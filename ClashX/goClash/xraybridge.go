package main

import (
	"bytes"
	"fmt"
	"strings"

	// registers all xray features/protocols for library use
	_ "github.com/xtls/xray-core/main/distro/all"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
)

// xrayBridge runs one embedded Xray-core instance. Each bridged proxy gets a
// local socks inbound; traffic is routed inboundTag -> outboundTag.
type xrayBridge struct {
	instance *core.Instance
	nodes    []xrayNode
}

func newXrayBridge(nodes []xrayNode) (*xrayBridge, error) {
	if len(nodes) == 0 {
		return nil, nil
	}
	inbounds := []map[string]any{}
	outbounds := []map[string]any{}
	rules := []map[string]any{}
	for i, node := range nodes {
		inTag := fmt.Sprintf("vp_in_%d", i)
		outTag := fmt.Sprintf("vp_out_%d", i)
		inbounds = append(inbounds, map[string]any{
			"tag":    inTag,
			"listen": "127.0.0.1",
			"port":   node.LocalPort,
			"protocol": "socks",
			"settings": map[string]any{"udp": true},
		})
		ob := node.Outbound
		ob["tag"] = outTag
		outbounds = append(outbounds, ob)
		rules = append(rules, map[string]any{
			"type":        "field",
			"inboundTag":  []string{inTag},
			"outboundTag": outTag,
		})
	}
	// A final blackhole keeps xray from dialing unmatched traffic directly.
	outbounds = append(outbounds, map[string]any{
		"tag":      "vp_block",
		"protocol": "blackhole",
		"settings": map[string]any{},
	})
	rules = append(rules, map[string]any{
		"type":        "field",
		"network":     "tcp,udp",
		"outboundTag": "vp_block",
	})
	config := map[string]any{
		"log":       map[string]any{"loglevel": "warning"},
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"routing":   map[string]any{"rules": rules},
	}
	raw := jsonMarshal(config)
	pbConfig, err := serial.DecodeJSONConfig(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("xray decode config: %w", err)
	}
	coreConfig, err := pbConfig.Build()
	if err != nil {
		return nil, fmt.Errorf("xray build config: %w", err)
	}
	instance, err := core.New(coreConfig)
	if err != nil {
		return nil, fmt.Errorf("xray new instance: %w", err)
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		return nil, fmt.Errorf("xray start: %w", err)
	}
	return &xrayBridge{instance: instance, nodes: nodes}, nil
}

func (b *xrayBridge) Close() {
	if b != nil && b.instance != nil {
		b.instance.Close()
		b.instance = nil
	}
}

// xrayNodeSummary is used for logging.
func (b *xrayBridge) Summary() string {
	if b == nil {
		return "none"
	}
	names := make([]string, 0, len(b.nodes))
	for _, n := range b.nodes {
		names = append(names, fmt.Sprintf("%s(127.0.0.1:%d)", n.Name, n.LocalPort))
	}
	return strings.Join(names, ", ")
}
