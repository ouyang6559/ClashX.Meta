//
//  VPMAccountWindowController.swift
//  ClashX
//
//  登录模式账户窗口：未登录展示认证视图，已登录展示账户详情。
//

import Cocoa

class VPMAccountWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = NSLocalizedString("vpm.account.title", comment: "")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        reloadContent()
    }

    func reloadContent() {
        if VPMAPIClient.isLoggedIn {
            window?.contentViewController = VPMAccountViewController()
        } else {
            window?.contentViewController = VPMLoginViewController()
        }
        window?.layoutIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.contentViewController = nil
        return true
    }
}

/// 已登录的账户视图（commit 6 扩展为权益/流量展示）。
class VPMAccountViewController: NSViewController {
    private let emailLabel = NSTextField(labelWithString: VPMAuthService.displayEmail)
    private let logoutButton = NSButton(title: NSLocalizedString("vpm.account.logout", comment: ""),
                                        target: nil,
                                        action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emailLabel.stringValue = VPMAuthService.displayEmail
        logoutButton.bezelStyle = .rounded
        logoutButton.target = self
        logoutButton.action = #selector(didTapLogout(_:))

        let stack = NSStackView(views: [emailLabel, logoutButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func didTapLogout(_ sender: NSButton) {
        VPMAuthService.logout()
        if let windowController = view.window?.windowController as? VPMAccountWindowController {
            windowController.reloadContent()
        }
    }
}
