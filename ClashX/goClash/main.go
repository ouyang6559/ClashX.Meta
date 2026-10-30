package main

import (
	"C"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// The exported API mirrors the legacy clash bridge exactly so the Swift side
// needs no changes: initClashCore / verifyClashConfig / run / setUIPath /
// clashUpdateConfig / clashGetConfigs / verifyGEOIPDataBase. Under the hood
// the core is sing-box (with the Clash API exposed for the UI) plus an
// embedded Xray-core for xtls-rprx-vision nodes.

func activeConfigPath() string {
	return filepath.Join(sharedEngine.configDir, "config.yaml")
}

//export initClashCore
func initClashCore() {
	sharedEngine.mu.Lock()
	defer sharedEngine.mu.Unlock()
	sharedEngine.configDir = homeConfigDir()
	_ = os.MkdirAll(sharedEngine.configDir, 0o755)
}

//export verifyClashConfig
func verifyClashConfig(content *C.char) *C.char {
	data := []byte(C.GoString(content))
	cfg, err := parseClashConfig(data)
	if err != nil {
		return C.CString(err.Error())
	}
	if len(cfg.Proxies) < 1 {
		return C.CString("No proxy found in config")
	}
	opt := startOptions{
		MixedPort:    cfg.MixedPort,
		InternalPort: 19090,
		ConfigDir:    sharedEngine.configDir,
		Mode:         cfg.Mode,
		LogLevel:     cfg.LogLevel,
	}
	if _, err := convertClashToSingBox(cfg, opt, func() (int, error) { return 60000, nil }); err != nil {
		return C.CString(err.Error())
	}
	return C.CString("success")
}

//export run
func run(checkConfig, allowLan bool) *C.char {
	sharedEngine.mu.Lock()
	if sharedEngine.configDir == "" {
		sharedEngine.configDir = homeConfigDir()
		_ = os.MkdirAll(sharedEngine.configDir, 0o755)
	}
	sharedEngine.mu.Unlock()

	path := activeConfigPath()
	if _, err := os.Stat(path); err != nil {
		return C.CString(fmt.Sprintf("Configuration file %s is missing", path))
	}
	if err := reloadFromPath(path, checkConfig); err != nil {
		return C.CString(err.Error())
	}

	sharedEngine.mu.Lock()
	port := sharedEngine.publicPort
	secret := sharedEngine.publicSecret
	sharedEngine.mu.Unlock()

	payload, err := json.Marshal(map[string]string{
		"externalController": fmt.Sprintf("127.0.0.1:%d", port),
		"secret":             secret,
	})
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString(string(payload))
}

//export setUIPath
func setUIPath(path *C.char) {
	setUIPathImpl(C.GoString(path))
}

//export clashUpdateConfig
func clashUpdateConfig(path *C.char) *C.char {
	p := C.GoString(path)
	if _, err := os.Stat(p); err != nil {
		return C.CString(fmt.Sprintf("read config: %s not found", p))
	}
	if err := reloadFromPath(p, false); err != nil {
		return C.CString(err.Error())
	}
	return C.CString("success")
}

//export clashGetConfigs
func clashGetConfigs() *C.char {
	sharedEngine.mu.Lock()
	general := sharedEngine.lastGeneral
	sharedEngine.mu.Unlock()
	data, err := json.Marshal(general)
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString(string(data))
}

//export verifyGEOIPDataBase
func verifyGEOIPDataBase() bool {
	sharedEngine.mu.Lock()
	dir := sharedEngine.configDir
	if dir == "" {
		dir = homeConfigDir()
	}
	sharedEngine.mu.Unlock()
	return fileNonEmpty(filepath.Join(dir, "geoip.db"))
}

func main() {}
