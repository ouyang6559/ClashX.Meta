package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// clashRawConfig mirrors the subset of clash-style YAML profiles this app
// consumes. Unknown fields are ignored on purpose.
type clashRawConfig struct {
	MixedPort         int    `yaml:"mixed-port"`
	Port              int    `yaml:"port"`
	SocksPort         int    `yaml:"socks-port"`
	AllowLan          bool   `yaml:"allow-lan"`
	BindAddress       string `yaml:"bind-address"`
	Mode              string `yaml:"mode"`
	LogLevel          string `yaml:"log-level"`
	IPv6              bool   `yaml:"ipv6"`
	ExternalController string `yaml:"external-controller"`
	Secret            string `yaml:"secret"`
	Proxies           []map[string]any  `yaml:"proxies"`
	ProxyGroups       []map[string]any  `yaml:"proxy-groups"`
	Rules             []string          `yaml:"rules"`
}

type startOptions struct {
	MixedPort    int
	HTTPPort     int
	SocksPort    int
	AllowLan     bool
	Mode         string
	LogLevel     string
	InternalPort int
	Secret       string
	UIPath       string
	ConfigDir    string
}

type generalInfo struct {
	Port      int            `json:"port"`
	SocksPort int            `json:"socks-port"`
	RedirPort int            `json:"redir-port"`
	TProxyPort int           `json:"tproxy-port"`
	MixedPort int            `json:"mixed-port"`
	AllowLan  bool           `json:"allow-lan"`
	BindAddress string       `json:"bind-address"`
	Mode      string         `json:"mode"`
	ModeList  []string       `json:"mode-list"`
	LogLevel  string         `json:"log-level"`
	IPv6      bool           `json:"ipv6"`
	Tun       map[string]any `json:"tun"`
}

// xrayNode is a proxy that must be dialed through the embedded Xray-core.
type xrayNode struct {
	Name      string
	LocalPort int
	Outbound  map[string]any // xray outbound JSON
}

type convertResult struct {
	Options map[string]any
	Xray    []xrayNode
	General generalInfo
}

func parseClashConfig(data []byte) (*clashRawConfig, error) {
	cfg := &clashRawConfig{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse yaml: %w", err)
	}
	if cfg.MixedPort == 0 {
		if cfg.Port > 0 {
			cfg.MixedPort = cfg.Port
			cfg.Port = 0
		} else if cfg.SocksPort > 0 {
			cfg.MixedPort = cfg.SocksPort
			cfg.SocksPort = 0
		} else {
			cfg.MixedPort = 7890
		}
	}
	if cfg.Mode == "" {
		cfg.Mode = "rule"
	}
	if cfg.LogLevel == "" {
		cfg.LogLevel = "info"
	}
	return cfg, nil
}

func mapLogLevel(level string) string {
	switch strings.ToLower(level) {
	case "silent":
		return "panic"
	case "warning":
		return "warn"
	case "unknow", "unknown", "":
		return "info"
	default:
		return strings.ToLower(level)
	}
}

func mapTarget(target string) string {
	switch target {
	case "DIRECT":
		return "direct"
	case "REJECT", "REJECT-DROP", "PASS":
		return "block"
	default:
		return target
	}
}

