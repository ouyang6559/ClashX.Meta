package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/go-chi/chi/v5"
	singjson "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/experimental/deprecated"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/service"
)

// engine owns the sing-box instance, the embedded xray bridge and the public
// HTTP endpoint the Swift UI talks to.
type engine struct {
	mu sync.Mutex

	configDir         string
	uiPath            string
	internalAPIPort   int
	publicPort        int
	publicSecret      string
	lastGeneral       generalInfo
	currentLevel      string
	activeRaw         []byte
	logLevelOverride  string
	allowLanOverride  *bool

	box      *box.Box
	xray     *xrayBridge
	proxy    *httputil.ReverseProxy
	proxySrv *http.Server
	running  bool
}

var sharedEngine = &engine{}

func getFreePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func portBusy(port int) bool {
	for _, addr := range []string{"0.0.0.0", "127.0.0.1"} {
		l, err := net.Listen("tcp", fmt.Sprintf("%s:%d", addr, port))
		if err != nil {
			return true
		}
		l.Close()
	}
	return false
}

func homeConfigDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".config", "clash")
}

// setUIPathImpl records the dashboard path inside the app bundle; it doubles
// as the anchor for locating bundled geo resources.
func setUIPathImpl(path string) {
	sharedEngine.mu.Lock()
	defer sharedEngine.mu.Unlock()
	sharedEngine.uiPath = path
}

// extractGeoResources unpacks bundled geoip.db.gz / geosite.db.gz (from the
// app bundle Resources dir) into the config dir when missing.
func extractGeoResources() {
	dir := sharedEngine.configDir
	if sharedEngine.uiPath == "" {
		return
	}
	resDir := filepath.Dir(sharedEngine.uiPath)
	for _, name := range []string{"geoip.db", "geosite.db"} {
		dst := filepath.Join(dir, name)
		if fileNonEmpty(dst) {
			continue
		}
		src, err := os.Open(filepath.Join(resDir, name+".gz"))
		if err != nil {
			continue
		}
		gz, err := gzip.NewReader(src)
		if err != nil {
			src.Close()
			continue
		}
		out, err := os.Create(dst)
		if err == nil {
			_, _ = io.Copy(out, gz)
			out.Close()
		}
		gz.Close()
		src.Close()
	}
}

