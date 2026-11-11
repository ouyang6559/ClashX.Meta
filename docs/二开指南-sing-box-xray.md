# ClashX.Meta 二次开发指南：接入 sing-box / xray 内核

> 面向第一次接触本项目的开发者。读完本文你将理解：这个项目是怎么把 Go 代理内核"塞进" macOS App 的、Swift 和 Go 之间怎么通信、以及要支持 sing-box 和 xray 分别需要动哪些地方、各自的工作量有多大。
>
> 文档基于当前仓库代码（core 还挂在 `Dreamacro/clash` 的 2022-03 快照）撰写，所有文件路径和函数名都是真实存在的，可以直接搜索定位。

---

## 目录

1. [先想清楚：你到底想要什么](#1-先想清楚你到底想要什么)
2. [项目架构总览](#2-项目架构总览)
3. [环境搭建与第一次编译](#3-环境搭建与第一次编译)
4. [代码导读：关键文件地图](#4-代码导读关键文件地图)
5. [核心机制详解：Go 是怎么被嵌进 App 的](#5-核心机制详解go-是怎么被嵌进-app-的)
6. [方案对比与推荐路线](#6-方案对比与推荐路线)
7. [实战 A：接入 sing-box（推荐，工作量最小）](#7-实战-a接入-sing-box推荐工作量最小)
8. [实战 B：接入 xray-core（难度较高）](#8-实战-b接入-xray-core难度较高)
9. [配置格式转换：订阅怎么办](#9-配置格式转换订阅怎么办)
10. [Swift 侧 UI 改动清单](#10-swift-侧-ui-改动清单)
11. [打包、签名与分发](#11-打包签名与分发)
12. [常见坑 FAQ](#12-常见坑-faq)
13. [参考资料](#13-参考资料)

---

## 1. 先想清楚：你到底想要什么

"支持 sing-box 和 xray"这句话背后其实是三种完全不同的需求，工作量天差地别。动手前先对号入座：

| 你的真实需求 | 推荐方案 | 大致工作量 |
|---|---|---|
| 只是想支持 VLESS / XTLS / Reality / Hysteria2 这些"xray 系"协议 | **方案 A：把内核整体换成 sing-box** | ★☆☆ 两三周业余时间 |
| 想保留 clash/mihomo 内核，同时加一个 sing-box 内核让用户切换 | **方案 B：双内核并存** | ★★☆ 需要抽象出一层内核接口 |
| 必须使用真正的 xray-core（完整 XTLS 行为、xray 独有特性） | **方案 C：嵌入 xray-core** | ★★★ 需要自己写 API 适配层 |

**一个重要的事实**：sing-box 本身原生支持 VMess / VLESS / XTLS / Reality / Trojan / Hysteria 等"xray 系"协议。也就是说，**大多数"想支持 xray"的需求，用方案 A（sing-box）就已经满足了**，根本不需要把 xray-core 塞进来。只有在你要 100% 复刻 xray-core 的行为时才值得走方案 C。

---

## 2. 项目架构总览

这个 App 一共四层，画成图是这样：

```
┌─────────────────────────────────────────────────────────┐
│  ClashX.app（一个 macOS 菜单栏 Swift 应用）                │
│                                                         │
│  ┌───────────────┐   HTTP/WS    ┌────────────────────┐  │
│  │ Swift UI 层    │◄────────────►│ Clash REST API      │  │
│  │ 菜单/设置/订阅  │ 127.0.0.1:端口│ (核心内置的HTTP服务) │  │
│  └───────┬───────┘              └─────────▲──────────┘  │
│          │ 直接调用 C 函数                  │             │
│          ▼                                │             │
│  ┌────────────────────────────────────────┴──────────┐  │
│  │ Go 桥接层 ClashX/goClash/main.go（cgo，编成静态库）   │  │
│  │  initClashCore / run / clashUpdateConfig / ...     │  │
│  └───────────────────────┬───────────────────────────┘  │
│                          │ 函数调用                       │
│  ┌───────────────────────▼───────────────────────────┐  │
│  │ 代理内核（clash，未来可以换成 sing-box / xray-core）  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
            │ XPC（root 权限）
            ▼
┌─────────────────────────────────────────────────────────┐
│ ProxyConfigHelper（特权 Helper，只干一件事：设置系统代理）   │
└─────────────────────────────────────────────────────────┘
```

四个要点：

1. **内核不是独立进程，而是编译成静态库直接链接进 App**。所以没有"启动 clash 可执行文件"这回事，App 退出内核就死了。
2. **Swift UI 和内核之间不走 C 函数传流量数据**，而是走内核自带的 HTTP REST API（127.0.0.1:xxxx）。菜单上的延迟测试、连接列表、实时速率，全都是 Swift 发 HTTP 请求拿的。
3. **特权 Helper 和代理功能无关**，它只负责以 root 权限改系统网络设置（HTTP/SOCKS 代理地址）。内核挂了它也照常工作。
4. **配置文件在 `~/.config/clash/`**（见 `ClashX/Macro/Paths.swift:10`），App 自己不解析代理节点，解析全在 Go 内核里。

---

## 3. 环境搭建与第一次编译

### 3.1 需要装的东西

| 工具 | 用途 | 安装方式 |
|---|---|---|
| Xcode 13+ | 编 Swift/ObjC | App Store 或 xcodes |
| Go 1.18+ | 编代理内核 | `brew install go` |
| Python 3 | 跑内核构建脚本 | `brew install python3`（macOS 自带的也行） |
| Ruby + Bundler | 装 CocoaPods 依赖 | `brew install ruby bundler` |

### 3.2 一键准备依赖

仓库根目录的 `install_dependency.sh` 做了五件事，建议逐条理解而不是无脑跑：

```bash
#!/bin/bash
# 1. 编译 Go 内核 → 生成 ClashX/goClash/goClash.a + goClash.h
python3 build_clash_universal.py
# 2. 安装 CocoaPods 依赖（Alamofire/RxSwift/Sparkle 等）
bundle install && bundle exec pod install
# 3. 下载 GeoIP 数据库 → ClashX/Resources/Country.mmdb.gz
curl -LO https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb
# 4. clone clash-dashboard 网页面板 → ClashX/Resources/dashboard
git clone -b gh-pages https://github.com/Dreamacro/clash-dashboard.git dashboard
```

### 3.3 编译运行

```bash
bash install_dependency.sh
# 注意：必须打开 workspace，不是 xcodeproj！
open ClashX.xcworkspace
# Xcode 里选 ClashX target，Cmd+R
```

第一次编译大概率会遇到的问题，直接跳到 [第 12 节 FAQ](#12-常见坑-faq)。

---

## 4. 代码导读：关键文件地图

二开会碰到的文件其实不多，按重要性排序：

| 文件 | 作用 | 二开时的角色 |
|---|---|---|
| `ClashX/goClash/main.go` | Go 桥接层，导出 7 个 C 函数给 Swift | **改动最频繁的文件** |
| `ClashX/goClash/go.mod` | 内核依赖声明（当前指向 `Dreamacro/clash`） | 换内核第一步就是改它 |
| `ClashX/goClash/build_clash_universal.py` | 把内核编成 macOS 双架构静态库 | 换内核时改编译参数 |
| `ClashX/goClash/goClash.h` / `goClash.a` | cgo 生成的头文件 + 双架构静态库（已提交进仓库） | 构建产物 |
| `ClashX/AppDelegate.swift` | App 入口，`initClashCore()`/`run()` 都在这里调 | 适配启动流程 |
| `ClashX/General/ApiRequest.swift` | 封装对内核 REST API 的所有请求（HTTP + WebSocket） | **决定 UI 兼容性的关键** |
| `ClashX/General/Managers/ConfigManager.swift` | 端口号、apiSecret、配置文件管理等全局状态 | 小改 |
| `ClashX/General/Managers/RemoteConfigManager.swift` | 订阅下载/更新，用 `verifyClashConfig` 校验配置 | 订阅格式适配 |
| `ClashX/General/Managers/ClashResourceManager.swift` | GeoIP mmdb 的安装与下载 | 换 GeoIP 机制时动 |
| `ClashX/General/Managers/PrivilegedHelperManager.swift` | 安装/管理特权 Helper | 一般不用动 |
| `ProxyConfigHelper/`（独立 target） | root 特权 XPC 服务，改系统代理设置 | 一般不用动 |
| `ClashX/Macro/Paths.swift` | 配置目录 `~/.config/clash/` 等路径常量 | 小改 |
| `ClashX/General/Managers/MenuItemFactory.swift` + `ClashX/Views/` | 菜单栏 UI | 加"内核切换"菜单时动 |

### Swift 调用 Go 的完整调用链

启动时（`AppDelegate.swift`）：

```
applicationDidFinishLaunching
  → initClashCore()                     // Go: 设置内核配置文件路径
  → startProxy()
      → setUIPath(dashboard路径)         // Go: 让内核托管 dashboard 静态页
      → run(builtInApiMode, allowLan)   // Go: 读配置→起代理→起REST API
        返回 JSON: {"externalController":"127.0.0.1:52341","secret":""}
      → apiPort / apiSecret 存进 ConfigManager
  → ApiRequest.requestConfigUpdate(...)  // HTTP PUT /configs 让内核加载配置
```

之后的日常通信全部是 HTTP（`ApiRequest.swift`）：

| 端点 | 用途 |
|---|---|
| `GET/PUT/PATCH /configs` | 读/换/改配置（模式、日志级别） |
| `GET /proxies` | 节点与策略组列表、测延迟 |
| `GET /providers/proxies` | 代理集合 |
| `GET /rules` | 规则列表 |
| `GET/DELETE /connections` | 当前连接 |
| `WS /traffic` | 实时上下行速率 |
| `WS /logs?level=xx` | 实时日志 |

**记住这张表**：换成 sing-box 或 xray 后，UI 能不能少改，取决于新内核能不能继续提供这些端点。这是整个二开的核心判断依据。

---

## 5. 核心机制详解：Go 是怎么被嵌进 App 的

### 5.1 cgo + c-archive

`ClashX/goClash/main.go` 的开头是：

```go
package main
import "C"   // 启用 cgo
```

`build_clash_universal.py` 用这条命令把它变成静态库：

```bash
go build -buildmode=c-archive -o goClash_arm64.a   # 再来一遍 amd64
```

`c-archive` 会生成一个 `.a` 静态库 + 一个 `goClash.h` C 头文件。凡是写成 `//export 函数名` 的 Go 函数，都会出现在头文件里，Swift 通过桥接头（`ClashX-Bridging-Header.h` 里的 `#import "goClash.h"`）就能直接调用。

脚本会把 amd64 和 arm64 两个库用 `lipo` 合并成通用库 `goClash.a`（这就是 Apple Silicon + Intel 双支持的来源），合并前有一个 **`filecmp` 校验：两个架构生成的 `goClash.h` 必须逐字节一致**，否则直接 `exit(-1)`。改 `main.go` 导出函数签名时两个架构必须同步，不然就会在这里卡住。

### 5.2 七个导出函数（这就是你要"重写"的全部 Go 接口）

```go
initClashCore()                                  // 初始化配置路径
verifyClashConfig(content) -> error字符串         // 校验配置合法性（订阅下载后调用）
run(checkConfig, allowLan) -> JSON字符串          // 启动内核，返回 API 地址和 secret
setUIPath(path)                                  // 托管 dashboard 静态文件
clashUpdateConfig(path) -> error字符串            // 热更新配置
clashGetConfigs() -> JSON字符串                   // 返回当前 General 配置
verifyGEOIPDataBase() -> bool                    // 校验 GeoIP 数据库
```

**好消息**：这些函数签名就是 Swift 侧依赖的全部 Go 接口。只要新内核实现同样签名的函数，Swift 几乎不用动。这就是二开的主策略：**保接口、换实现**。

### 5.3 REST API 是怎么来的

`main.go` 里的 `parseDefaultConfigThenStart` 做了这些事：

```go
go route.Start(cfg.General.ExternalController, cfg.General.Secret) // 起 HTTP API 服务
executor.ApplyConfig(cfg, true)                                    // 应用配置，开始代理
```

`route.Start` 是 clash 内核自带的 REST API 服务器。sing-box 有一个设计上专门对标它的组件（`experimental.clash_api`），而 xray-core **没有**——这是两者二开难度差异巨大的根源，后面详述。

---

## 6. 方案对比与推荐路线

| | 方案 A：换 sing-box | 方案 B：双内核并存 | 方案 C：嵌入 xray-core |
|---|---|---|---|
| 协议支持 | VMess/VLESS/Trojan/SS/Hysteria2/Reality/TUIC… | 两者并集 | xray 全部 |
| Clash REST API | ✅ 内置 `clash_api` 兼容层 | 原内核有；sing-box 有 | ❌ 没有，要自己造 |
| Swift UI 改动 | 很小（容错处理） | 中（加内核切换逻辑） | 大（或写 Go 适配层） |
| 订阅格式 | 需转换（clash yaml → sing-box json） | 按内核分别转换 | 需转换（→ xray json） |
| Go 桥接层 | 重写 main.go 的 7 个函数 | 两套导出函数 + 分发 | 重写 + 自建 API 服务 |
| 风险 | sing-box API 变动较快，注意锁版本 | 状态管理复杂度高 | 工作量最大，收益最小 |

**推荐：先做方案 A，跑通后再演进到方案 B。** 方案 B 的本质是"把方案 A 的代码再抽象一层"，直接做 B 会同时面对所有问题。除非你有明确的 xray-core 独占需求，否则不建议做 C。

---

## 7. 实战 A：接入 sing-box（推荐，工作量最小）

### 7.1 为什么 sing-box 是"亲儿子"级别的好换

sing-box 官方内置了 **`clash_api`** 实验模块：启用后它会提供一个和 clash 几乎兼容的 REST API（`/proxies`、`/connections`、`/traffic`、`/logs`、`/configs`……）。也就是说，本项目的整套 UI（菜单、连接面板、速率显示、甚至内嵌的 clash-dashboard 网页）**大部分可以直接沿用**，因为它们依赖的 API sing-box 都有。

### 7.2 第一步：替换 Go 依赖

编辑 `ClashX/goClash/go.mod`：

```go
module github.com/yichengchen/clashX/ClashX

require (
    github.com/sagernet/sing-box v1.x.x   // 锁一个明确的版本！
    github.com/phayes/freeport ...
)
```

> ⚠️ sing-box 在 1.x 各版本间 API 变动比较频繁（尤其 `box.New` 的签名）。选定版本后**不要随意升级**，先在本地跑通再考虑。当前仓库用的是 go 1.18，sing-box 新版本要求更高的 go 版本，记得同步改 `go 1.xx` 指令。

```bash
cd ClashX/goClash
go mod tidy   # 会自动下载依赖并更新 go.sum
```

### 7.3 第二步：重写 main.go 的七个导出函数

保留函数签名，替换实现。骨架示例（以 sing-box 1.x 为例，实际请对照你锁定的版本文档调整）：

```go
package main

import (
	"C"
	"context"
	"encoding/json"
	"net/http"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
	"github.com/phayes/freeport"
)

var instance *box.Box

//export initSingBoxCore
func initSingBoxCore() {
	// 对应原 initClashCore：初始化配置路径等全局状态
}

//export verifySingBoxConfig
func verifySingBoxConfig(content *C.char) *C.char {
	// 用 sing-box 的配置解析器试解析，失败返回错误字符串
	// Swift 侧 RemoteConfigManager.verifyConfig 依赖这个返回 "success"
	return C.CString("success")
}

//export run
func run(checkConfig, allowLan bool) *C.char {
	// 1. 读 ~/.config/clash/config.json（或继续用 yaml，先转换，见第9节）
	// 2. 解析成 option.Options
	options, err := parseOptions(configBytes)
	if err != nil {
		return C.CString(err.Error())
	}
	// 3. 仿照原逻辑：给 clash_api 分配一个空闲端口
	port, _ := freeport.GetFreePort()
	injectClashAPI(&options, "127.0.0.1:"+strconv.Itoa(port)) // 见 7.4

	// 4. 创建并启动
	instance = box.New(box.Context{Context: context.Background(), Options: options})
	if err := instance.Start(); err != nil {
		return C.CString(err.Error())
	}
	// 5. 返回和原来一模一样的 JSON，Swift 侧零改动
	resp, _ := json.Marshal(map[string]string{
		"externalController": "127.0.0.1:" + strconv.Itoa(port),
		"secret":             apiSecret,
	})
	return C.CString(string(resp))
}

//export stop
func stop() {
	if instance != nil {
		instance.Close()
	}
}
```

> 💡 注意 App 退出时最好调用内核的关闭逻辑（在 `AppDelegate.applicationShouldTerminate` 里加），clash 时代没有严格清理也能活，sing-box 建议 Close 干净，尤其是以后开 TUN 时。

### 7.4 第三步：注入 clash_api 配置

用户订阅里不会带 `clash_api` 段，所以要在 Go 侧**程序化注入**（等价于原来 `parseDefaultConfigThenStart` 里对端口的处理逻辑）：

```json
{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:52341",
      "secret": "",
      "default_mode": "rule"
    }
  }
}
```

这样 `run()` 返回给 Swift 的端口就是 clash_api 的监听端口，`ApiRequest.swift` 里的请求照发，UI 照常工作。

### 7.5 第四步：处理已知差异

sing-box 的 clash_api 不是 100% 兼容，实测需要容错的点：

| 依赖点 | 差异 | 处理建议 |
|---|---|---|
| `GET /providers/proxies` | sing-box 对 provider 端点支持有限 | `ApiRequest` 相关回调判空容错，UI 隐藏对应入口 |
| 测延迟 `GET /proxies/{name}/delay` | 支持，但超时参数行为略有不同 | 基本无痛 |
| `PUT /configs`（Path 热切换） | sing-box 不支持按路径热加载 | 改成"关实例→重建实例"，在 Go 侧封装 |
| `WS /logs` 的日志格式 | 字段略有差异 | dashboard 基本能显示 |
| dashboard 网页面板 | clash-dashboard 大部分功能可用 | 可换成 metacubexd / yacd-meta 体验更好 |

### 7.6 第五步：更新构建脚本

`build_clash_universal.py` 里的版本号提取逻辑是从 go.mod 里 grep "clash" 关键字，换成 sing-box 后要改：

```python
def get_version():
    # 原来 grep clash，现在要适配 sing-box 的行
    for line in open('./go.mod'):
        if "sing-box" in line:
            return line.split("v")[-1][:6]
```

同时注意 `go build -ldflags '-X "github.com/Dreamacro/clash/constant.Version=..."'` 这类注入也要换成 sing-box 对应的版本变量（或直接删掉）。

### 7.7 验收清单

- [ ] `python3 build_clash_universal.py` 通过，`goClash.a` 正常生成
- [ ] App 启动后菜单显示运行状态，`/traffic` 速率正常滚动
- [ ] 订阅导入 → 校验 → 节点列表 → 测延迟 → 选择节点 → 系统代理可上网
- [ ] 连接面板、日志面板工作
- [ ] 切换配置文件（菜单 Config）正常

---

## 8. 实战 B：接入 xray-core（难度较高）

### 8.1 先泼冷水：难点在哪

1. **xray-core 没有任何 clash 风格的 REST API**。它的管理接口是 gRPC（`StatsService`、`HandlerService`），而本项目整套 UI（包括内嵌网页面板）都建立在 REST + WebSocket 之上。
2. **配置模型完全不同**：clash/sing-box 是"节点列表 + 策略组"模型，xray 是"inbound/outbound + routing 规则"模型，没有策略组概念。UI 上的"节点选择菜单"需要自己实现映射。
3. **没有按名字测延迟的现成 API**（有 `observer`，但输出模型不同）。

### 8.2 两条子路线

**路线 C-1（推荐）：Go 侧自建 Clash 风格 API 适配层。**

思路：既然都在同一个进程里（c-archive），Go 桥接层可以直接读 xray 的内存状态，用一个自己的 HTTP 服务器（`net/http` 就够，原来 clash 的 chi 路由思路可以照搬）对外提供 clash 风格端点：

```go
import (
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/features/stats"
)

func startXray(configJSON []byte) (*core.Instance, error) {
	pbConfig, err := serial.DecodeJSONConfig(bytes.NewReader(configJSON))
	if err != nil { return nil, err }
	built, err := pbConfig.Build()
	if err != nil { return nil, err }
	inst, err := core.New(built)
	if err != nil { return nil, err }
	inst.Start()
	return inst, nil
}

// 实时速率：直接读进程内的 stats 计数器，完全不需要 gRPC！
func trafficSnapshot() (up, down int64) {
	mgr := instance.GetFeature(stats.ManagerType()).(stats.Manager)
	upCtr := mgr.GetCounter("outbound>>>traffic>>>uplink")
	downCtr := mgr.GetCounter("outbound>>>traffic>>>downlink")
	return upCtr.Set(0), downCtr.Set(0) // 读后清零，实现"每秒速率"
}
```

然后在 Go 桥里实现一个极简 HTTP 服务：

| 需要实现 | 数据来源 | 难度 |
|---|---|---|
| `WS /traffic` | 上面的 stats 计数器，每秒推送 | 简单 |
| `GET /configs` + `PATCH /configs`（mode） | 自己维护的内存状态 | 简单 |
| `GET /proxies` | routing 配置 + handler 状态 | 中 |
| 节点切换 | `HandlerService`（gRPC 或进程内 feature 调用）重建 outbound | 中 |
| `GET /connections` / 按连接关闭 | xray 无此模型，只能做总量或放弃 | 看取舍 |
| `WS /logs` | xray log 模块自定义 handler | 简单 |

这样 Swift 侧依旧"以为"自己在和一个 clash 内核说话，改动集中在 Go 层。

**路线 C-2：Swift 直接说 gRPC。** 用 grpc-swift + protobuf 生成 StatsService 客户端。改动面大、学习成本高，除非你本来就想重写 API 层，否则不推荐。

### 8.3 按名字测延迟的土办法

xray 没有现成的"某节点延迟"接口。常见做法：Go 桥里针对选中节点临时起一个一次性 inbound（本地 socks 端口），通过它发起一个到 `gstatic.com/generate_204` 的 HTTP 请求，用耗时当延迟。这是各 xray GUI 客户端的通行做法。

### 8.4 什么时候值得做 C

- 你需要 xray 独有的行为细节（比如完整的 XTLS Flow 生态、xray 特有的分流语法）。
- 你有现成的 xray JSON 配置生态要兼容（用户直接粘贴 xray 配置）。

否则请回到方案 A——**sing-box 对 VLESS/Reality/XTLS 的支持已经覆盖绝大多数场景**。

---

## 9. 配置格式转换：订阅怎么办

### 9.1 现状

- 本项目下载的订阅是 **clash yaml 格式**（`RemoteConfigManager` 下载后用 `verifyClashConfig` 让内核校验）。
- sing-box 用 **JSON**；xray 用 **JSON（v2ray 风格）**。
- 三者没有通用格式，必须转换。

### 9.2 同一个节点在三种格式里的样子

以一个 VMess 节点为例：

```yaml
# clash (yaml)
proxies:
  - name: "我的节点"
    type: vmess
    server: example.com
    port: 443
    uuid: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    alterId: 0
    cipher: auto
    tls: true
```

```json
// sing-box (outbound 片段)
{
  "type": "vmess",
  "tag": "我的节点",
  "server": "example.com",
  "server_port": 443,
  "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "security": "auto",
  "tls": { "enabled": true }
}
```

```json
// xray (outbound 片段)
{
  "tag": "我的节点",
  "protocol": "vmess",
  "settings": {
    "vnext": [{
      "address": "example.com",
      "port": 443,
      "users": [{
        "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "alterId": 0,
        "security": "auto"
      }]
    }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls"
  }
}
```

### 9.3 转换器放哪一层？

**强烈建议放在 Go 侧**（`main.go` 或单独的包），原因：

1. Go 侧能拿到成熟的 yaml/json 库（`gopkg.in/yaml.v3`、`encoding/json`），而且 clash 节点结构体可以直接抄 clash 源码里的 `config.RawProxy` 定义。
2. 转换完直接交给内核校验，`verifyClashConfig` 的"下载→校验→保存"流程不用改。
3. Swift 侧对"订阅是 yaml"的假设可以完全保留，用户无感。

实现思路：`main.go` 里加一个内部步骤——`run()`/`verify` 拿到 yaml 后，先解析 `proxies:` 数组，逐条映射成目标内核的 outbound，再拼上固定的 inbound（本地混合端口）+ routing（sing-box）或 inbounds/outbounds/routing（xray），最后序列化成目标格式。

> 💡 社区有现成的转换工具可以参考映射表（如 subconverter、各种 sub-web 项目），抄字段映射比自己拍脑袋靠谱。vless/reality/hysteria2 等新协议字段较多，建议每支持一种协议就补一条映射并写单测。

### 9.4 策略组的坑（重点）

clash 订阅里的 `proxy-groups`（select/url-test/fallback）在 xray 里**没有对应物**。方案 C 需要自己在 App 层模拟"选择节点→切换 outbound"；sing-box 有 `selector`/`urltest` outbound 类型，可以近乎一一对应，这也是方案 A 顺手的另一个原因。

---

## 10. Swift 侧 UI 改动清单

无论哪个方案，UI 层大概率要做这些（按需取用）：

1. **加"内核引擎"菜单**（方案 B 必须，A 可选）
   - `ClashX/General/Managers/MenuItemFactory.swift` 里仿照 `generateSwitchConfigMenuItems` 加一组单选项。
   - 选择结果存 `UserDefaults`，重启内核时生效。
2. **配置文件后缀适配**
   - `ClashX/Macro/Paths.swift` 里 `Paths.configFileName(for:)` 目前固定 `.yaml`；sing-box/xray 建议内部统一 `.json`（或保持 yaml 由 Go 层转换，推荐后者，改动最小）。
3. **容错**：`ApiRequest.swift` 里对 `/providers/proxies` 等端点的响应判空，避免 sing-box/xray 没实现时 UI 崩溃。
4. **关于 TUN / 增强模式**
   - 本仓库的 `ProxyConfigHelper` **只负责系统 HTTP/SOCKS 代理，不含 TUN**。
   - 如果你想加 TUN（增强模式）：sing-box 自带 tun inbound（Go 侧配好即可，但需要 root 权限起 utun + 配路由，要给 App 加对应授权与 Helper 能力）；xray 需要自己实现或借助 sing-tun。这是一个独立的、不小的工作量，建议作为二期。
5. **`AppDelegate.applicationShouldTerminate`**
   - 补内核 Close/停机逻辑（原版没有显式停止，因为进程退出自然销毁；加 TUN 后必须清理路由，见各内核文档）。

---

## 11. 打包、签名与分发

1. **构建产物已入库**：`goClash.a`/`goClash.h` 是提交进仓库的。你自己改了内核后要重新生成并提交，否则别人拉代码编的还是旧内核。CI（如果有）会执行 `install_dependency.sh`，记得保持脚本与新内核兼容。
2. **版本号注入**：`build_clash_universal.py` 在 CI 环境下会把内核版本写进 `ClashX/info.plist` 的 `coreVersion` 字段（菜单"关于"里显示的就是它）。换内核后同样改这里。
3. **双架构**：脚本分别编 amd64/arm64 再 `lipo` 合并，新内核照用，别只编一个架构。
4. **最低系统版本**：`CGO_LDFLAGS`/`CGO_CFLAGS` 里的 `-mmacosx-version-min=10.12` 和 Podfile 的 deployment target 要保持一致，Go 侧不要单独抬高。
5. **签名与 Helper**：特权 Helper（SMJobBless）对签名极其敏感——主 App 和 Helper 的证书 Team ID、`SMPrivilegedExecutables` 匹配规则一个字符都不能错。本地开发建议直接跑（Xcode 会用开发签名），分发才需要处理完整公证。Sparkle 更新（`AutoUpgardeManager`）同理依赖 appcast 与签名配置。
6. **严格来说**，使用系统代理模式（Helper 改网络设置）+ 非官方分发的代理工具，在不同地区的分发渠道可能有合规风险，自行评估。

---

## 12. 常见坑 FAQ

**Q1：`build_clash_universal.py` 在 `mergeLibs` 处 `exit(-1)`？**
两个架构生成的 `goClash.h` 不一致（`filecmp` 校验失败）。通常是你改了导出函数但条件编译导致两个架构签名不同；检查是否引入了带架构差异的 `//export`。

**Q2：`go mod tidy` 报错或卡住？**
sing-box/xray 的依赖需要较新 Go 版本；另外确认代理环境正常（`go env -w GOPROXY=https://goproxy.cn,direct` 国内常用）。仓库自带的 go.sum 是旧内核的，tidy 后会大量变动，这是正常的（当前 git 状态里 go.mod/go.sum 就有未提交改动）。

**Q3：编译通过但 App 启动就闪退 / 菜单灰色？**
看 `Console.app` 或 Xcode 控制台的 `Logger.log` 输出。常见原因：配置文件不存在或格式不合法（`run()` 返回了错误字符串）、端口被占用（原代码有 `freeport` 兜底逻辑，确认你保留了）。

**Q4：dashboard 页面空白？**
`ClashX/Resources/dashboard` 需要按 `install_dependency.sh` clone gh-pages 分支，忘了 clone 就是空白。换 sing-box 后建议换 metacubexd。

**Q5：订阅校验失败 "No proxy found in config"？**
`verifyClashConfig` 要求至少一个节点。确认你的格式转换器真的把 `proxies` 转成了目标内核的 outbound，且 inbound（本地监听端口）也配了。

**Q6：能不能不嵌库、改成外部进程方式跑 sing-box/xray？**
可以（下载内核二进制 + `Process` 启动），生命周期更隔离、崩溃不连累 App，也是不少客户端的做法。但本项目现有代码全是进程内模型（直接函数调用 + 同进程 REST），改外部进程等于重写启动/停止/更新逻辑。作为二开的"第二阶段"可以考虑，第一步不建议。

**Q7：老 `upgrade_core.py` 还能用吗？**
它只是把 go.mod 里的版本号改成 `dev` 后重新拉取构建，是给原 clash 内核用的维护脚本。换内核后要么改写它，要么删掉避免误导。

---

## 13. 参考资料

- 项目本体
  - 上游仓库：https://github.com/MetaCubeX/ClashX.Meta
  - 原版 ClashX（本项目的直系祖先）：https://github.com/yichengchen/clashX
- 内核
  - sing-box：https://github.com/SagerNet/sing-box （文档 https://sing-box.sagernet.org ，重点读 `experimental.clash_api` 与 `option` 包）
  - xray-core：https://github.com/XTLS/Xray-core （文档 https://xtls.github.io ，重点读 config 全貌与 `app/stats`、`app/proxyman/command`）
  - mihomo（上游 ClashX.Meta 现用内核，升级可参考）：https://github.com/MetaCubeX/mihomo
- 格式转换参考
  - subconverter（字段映射的活字典）：https://github.com/tindy2013/subconverter
- 关键 Go 技术
  - cgo 与 c-archive：`go help c` ；本项目示例就在 `ClashX/goClash/main.go`
  - lipo 多架构合并：`man lipo`

---

*文档生成于 2026-10-29，基于仓库 commit `471b3e0`。内核版本变化较快，具体 API 以你锁定的 sing-box / xray-core 版本文档为准。*