// convertClashToSingBox builds sing-box options (and the xray bridge plan)
// from a parsed clash-style config.
func convertClashToSingBox(cfg *clashRawConfig, opt startOptions, allocPort func() (int, error)) (*convertResult, error) {
	res := &convertResult{}
	outbounds := []map[string]any{}
	endpoints := []map[string]any{}
	proxyTags := []string{}
	groupTags := []string{}
	for _, g := range cfg.ProxyGroups {
		if name, _ := g["name"].(string); name != "" {
			groupTags = append(groupTags, name)
		}
	}

	// ---- proxies ----
	for _, p := range cfg.Proxies {
		name, _ := p["name"].(string)
		ptype, _ := p["type"].(string)
		if name == "" || ptype == "" {
			return nil, fmt.Errorf("proxy entry missing name/type: %v", p)
		}
		if ptype == "wireguard" {
			ep, err := buildWireguardEndpoint(p, name)
			if err != nil {
				return nil, fmt.Errorf("proxy %s: %w", name, err)
			}
			endpoints = append(endpoints, ep)
			proxyTags = append(proxyTags, name)
			continue
		}
		if ptype == "vless" {
			if flow, _ := p["flow"].(string); strings.Contains(flow, "vision") {
				port, err := allocPort()
				if err != nil {
					return nil, fmt.Errorf("alloc local port for %s: %w", name, err)
				}
				outbound, err := buildXrayVLESSOutbound(p)
				if err != nil {
					return nil, fmt.Errorf("proxy %s: %w", name, err)
				}
				res.Xray = append(res.Xray, xrayNode{Name: name, LocalPort: port, Outbound: outbound})
				outbounds = append(outbounds, map[string]any{
					"type": "socks", "tag": name,
					"server": "127.0.0.1", "server_port": port, "version": "5",
				})
				proxyTags = append(proxyTags, name)
				continue
			}
		}
		ob, err := buildSingBoxOutbound(p, name, ptype)
		if err != nil {
			// unsupported protocol (ssr etc.): skip the node, keep the rest
			fmt.Printf("[vpcore] skip proxy %q: %v\n", name, err)
			continue
		}
		outbounds = append(outbounds, ob)
		proxyTags = append(proxyTags, name)
	}

	// ---- groups ----
	// refs must point at outbounds that actually exist, or sing-box validation
	// rejects the whole config (mihomo tolerated dangling names)
	known := map[string]bool{"direct": true, "block": true, "GLOBAL": true}
	for _, t := range proxyTags {
		known[t] = true
	}
	for _, t := range groupTags {
		known[t] = true
	}
	hasBlock := false
	groups := []map[string]any{}
	for _, g := range cfg.ProxyGroups {
		name, _ := g["name"].(string)
		gtype, _ := g["type"].(string)
		members, _ := g["proxies"].([]any)
		if name == "" || gtype == "" {
			continue
		}
		tags := []string{}
		for _, m := range members {
			ms, _ := m.(string)
			switch ms {
			case "DIRECT":
				tags = append(tags, "direct")
			case "REJECT", "REJECT-DROP", "PASS":
				hasBlock = true // only meaningful for rules; groups skip it
			default:
				if ms != "" && known[ms] {
					tags = append(tags, ms)
				}
			}
		}
		if len(tags) == 0 {
			tags = []string{"direct"}
		}
		switch gtype {
		case "url-test":
			entry := map[string]any{"type": "urltest", "tag": name, "outbounds": tags}
			if u, ok := g["url"].(string); ok && u != "" {
				entry["url"] = u
			}
			if itv, ok := g["interval"].(int); ok && itv > 0 {
				entry["interval"] = fmt.Sprintf("%ds", itv)
			}
			if tol, ok := g["tolerance"].(int); ok && tol > 0 {
				entry["tolerance"] = int64(tol)
			}
			groups = append(groups, entry)
		case "select", "fallback", "load-balance", "relay":
			// fallback/load-balance/relay degrade to manual selector in v1
			groups = append(groups, map[string]any{"type": "selector", "tag": name, "outbounds": tags})
		default:
			fmt.Printf("[vpcore] skip proxy-group %q: unsupported type %q\n", name, gtype)
		}
	}

	// GLOBAL selector drives clash "global" mode.
	globalMembers := append([]string{}, proxyTags...)
	globalMembers = append(globalMembers, "direct")
	groups = append([]map[string]any{{"type": "selector", "tag": "GLOBAL", "outbounds": globalMembers}}, groups...)

	outbounds = append(outbounds, groups...)
	outbounds = append(outbounds,
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "block", "tag": "block"},
	)
	_ = hasBlock

	// ---- rules ----
	rules := []map[string]any{
		{"clash_mode": "Global", "outbound": "GLOBAL"},
		{"clash_mode": "Direct", "outbound": "direct"},
	}
	final := "direct"
	geoOK := fileNonEmpty(filepath.Join(opt.ConfigDir, "geoip.db"))
	geoSiteOK := fileNonEmpty(filepath.Join(opt.ConfigDir, "geosite.db"))
	for _, line := range cfg.Rules {
		fields := strings.Split(line, ",")
		if len(fields) < 2 {
			continue
		}
		rtype := strings.ToUpper(strings.TrimSpace(fields[0]))
		if rtype == "MATCH" {
			if len(fields) >= 2 {
				final = mapTarget(strings.TrimSpace(fields[1]))
			}
			continue
		}
		if rtype == "RULE-SET" || rtype == "AND" || rtype == "OR" || rtype == "NOT" || rtype == "SUB-RULE" {
			continue // not supported in v1
		}
		if len(fields) < 3 {
			continue
		}
		payload := strings.TrimSpace(fields[1])
		rawTarget := strings.TrimSpace(fields[2])
		if !known[mapTarget(rawTarget)] {
			continue // dangling reference (e.g. empty proxy list in sample config)
		}
		target := mapTarget(rawTarget)
		var field string
		var value any
		switch rtype {
		case "DOMAIN":
			field, value = "domain", []string{strings.ToLower(payload)}
		case "DOMAIN-SUFFIX":
			field, value = "domain_suffix", []string{strings.ToLower(payload)}
		case "DOMAIN-KEYWORD":
			field, value = "domain_keyword", []string{strings.ToLower(payload)}
		case "IP-CIDR", "IP-CIDR6":
			field, value = "ip_cidr", []string{payload}
		case "SRC-IP-CIDR":
			field, value = "source_ip_cidr", []string{payload}
		case "DST-PORT":
			ports, err := expandPorts(payload)
			if err != nil || len(ports) == 0 {
				continue
			}
			field, value = "port", ports
		case "SRC-PORT":
			ports, err := expandPorts(payload)
			if err != nil || len(ports) == 0 {
				continue
			}
			field, value = "source_port", ports
		case "GEOIP":
			if !geoOK {
				continue
			}
			field, value = "geoip", []string{strings.ToLower(payload)}
		case "GEOSITE":
			if !geoSiteOK {
				continue
			}
			field, value = "geosite", []string{strings.ToLower(payload)}
		case "PROCESS-NAME":
			field, value = "process_name", []string{payload}
		default:
			continue
		}
		rule := map[string]any{field: value}
		if target == "block" {
			rule["action"] = "reject"
		} else {
			rule["outbound"] = target
		}
		rules = append(rules, rule)
	}

	// ---- dns / route / experimental ----
	options := map[string]any{
		"log": map[string]any{
			"level":     mapLogLevel(opt.LogLevel),
			"timestamp": true,
		},
		"dns": map[string]any{
			"servers": []map[string]any{{"type": "local", "tag": "local"}},
		},
		"inbounds":  buildInbounds(opt),
		"outbounds": outbounds,
		"route": map[string]any{
			"rules":                    rules,
			"final":                    final,
			"auto_detect_interface":    true,
			"default_domain_resolver":  map[string]any{"server": "local"},
		},
		"experimental": map[string]any{
			"clash_api": map[string]any{
				"external_controller": fmt.Sprintf("127.0.0.1:%d", opt.InternalPort),
				"default_mode":        cfg.Mode,
				"access_control_allow_origin": []string{"*"},
				"access_control_allow_private_network": true,
			},
			"cache_file": map[string]any{
				"enabled": true,
				"path":    filepath.Join(opt.ConfigDir, "cache.db"),
			},
		},
	}
	if len(endpoints) > 0 {
		options["endpoints"] = endpoints
	}
	if opt.UIPath != "" {
		optExp := options["experimental"].(map[string]any)
		optExp["clash_api"].(map[string]any)["external_ui"] = opt.UIPath
	}
	if geoOK {
		options["route"].(map[string]any)["geoip"] = map[string]any{"path": filepath.Join(opt.ConfigDir, "geoip.db")}
	}
	if geoSiteOK {
		options["route"].(map[string]any)["geosite"] = map[string]any{"path": filepath.Join(opt.ConfigDir, "geosite.db")}
	}

	res.Options = options
	res.General = generalInfo{
		Port: opt.HTTPPort, SocksPort: opt.SocksPort, MixedPort: opt.MixedPort,
		AllowLan: opt.AllowLan, BindAddress: "*",
		Mode: cfg.Mode, ModeList: []string{"Rule", "Global", "Direct"},
		LogLevel: strings.ToLower(opt.LogLevel), IPv6: cfg.IPv6,
	}
	return res, nil
}

