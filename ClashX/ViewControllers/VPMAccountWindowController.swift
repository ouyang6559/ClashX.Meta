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

/// 已登录的账户视图：权益与流量展示 + 购买入口 + 退出登录。
class VPMAccountViewController: NSViewController {
    private let emailLabel = NSTextField(labelWithString: VPMAuthService.displayEmail)
    private let planLabel = NSTextField(labelWithString: "—")
    private let expiryLabel = NSTextField(labelWithString: "—")
    private let trafficLabel = NSTextField(labelWithString: "—")
    private let resetLabel = NSTextField(labelWithString: "—")
    private let progressBar = NSProgressIndicator()
    private let subscriptionLabel = NSTextField(labelWithString: "—")
    private let refreshButton = NSButton(title: NSLocalizedString("vpm.account.refresh", comment: ""),
                                         target: nil, action: nil)
    private let storeButton = NSButton(title: NSLocalizedString("vpm.store.buyPlan", comment: ""),
                                       target: nil, action: nil)
    private let logoutButton = NSButton(title: NSLocalizedString("vpm.account.logout", comment: ""),
                                        target: nil, action: nil)
    private var storeWindowController: VPMStoreWindowController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emailLabel.stringValue = VPMAuthService.displayEmail
        emailLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        for label in [planLabel, expiryLabel, trafficLabel, resetLabel, subscriptionLabel] {
            label.textColor = .labelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
        }
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.controlSize = .regular
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(didTapRefresh(_:))
        storeButton.bezelStyle = .rounded
        storeButton.target = self
        storeButton.action = #selector(didTapStore(_:))
        logoutButton.bezelStyle = .rounded
        logoutButton.target = self
        logoutButton.action = #selector(didTapLogout(_:))

        let infoStack = NSStackView(views: [planLabel, expiryLabel, progressBar, trafficLabel, resetLabel, subscriptionLabel])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8

        let buttonRow = NSStackView(views: [refreshButton, storeButton, logoutButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let rootStack = NSStackView(views: [emailLabel, infoStack, buttonRow])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 20
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            rootStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            progressBar.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            trafficLabel.widthAnchor.constraint(lessThanOrEqualTo: rootStack.widthAnchor),
        ])

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reload),
                                               name: .vpmEntitlementChanged,
                                               object: nil)
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reload() {
        loadEntitlement()
        loadTraffic()
        subscriptionLabel.stringValue = VPMDeviceService.shared.subscriptionImported
            ? NSLocalizedString("vpm.account.subscriptionImported", comment: "")
            : NSLocalizedString("vpm.account.subscriptionMissing", comment: "")
    }

    private func loadEntitlement() {
        VPMAPIClient.shared.request("/api/v1/entitlements/current") { [weak self] (result: Result<VPMENTitlement, VPMError>) in
            guard let self = self else { return }
            switch result {
            case let .success(ent):
                if ent.active, let product = ent.productName {
                    self.planLabel.stringValue = String(format: NSLocalizedString("vpm.account.planActive", comment: ""), product, ent.level)
                    self.expiryLabel.stringValue = String(format: NSLocalizedString("vpm.account.expiry", comment: ""),
                                                          VPMDateUtil.display(ent.endAt))
                } else {
                    self.planLabel.stringValue = NSLocalizedString("vpm.account.planFree", comment: "")
                    self.expiryLabel.stringValue = ""
                }
            case let .failure(error):
                self.planLabel.stringValue = error.displayMessage
            }
        }
    }

    private func loadTraffic() {
        VPMAPIClient.shared.request("/api/v1/dashboard") { [weak self] (result: Result<VPMDashboardResponse, VPMError>) in
            guard let self = self else { return }
            switch result {
            case let .success(resp):
                let traffic = resp.traffic
                self.trafficLabel.stringValue = String(format: NSLocalizedString("vpm.account.traffic", comment: ""),
                                                       VPMDateUtil.byteDisplay(traffic.usedBytes),
                                                       VPMDateUtil.byteDisplay(traffic.baseQuotaBytes),
                                                       Int(traffic.percent))
                self.progressBar.doubleValue = traffic.percent
                self.resetLabel.stringValue = String(format: NSLocalizedString("vpm.account.trafficReset", comment: ""),
                                                     VPMDateUtil.display(traffic.resetAt))
            case let .failure(error):
                self.trafficLabel.stringValue = error.displayMessage
            }
        }
    }

    @objc private func didTapRefresh(_ sender: NSButton) {
        reload()
    }

    @objc private func didTapStore(_ sender: NSButton) {
        if storeWindowController == nil {
            storeWindowController = VPMStoreWindowController()
        }
        storeWindowController?.show()
    }

    @objc private func didTapLogout(_ sender: NSButton) {
        VPMStoreService.shared.stopPolling()
        VPMAuthService.logout()
        if let windowController = view.window?.windowController as? VPMAccountWindowController {
            windowController.reloadContent()
        }
    }
}

/// 展示工具：RFC3339 时间与字节量。
enum VPMDateUtil {
    static func display(_ rfc3339: String?) -> String {
        guard let rfc3339 = rfc3339, let date = formatter.date(from: rfc3339) else { return "—" }
        return displayFormatter.string(from: date)
    }

    static func byteDisplay(_ minor: String) -> String {
        guard let bytes = Double(minor) else { return minor }
        let units: [String] = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? String(format: "%.0f%@", value, units[index]) : String(format: "%.2f%@", value, units[index])
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