// startEngine converts the config and boots sing-box + xray + the public API.
// Conversion happens BEFORE the previous core is stopped, so a bad profile
// never takes down a running proxy.
func startEngine(cfg *clashRawConfig, raw []byte, checkPort, allowLan bool) error {
	sharedEngine.mu.Lock()
	defer sharedEngine.mu.Unlock()

	if sharedEngine.internalAPIPort == 0 {
		port, err := getFreePort()
		if err != nil {
			return err
		}
		sharedEngine.internalAPIPort = port
	}

	if sharedEngine.allowLanOverride != nil {
		allowLan = *sharedEngine.allowLanOverride
	}
	logLevel := cfg.LogLevel
	if sharedEngine.logLevelOverride != "" {
		logLevel = sharedEngine.logLevelOverride
	}

	opt := startOptions{
		AllowLan:     allowLan,
		Mode:         cfg.Mode,
		LogLevel:     logLevel,
		InternalPort: sharedEngine.internalAPIPort,
		Secret:       cfg.Secret,
		UIPath:       sharedEngine.uiPath,
		ConfigDir:    sharedEngine.configDir,
	}

	// inbound ports: honor config, fall back to free ports when busy.
	// On profile reloads keep the already-bound ports (mihomo semantics:
	// inbound ports are fixed for the app session).
	mixed := cfg.MixedPort
	httpPort := cfg.Port
	socksPort := cfg.SocksPort
	if sharedEngine.lastGeneral.MixedPort > 0 {
		mixed = sharedEngine.lastGeneral.MixedPort
		httpPort = sharedEngine.lastGeneral.Port
		socksPort = sharedEngine.lastGeneral.SocksPort
	}
	if checkPort {
		if mixed > 0 && portBusy(mixed) {
			if p, err := getFreePort(); err == nil {
				mixed = p
			}
		}
		if mixed == 0 {
			if p, err := getFreePort(); err == nil {
				mixed = p
			}
		}
		if httpPort > 0 && portBusy(httpPort) {
			httpPort = 0
		}
		if socksPort > 0 && portBusy(socksPort) {
			socksPort = 0
		}
	} else if mixed > 0 && portBusy(mixed) {
		// old core was just stopped but the port is still held by someone else
		if p, err := getFreePort(); err == nil {
			mixed = p
		}
	}
	opt.MixedPort, opt.HTTPPort, opt.SocksPort = mixed, httpPort, socksPort

	// public API port: picked once per engine lifetime so profile reloads
	// don't yank the endpoint the UI is talking to
	publicPort := sharedEngine.publicPort
	if publicPort == 0 {
		if ec := cfg.ExternalController; ec != "" {
			if p, err := strconv.Atoi(ec[strings.LastIndex(ec, ":")+1:]); err == nil && p > 0 && p < 65535 && !portBusy(p) {
				publicPort = p
			}
		}
		if publicPort == 0 {
			p, err := getFreePort()
			if err != nil {
				return err
			}
			publicPort = p
		}
		sharedEngine.publicPort = publicPort
	}
	if cfg.Secret != "" {
		sharedEngine.publicSecret = cfg.Secret
	} else {
		sharedEngine.publicSecret = ""
	}

	extractGeoResources()

	result, err := convertClashToSingBox(cfg, opt, func() (int, error) {
		for i := 0; i < 32; i++ {
			p, err := getFreePort()
			if err != nil {
				return 0, err
			}
			if p != mixed && p != httpPort && p != socksPort && p != publicPort && p != sharedEngine.internalAPIPort {
				return p, nil
			}
		}
		return 0, fmt.Errorf("no free port")
	})
	if err != nil {
		return err
	}

	// conversion done — now tear down the old core so inbound ports free up,
	// then boot the new xray bridge and box
	sharedEngine.stopLocked()

	// boot xray bridge first so its socks inbounds are listening
	xr, err := newXrayBridge(result.Xray)
	if err != nil {
		return err
	}

	coreCtx := include.Context(service.ContextWith(context.Background(), deprecated.NewStderrManager(log.StdLogger())))
	optionsJSON, _ := json.Marshal(result.Options)
	boxOptions, err := singjson.UnmarshalExtendedContext[option.Options](coreCtx, optionsJSON)
	if err != nil {
		xr.Close()
		return fmt.Errorf("parse sing-box options: %w", err)
	}
	b, err := box.New(box.Options{Context: coreCtx, Options: boxOptions})
	if err != nil {
		xr.Close()
		return fmt.Errorf("start sing-box: %w", err)
	}
	if err := b.Start(); err != nil {
		b.Close()
		xr.Close()
		return fmt.Errorf("sing-box start: %w", err)
	}

	sharedEngine.box = b
	sharedEngine.xray = xr
	sharedEngine.lastGeneral = result.General
	sharedEngine.currentLevel = mapLogLevel(opt.LogLevel)
	sharedEngine.activeRaw = raw
	sharedEngine.running = true

	if sharedEngine.proxy == nil {
		target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", sharedEngine.internalAPIPort))
		rp := httputil.NewSingleHostReverseProxy(target)
		rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"message":"core not running"}`))
		}
		sharedEngine.proxy = rp
	}

	if sharedEngine.proxySrv == nil {
		mux := chi.NewRouter()
		mux.Get("/configs", handleGetConfigs)
		mux.Put("/configs", handlePutConfigs)
		mux.Patch("/configs", handlePatchConfigs)
		mux.Handle("/*", sharedEngine.proxy)
		sharedEngine.proxySrv = &http.Server{
			Addr:    fmt.Sprintf("127.0.0.1:%d", publicPort),
			Handler: mux,
		}
		go func(srv *http.Server) {
			_ = srv.ListenAndServe()
		}(sharedEngine.proxySrv)
	} else if sharedEngine.proxySrv.Addr != fmt.Sprintf("127.0.0.1:%d", publicPort) {
		_ = sharedEngine.proxySrv.Close()
		mux := chi.NewRouter()
		mux.Get("/configs", handleGetConfigs)
		mux.Put("/configs", handlePutConfigs)
		mux.Patch("/configs", handlePatchConfigs)
		mux.Handle("/*", sharedEngine.proxy)
		sharedEngine.proxySrv = &http.Server{
			Addr:    fmt.Sprintf("127.0.0.1:%d", publicPort),
			Handler: mux,
		}
		go func(srv *http.Server) {
			_ = srv.ListenAndServe()
		}(sharedEngine.proxySrv)
	}
	return nil
}

// stopLocked tears down the previous box/xray without touching the public server.
func (e *engine) stopLocked() {
	if e.box != nil {
		_ = e.box.Close()
		e.box = nil
	}
	if e.xray != nil {
		e.xray.Close()
		e.xray = nil
	}
	e.running = false
}

func (e *engine) stopEngine() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.stopLocked()
	if e.proxySrv != nil {
		_ = e.proxySrv.Close()
		e.proxySrv = nil
	}
}

// reloadFromPath re-converts and restarts the core against a config file.
func reloadFromPath(path string, checkPort bool) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}
	cfg, err := parseClashConfig(data)
	if err != nil {
		return err
	}
	return startEngine(cfg, data, checkPort, cfg.AllowLan)
}

// ---- public server handlers (override clash_api /configs) ----

func handleGetConfigs(w http.ResponseWriter, r *http.Request) {
	e := sharedEngine
	e.mu.Lock()
	base := e.lastGeneral
	secret := e.publicSecret
	e.mu.Unlock()
	// mode/log-level are authoritative from the core
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/configs", e.internalAPIPort))
	if err == nil {
		var internal map[string]any
		if json.NewDecoder(resp.Body).Decode(&internal) == nil {
			if m, ok := internal["mode"].(string); ok && m != "" {
				// sing-box normalizes clash modes to capitalized form; the
				// Swift enum expects mihomo-style lowercase values.
				base.Mode = strings.ToLower(m)
			}
			if l, ok := internal["log-level"].(string); ok && l != "" {
				base.LogLevel = l
			}
			if ml, ok := internal["mode-list"].([]any); ok && len(ml) > 0 {
				list := []string{}
				for _, item := range ml {
					if s, ok := item.(string); ok {
						list = append(list, s)
					}
				}
				base.ModeList = list
			}
		}
		resp.Body.Close()
	}
	base.Tun = map[string]any{"enable": false}
	data, _ := json.Marshal(base)
	w.Header().Set("Content-Type", "application/json")
	if secret != "" {
		w.Header().Set("Authorization", "Bearer "+secret)
	}
	_, _ = w.Write(data)
}

func handlePutConfigs(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path string `json:"Path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Path == "" {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"message":"missing Path"}`))
		return
	}
	if err := reloadFromPath(body.Path, false); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		msg, _ := json.Marshal(map[string]string{"message": err.Error()})
		_, _ = w.Write(msg)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func handlePatchConfigs(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Mode     string `json:"mode"`
		LogLevel string `json:"log-level"`
		AllowLan *bool  `json:"allow-lan"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	changed := false
	if body.Mode != "" {
		// forward mode change to the core's clash mode manager
		payload, _ := json.Marshal(map[string]string{"mode": body.Mode})
		req, _ := http.NewRequest(http.MethodPatch, fmt.Sprintf("http://127.0.0.1:%d/configs", sharedEngine.internalAPIPort), bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		if resp, err := http.DefaultClient.Do(req); err == nil {
			resp.Body.Close()
		}
		changed = true
	}
	if body.LogLevel != "" {
		changed = true
	}
	if body.AllowLan != nil {
		changed = true
	}
	if !changed {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// log-level / allow-lan require a rebuild of inbounds or logger
	if body.LogLevel != "" || body.AllowLan != nil {
		e := sharedEngine
		e.mu.Lock()
		raw := e.activeRaw
		if body.LogLevel != "" {
			e.logLevelOverride = body.LogLevel
		}
		if body.AllowLan != nil {
			lan := *body.AllowLan
			e.allowLanOverride = &lan
		}
		e.mu.Unlock()
		if len(raw) > 0 {
			cfg, err := parseClashConfig(raw)
			if err == nil {
				_ = startEngine(cfg, raw, false, cfg.AllowLan)
			}
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
