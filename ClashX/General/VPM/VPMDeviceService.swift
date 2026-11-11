//
//  VPMDeviceService.swift
//  ClashX
//
//  登录模式下的设备注册与 Clash 订阅导入：
//  登录成功 → 查询设备（空则自动创建）→ 获取 format=clash 订阅链接 →
//  去重后导入 RemoteConfigManager（复用其定时更新机制）。订阅链接含 token，禁止写日志。
//

import Cocoa

class VPMDeviceService {
    static let shared = VPMDeviceService()

    private static let subscriptionName = "VPM 订阅"
    private static let clashFormat = "clash"
    private var importing = false

    /// 登录态变化后调用：已登录则确保设备存在并导入订阅。
    func ensureSubscriptionAfterLogin() {
        guard Settings.vpmLoginModeEnabled, VPMAPIClient.isLoggedIn, !importing else { return }
        importing = true
        ensureDeviceAndSubscription { [weak self] result in
            guard let self = self else { return }
            self.importing = false
            switch result {
            case let .success(url):
                if let url = url {
                    self.importSubscription(url: url)
                }
            case let .failure(error):
                Logger.log("VPM ensure subscription failed: \(error.reason)", level: .warning)
                NSUserNotificationCenter.default.post(title: NSLocalizedString("vpm.subscription.title", comment: ""),
                                                      info: error.displayMessage)
            }
        }
    }

    // MARK: - Device orchestration

    func ensureDeviceAndSubscription(completeHandler: @escaping (Result<String?, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/devices") { [weak self] (result: Result<VPMDeviceListResponse, VPMError>) in
            guard let self = self else { return }
            switch result {
            case let .success(list):
                let active = list.items.filter { $0.status != "DELETED" }
                if let existing = active.first {
                    self.fetchSubscription(deviceId: existing.id, completeHandler: completeHandler)
                } else {
                    self.createDevice { createResult in
                        switch createResult {
                        case let .success(device):
                            self.fetchSubscription(deviceId: device.id, completeHandler: completeHandler)
                        case let .failure(error):
                            completeHandler(.failure(error))
                        }
                    }
                }
            case let .failure(error):
                completeHandler(.failure(error))
            }
        }
    }

    private func createDevice(completeHandler: @escaping (Result<VPMDeviceCreateResponse, VPMError>) -> Void) {
        let body: [String: Any] = ["name": Host.current().localizedName ?? "ClashX", "platform": "macos"]
        VPMAPIClient.shared.request("/api/v1/devices", method: .post, body: body) { (result: Result<VPMDeviceCreateResponse, VPMError>) in
            completeHandler(result)
        }
    }

    private func fetchSubscription(deviceId: String, completeHandler: @escaping (Result<String?, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/devices/\(deviceId)/subscription") { (result: Result<VPMDeviceSubscriptionResponse, VPMError>) in
            switch result {
            case let .success(resp):
                completeHandler(.success(resp.subscriptionUrls[VPMDeviceService.clashFormat]))
            case let .failure(error):
                completeHandler(.failure(error))
            }
        }
    }

    // MARK: - Subscription import

    /// 去重导入：同名配置更新 URL，否则新增 RemoteConfigModel 并立即拉取。
    func importSubscription(url: String) {
        guard url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("http://") else { return }
        if let existing = RemoteConfigManager.shared.configs.first(where: { $0.name == VPMDeviceService.subscriptionName }) {
            if existing.url == url { return } // 订阅 token 未变化
            existing.url = url
        } else {
            let config = RemoteConfigModel(url: url, name: VPMDeviceService.subscriptionName)
            RemoteConfigManager.shared.configs.append(config)
        }
        RemoteConfigManager.shared.saveConfigs()
        let config = RemoteConfigManager.shared.configs.first { $0.name == VPMDeviceService.subscriptionName }
        guard let config = config, !config.updating else { return }
        config.updating = true
        RemoteConfigManager.updateConfig(config: config) { [weak config] errorString in
            guard let config = config else { return }
            config.updating = false
            if errorString == nil {
                config.updateTime = Date()
                RemoteConfigManager.shared.saveConfigs()
            } else {
                Logger.log("VPM subscription update failed: \(errorString ?? "")", level: .warning)
                NSUserNotificationCenter.default.post(title: NSLocalizedString("vpm.subscription.title", comment: ""),
                                                      info: NSLocalizedString("vpm.subscription.updateFailed", comment: ""))
            }
        }
    }

    /// 订阅 URL 是否已导入（账户页展示用）。
    var subscriptionImported: Bool {
        return RemoteConfigManager.shared.configs.contains { $0.name == VPMDeviceService.subscriptionName }
    }
}