func buildInbounds(opt startOptions) []map[string]any {
	listen := "127.0.0.1"
	if opt.AllowLan {
		listen = "::"
	}
	inbounds := []map[string]any{}
	if opt.MixedPort > 0 {
		inbounds = append(inbounds, map[string]any{
			"type": "mixed", "tag": "mixed-in", "listen": listen, "listen_port": opt.MixedPort,
		})
	}
	if opt.HTTPPort > 0 {
		inbounds = append(inbounds, map[string]any{
			"type": "http", "tag": "http-in", "listen": listen, "listen_port": opt.HTTPPort,
		})
	}
	if opt.SocksPort > 0 {
		inbounds = append(inbounds, map[string]any{
			"type": "socks", "tag": "socks-in", "listen": listen, "listen_port": opt.SocksPort,
		})
	}
	return inbounds
}

// ---- per-protocol outbound builders ----

func str(p map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := p[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

func integer(p map[string]any, keys ...string) int {
	for _, k := range keys {
		switch v := p[k].(type) {
		case int:
			if v != 0 {
				return v
			}
		case float64:
			if v != 0 {
				return int(v)
			}
		}
	}
	return 0
}

func serverBase(p map[string]any) (string, int, error) {
	server := str(p, "server")
	port := integer(p, "port")
	if server == "" || port <= 0 {
		return "", 0, fmt.Errorf("missing server/port")
	}
	return server, port, nil
}

func buildOutboundTLS(p map[string]any, defaultSNI string) map[string]any {
	enabled := false
	if v, ok := p["tls"].(bool); ok {
		enabled = v
	}
	sni := str(p, "servername", "sni")
	if sni == "" {
		sni = defaultSNI
	}
	if rp, ok := p["reality-opts"].(map[string]any); ok && len(rp) > 0 {
		enabled = true
	}
	if !enabled {
		return nil
	}
	tls := map[string]any{
		"enabled":      true,
		"server_name":  sni,
		"insecure":     boolAny(p["skip-cert-verify"]),
	}
	if alpn := strList(p, "alpn"); len(alpn) > 0 {
		tls["alpn"] = alpn
	}
	if fp := str(p, "client-fingerprint"); fp != "" {
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
	}
	if rp, ok := p["reality-opts"].(map[string]any); ok {
		reality := map[string]any{"enabled": true}
		if pk := str(rp, "public-key"); pk != "" {
			reality["public_key"] = pk
		}
		if sid := str(rp, "short-id"); sid != "" {
			reality["short_id"] = sid
		}
		tls["reality"] = reality
		if tls["utls"] == nil {
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": "chrome"}
		}
	}
	return tls
}

func boolAny(v any) bool {
	b, _ := v.(bool)
	return b
}

func strList(p map[string]any, key string) []string {
	if v, ok := p[key].([]any); ok {
		out := []string{}
		for _, item := range v {
			if s, ok := item.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

func buildOutboundTransport(p map[string]any) map[string]any {
	network := str(p, "network")
	switch network {
	case "ws":
		t := map[string]any{"type": "ws"}
		if wo, ok := p["ws-opts"].(map[string]any); ok {
			if path := str(wo, "path"); path != "" {
				t["path"] = path
			}
			if headers, ok := wo["headers"].(map[string]any); ok {
				headersOut := map[string]any{}
				if host := str(headers, "Host", "host"); host != "" {
					headersOut["Host"] = []string{host}
				}
				if len(headersOut) > 0 {
					t["headers"] = headersOut
				}
			}
			if v, ok := wo["max-early-data"].(int); ok && v > 0 {
				t["max_early_data"] = v
			}
			if v, ok := wo["early-data-header-name"].(string); ok && v != "" {
				t["early_data_header_name"] = v
			}
		}
		return t
	case "grpc":
		t := map[string]any{"type": "grpc"}
		if go_, ok := p["grpc-opts"].(map[string]any); ok {
			if svc := str(go_, "grpc-service-name"); svc != "" {
				t["service_name"] = svc
			}
		}
		return t
	case "h2", "http":
		t := map[string]any{"type": "http"}
		if ho, ok := p["h2-opts"].(map[string]any); ok {
			if host := strList(ho, "host"); len(host) > 0 {
				t["host"] = host
			}
			if path := str(ho, "path"); path != "" {
				t["path"] = path
			}
		}
		return t
	default:
		return nil
	}
}

func buildSingBoxOutbound(p map[string]any, name, ptype string) (map[string]any, error) {
	server, port, err := serverBase(p)
	if err != nil {
		return nil, err
	}
	ob := map[string]any{"tag": name, "server": server, "server_port": port}
	switch ptype {
	case "ss", "shadowsocks":
		ob["type"] = "shadowsocks"
		ob["method"] = str(p, "cipher")
		ob["password"] = str(p, "password")
		if plugin := str(p, "plugin"); plugin != "" {
			// v2ray-plugin/obfs map to sing-box plugin names
			switch plugin {
			case "obfs":
				ob["plugin"] = "obfs-local"
			case "v2ray-plugin":
				ob["plugin"] = "v2ray-plugin"
			default:
				ob["plugin"] = plugin
			}
			if po := str(p, "plugin-opts"); po != "" {
				// clash plugin-opts is a map; flatten common fields
				if pom, ok := p["plugin-opts"].(map[string]any); ok {
					ob["plugin_opts"] = flattenPluginOpts(plugin, pom)
				} else {
					ob["plugin_opts"] = po
				}
			}
		}
	case "vmess":
		ob["type"] = "vmess"
		ob["uuid"] = str(p, "uuid")
		ob["security"] = str(p, "cipher", "encryption")
		if ob["security"] == "" {
			ob["security"] = "auto"
		}
		ob["alter_id"] = integer(p, "alterId", "alter-id")
		ob["packet_encoding"] = "xudp"
		if tls := buildOutboundTLS(p, server); tls != nil {
			ob["tls"] = tls
		}
		if tr := buildOutboundTransport(p); tr != nil {
			ob["transport"] = tr
		}
	case "vless":
		ob["type"] = "vless"
		ob["uuid"] = str(p, "uuid")
		ob["packet_encoding"] = "xudp"
		if tls := buildOutboundTLS(p, server); tls != nil {
			ob["tls"] = tls
		}
		if tr := buildOutboundTransport(p); tr != nil {
			ob["transport"] = tr
		}
	case "trojan":
		ob["type"] = "trojan"
		ob["password"] = str(p, "password")
		tls := buildOutboundTLS(p, server)
		if tls == nil {
			tls = map[string]any{"enabled": true, "server_name": server, "insecure": boolAny(p["skip-cert-verify"])}
		}
		ob["tls"] = tls
		if tr := buildOutboundTransport(p); tr != nil {
			ob["transport"] = tr
		}
	case "hysteria2", "hy2":
		ob["type"] = "hysteria2"
		ob["password"] = str(p, "password", "auth")
		if up := str(p, "up"); up != "" {
			if n, err := strconv.Atoi(strings.TrimSuffix(up, " Mbps")); err == nil {
				ob["up_mbps"] = n
			}
		}
		if down := str(p, "down"); down != "" {
			if n, err := strconv.Atoi(strings.TrimSuffix(down, " Mbps")); err == nil {
				ob["down_mbps"] = n
			}
		}
		if obfs := str(p, "obfs"); obfs != "" && obfs != "none" {
			ob["obfs"] = map[string]any{"type": "salamander", "password": str(p, "obfs-password")}
		}
		tls := buildOutboundTLS(p, server)
		if tls == nil {
			tls = map[string]any{"enabled": true, "server_name": server, "insecure": boolAny(p["skip-cert-verify"])}
		}
		ob["tls"] = tls
	case "tuic":
		ob["type"] = "tuic"
		ob["uuid"] = str(p, "uuid")
		ob["password"] = str(p, "password")
		ob["congestion_control"] = str(p, "congestion-controller", "congestion-control")
		ob["udp_relay_mode"] = str(p, "udp-relay-mode")
		if v, ok := p["reduce-rtt"].(bool); ok && v {
			ob["zero_rtt_handshake"] = true
		}
		tls := buildOutboundTLS(p, server)
		if tls == nil {
			tls = map[string]any{"enabled": true, "server_name": server, "insecure": boolAny(p["skip-cert-verify"])}
		}
		if alpns, ok := tls["alpn"].([]string); !ok || len(alpns) == 0 {
			tls["alpn"] = []string{"h3"}
		}
		ob["tls"] = tls
	case "http":
		ob["type"] = "http"
		ob["username"] = str(p, "username")
		ob["password"] = str(p, "password")
		if tls := buildOutboundTLS(p, server); tls != nil {
			ob["tls"] = tls
		}
	case "socks5", "socks":
		ob["type"] = "socks"
		ob["version"] = "5"
		ob["username"] = str(p, "username")
		ob["password"] = str(p, "password")
		if tls := buildOutboundTLS(p, server); tls != nil {
			ob["tls"] = tls
		}
	default:
		return nil, fmt.Errorf("unsupported proxy type %q", ptype)
	}
	// remove empty optionals to keep validation happy
	cleanEmpty(ob)
	return ob, nil
}

func flattenPluginOpts(plugin string, opts map[string]any) string {
	parts := []string{}
	switch plugin {
	case "obfs":
		if mode := str(opts, "mode"); mode != "" {
			parts = append(parts, "obfs="+mode)
		}
		if host := str(opts, "host"); host != "" {
			parts = append(parts, "obfs-host="+host)
		}
	case "v2ray-plugin":
		if mode := str(opts, "mode"); mode != "" {
			parts = append(parts, "mode="+mode)
		}
		if boolAny(opts["tls"]) {
			parts = append(parts, "tls")
		}
		if host := str(opts, "host"); host != "" {
			parts = append(parts, "host="+host)
		}
		if path := str(opts, "path"); path != "" {
			parts = append(parts, "path="+path)
		}
	}
	return strings.Join(parts, ";")
}

func buildXrayVLESSOutbound(p map[string]any) (map[string]any, error) {
	server, port, err := serverBase(p)
	if err != nil {
		return nil, err
	}
	user := map[string]any{
		"id":         str(p, "uuid"),
		"encryption": "none",
		"flow":       str(p, "flow"),
		"level":      0,
	}
	out := map[string]any{
		"protocol": "vless",
		"settings": map[string]any{
			"vnext": []map[string]any{{
				"address": server,
				"port":    port,
				"users":   []map[string]any{user},
			}},
		},
	}
	stream := map[string]any{"network": "tcp"}
	if network := str(p, "network"); network != "" {
		stream["network"] = network
	}
	security := "none"
	sni := str(p, "servername", "sni")
	if sni == "" {
		sni = server
	}
	if rp, ok := p["reality-opts"].(map[string]any); ok && len(rp) > 0 {
		security = "reality"
		reality := map[string]any{
			"serverName":  sni,
			"fingerprint": str(p, "client-fingerprint", "chrome"),
			"publicKey":   str(rp, "public-key"),
			"shortId":     str(rp, "short-id"),
		}
		stream["realitySettings"] = reality
	} else if boolAny(p["tls"]) {
		security = "tls"
		tls := map[string]any{
			"serverName":    sni,
			"allowInsecure": boolAny(p["skip-cert-verify"]),
			"fingerprint":   str(p, "client-fingerprint", "chrome"),
		}
		if alpn := strList(p, "alpn"); len(alpn) > 0 {
			tls["alpn"] = alpn
		}
		stream["tlsSettings"] = tls
	}
	stream["security"] = security
	switch str(p, "network") {
	case "ws":
		ws := map[string]any{}
		if wo, ok := p["ws-opts"].(map[string]any); ok {
			if path := str(wo, "path"); path != "" {
				ws["path"] = path
			}
			if headers, ok := wo["headers"].(map[string]any); ok {
				if host := str(headers, "Host", "host"); host != "" {
					ws["headers"] = map[string]any{"Host": host}
				}
			}
		}
		stream["wsSettings"] = ws
	case "grpc":
		grpc := map[string]any{}
		if go_, ok := p["grpc-opts"].(map[string]any); ok {
			if svc := str(go_, "grpc-service-name"); svc != "" {
				grpc["serviceName"] = svc
			}
		}
		stream["grpcSettings"] = grpc
	}
	out["streamSettings"] = stream
	return out, nil
}

func buildWireguardEndpoint(p map[string]any, name string) (map[string]any, error) {
	server, port, err := serverBase(p)
	if err != nil {
		return nil, err
	}
	ep := map[string]any{"type": "wireguard", "tag": name}
	local := []string{}
	if ip := str(p, "ip"); ip != "" {
		local = append(local, ip+"/32")
	}
	if ip6 := str(p, "ipv6"); ip6 != "" {
		local = append(local, ip6+"/128")
	}
	ep["address"] = local
	ep["private_key"] = str(p, "private-key")
	peer := map[string]any{
		"address":     server,
		"port":        port,
		"public_key":  str(p, "public-key"),
		"allowed_ips": []string{"0.0.0.0/0", "::/0"},
	}
	if psk := str(p, "pre-shared-key"); psk != "" {
		peer["pre_shared_key"] = psk
	}
	if reserved := strList(p, "reserved"); len(reserved) > 0 {
		peer["reserved"] = reserved
	}
	ep["peers"] = []map[string]any{peer}
	if mtu := integer(p, "mtu"); mtu > 0 {
		ep["mtu"] = mtu
	}
	return ep, nil
}

func cleanEmpty(m map[string]any) {
	for k, v := range m {
		switch tv := v.(type) {
		case string:
			if tv == "" {
				delete(m, k)
			}
		case map[string]any:
			if len(tv) == 0 {
				delete(m, k)
			} else {
				cleanEmpty(tv)
			}
		}
	}
}

func expandPorts(payload string) ([]int, error) {
	out := []int{}
	for _, part := range strings.Split(payload, "/") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if strings.Contains(part, "-") {
			bounds := strings.SplitN(part, "-", 2)
			lo, err1 := strconv.Atoi(bounds[0])
			hi, err2 := strconv.Atoi(bounds[1])
			if err1 != nil || err2 != nil || hi < lo || hi-lo > 4096 {
				continue
			}
			for pnum := lo; pnum <= hi; pnum++ {
				out = append(out, pnum)
			}
			continue
		}
		if n, err := strconv.Atoi(part); err == nil && n > 0 && n < 65536 {
			out = append(out, n)
		}
	}
	return out, nil
}

func fileNonEmpty(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Size() > 0
}

// jsonMarshal is a tiny helper for tests and callers that want the raw JSON.
func jsonMarshal(v any) []byte {
	data, _ := json.Marshal(v)
	return data
}
