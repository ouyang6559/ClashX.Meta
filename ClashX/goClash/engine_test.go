package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testConfig = `
mixed-port: 17890
mode: rule
log-level: info
proxies:
  - name: ss-node
    type: ss
    server: 192.0.2.10
    port: 8388
    cipher: aes-256-gcm
    password: pass1
    udp: true
  - name: vmess-node
    type: vmess
    server: 192.0.2.11
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    alterId: 0
    cipher: auto
    tls: true
    servername: example.com
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: example.com
  - name: vision-node
    type: vless
    server: 192.0.2.12
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    flow: xtls-rprx-vision
    tls: true
    servername: real.example.com
    client-fingerprint: chrome
    reality-opts:
      public-key: abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ
      short-id: "0123abcd"
    udp: true
  - name: trojan-node
    type: trojan
    server: 192.0.2.13
    port: 443
    password: pass2
    sni: t.example.com
    skip-cert-verify: true
  - name: hy2-node
    type: hysteria2
    server: 192.0.2.14
    port: 36712
    password: pass3
    sni: h.example.com
  - name: tuic-node
    type: tuic
    server: 192.0.2.15
    port: 443
    uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    password: pass4
    sni: tu.example.com
    congestion-controller: bbr
    reduce-rtt: true
  - name: wg-node
    type: wireguard
    server: 192.0.2.16
    port: 51820
    ip: 172.16.0.2
    private-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    public-key: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
  - name: socks-local
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - AUTO
      - ss-node
      - vmess-node
      - vision-node
      - trojan-node
      - DIRECT
  - name: AUTO
    type: url-test
    url: http://cp.cloudflare.com/generate_204
    interval: 300
    proxies:
      - ss-node
      - trojan-node
rules:
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-KEYWORD,baidu,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
`

func httpGet(t *testing.T, url string) (int, []byte) {
	t.Helper()
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return 0, nil
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func TestEngineEndToEnd(t *testing.T) {
	dir := homeConfigDir()
	_ = os.MkdirAll(dir, 0o755)
	sharedEngine.mu.Lock()
	sharedEngine.configDir = dir
	sharedEngine.mu.Unlock()

	cfgPath := filepath.Join(dir, "test_engine.yaml")
	if err := os.WriteFile(cfgPath, []byte(testConfig), 0o644); err != nil {
		t.Fatal(err)
	}

	// 1. parse + verify
	cfg, err := parseClashConfig([]byte(testConfig))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(cfg.Proxies) != 8 {
		t.Fatalf("want 8 proxies, got %d", len(cfg.Proxies))
	}

	// 2. start engine
	if err := reloadFromPath(cfgPath, true); err != nil {
		t.Fatalf("start engine: %v", err)
	}
	defer sharedEngine.stopEngine()

	sharedEngine.mu.Lock()
	publicPort := sharedEngine.publicPort
	internalPort := sharedEngine.internalAPIPort
	xrayNodes := 0
	if sharedEngine.xray != nil {
		xrayNodes = len(sharedEngine.xray.nodes)
	}
	sharedEngine.mu.Unlock()
	t.Logf("public port=%d internal=%d xray nodes=%d", publicPort, internalPort, xrayNodes)

	// 3. xray vision node bridged + local socks listening
	if xrayNodes != 1 {
		t.Fatalf("want 1 xray node, got %d", xrayNodes)
	}
	var visionLocalPort int
	sharedEngine.mu.Lock()
	for _, n := range sharedEngine.xray.nodes {
		visionLocalPort = n.LocalPort
	}
	sharedEngine.mu.Unlock()
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", visionLocalPort), 2*time.Second)
	if err != nil {
		t.Fatalf("xray local socks not listening: %v", err)
	}
	conn.Close()

	// 4. public API: /version (proxied) and /configs (overridden)
	code, body := httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/version", publicPort))
	if code != 200 {
		t.Fatalf("/version status %d", code)
	}
	t.Logf("version: %s", string(body))

	code, body = httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/configs", publicPort))
	if code != 200 {
		t.Fatalf("/configs status %d", code)
	}
	var general map[string]any
	if err := json.Unmarshal(body, &general); err != nil {
		t.Fatalf("/configs decode: %v", err)
	}
	for _, key := range []string{"port", "socks-port", "mixed-port", "allow-lan", "mode", "log-level"} {
		if _, ok := general[key]; !ok {
			t.Fatalf("/configs missing key %q: %s", key, string(body))
		}
	}
	// mode persists across restarts via cache file; sanity-check the value
	mode := fmt.Sprintf("%v", general["mode"])
	if mode != "rule" && mode != "global" && mode != "direct" {
		t.Fatalf("unexpected mode %q", mode)
	}
	t.Logf("configs: %s", string(body))

	// 5. proxies list contains groups, GLOBAL and the xray-bridged node
	code, body = httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/proxies", publicPort))
	if code != 200 {
		t.Fatalf("/proxies status %d", code)
	}
	var proxies struct {
		Proxies map[string]map[string]any `json:"proxies"`
	}
	if err := json.Unmarshal(body, &proxies); err != nil {
		t.Fatalf("/proxies decode: %v", err)
	}
	for _, want := range []string{"GLOBAL", "PROXY", "AUTO", "vision-node", "wg-node", "hy2-node", "tuic-node"} {
		if _, ok := proxies.Proxies[want]; !ok {
			t.Fatalf("/proxies missing %q (got %d entries)", want, len(proxies.Proxies))
		}
	}

	// 6. PATCH mode -> internal core honors it
	client := &http.Client{Timeout: 5 * time.Second}
	req, _ := http.NewRequest("PATCH", fmt.Sprintf("http://127.0.0.1:%d/configs", publicPort),
		strings.NewReader(`{"mode":"global"}`))
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	_, body = httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/configs", publicPort))
	var after map[string]any
	json.Unmarshal(body, &after)
	if after["mode"] != "global" {
		t.Fatalf("mode not switched: %v", after["mode"])
	}

	// 7. rules endpoint (proxied)
	code, _ = httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/rules", publicPort))
	if code != 200 {
		t.Fatalf("/rules status %d", code)
	}

	// 8. mixed inbound accepts connections
	mixed := sharedEngine.lastGeneral.MixedPort
	conn, err = net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", mixed), 2*time.Second)
	if err != nil {
		t.Fatalf("mixed inbound not listening on %d: %v", mixed, err)
	}
	conn.Close()

	// 9. restart via PUT /configs (profile switch path)
	req, _ = http.NewRequest("PUT", fmt.Sprintf("http://127.0.0.1:%d/configs", publicPort),
		strings.NewReader(fmt.Sprintf(`{"Path":%q}`, cfgPath)))
	resp, err = client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 204 {
		t.Fatalf("PUT /configs status %d body %s", resp.StatusCode, string(data))
	}
	time.Sleep(300 * time.Millisecond)
	code, _ = httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/proxies", publicPort))
	if code != 200 {
		t.Fatalf("after restart /proxies status %d", code)
	}
	t.Log("END TO END OK")
}
