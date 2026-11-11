//
//  VPMLoginManager.swift
//  ClashX
//
//  登录模式菜单入口与账户窗口生命周期管理。
//  菜单项插入到 externalControlSeparator 之前，仅在登录模式开启时可见。
//

import Cocoa

class VPMLoginManager {
    static let shared = VPMLoginManager()

    private var menuItem: NSMenuItem?
    private var windowController: VPMAccountWindowController?

    func setupMenuItem(separator: NSMenuItem) {
        guard let menu = separator.menu else { return }
        let item = NSMenuItem(title: NSLocalizedString("vpm.menu.account", comment: ""),
                              action: #selector(showAccountWindow),
                              keyEquivalent: "")
        item.target = self
        item.isHidden = true
        let idx = menu.index(of: separator)
        menu.insertItem(item, at: max(0, idx))
        menuItem = item
        refreshVisibility()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(loginStateChanged),
                                               name: .vpmLoginStateChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionExpired),
                                               name: .vpmSessionExpired,
                                               object: nil)
    }

    func refreshVisibility() {
        menuItem?.isHidden = !Settings.vpmLoginModeEnabled
    }

    @objc private func loginStateChanged() {
        windowController?.reloadContent()
        if VPMAPIClient.isLoggedIn {
            // 登录成功：自动注册设备并导入 Clash 订阅。
            VPMDeviceService.shared.ensureSubscriptionAfterLogin()
        }
    }

    @objc private func sessionExpired() {
        NSUserNotificationCenter.default.post(title: NSLocalizedString("vpm.menu.account", comment: ""),
                                              info: NSLocalizedString("vpm.error.sessionExpired", comment: ""))
    }

    @objc func showAccountWindow() {
        if windowController == nil {
            windowController = VPMAccountWindowController()
        }
        windowController?.reloadContent()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
