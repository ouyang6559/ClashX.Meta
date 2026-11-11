//
//  VPMLoginViewController.swift
//  ClashX
//
//  登录模式账户窗口的认证视图：登录 / 注册 / 找回密码 三段切换。
//

import Cocoa

class VPMLoginViewController: NSViewController {
    private let modeSegment = NSSegmentedControl(labels: [NSLocalizedString("vpm.auth.tab.login", comment: ""),
                                                          NSLocalizedString("vpm.auth.tab.register", comment: ""),
                                                          NSLocalizedString("vpm.auth.tab.forgot", comment: "")],
                                                 trackingMode: .selectOne,
                                                 target: nil,
                                                 action: nil)
    private let emailTextField = NSTextField(string: "")
    private let passwordTextField = NSSecureTextField(string: "")
    private let tokenTextField = NSTextField(string: "")
    private let extraTextField = NSTextField(string: "")
    private let tokenLabel = NSTextField(labelWithString: "")
    private let extraLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "登录", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let thirdPartyContainer = NSStackView(views: [])

    private lazy var tokenRow = makeRow(label: tokenLabel, field: tokenTextField, fixedFieldWidth: 140)
    private lazy var extraRow = makeRow(label: extraLabel, field: extraTextField, fixedFieldWidth: 140)
    private var sendCodeButton: NSButton?

    private var oauthProviders: [VPMOAuthProvider] = []
    private var telegramCode: String?
    private var telegramPollTimer: Timer?
    private let telegramStatusLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        switchMode(0)
        loadOAuthProviders()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(oauthFailed),
                                               name: .vpmOAuthFailed,
                                               object: nil)
    }

    private func loadOAuthProviders() {
        VPMOAuthService.shared.fetchProviders { [weak self] providers in
            guard let self = self else { return }
            self.oauthProviders = providers
            self.rebuildThirdPartyButtons()
        }
    }

    private func rebuildThirdPartyButtons() {
        thirdPartyContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var views: [NSView] = []
        let providers = oauthProviders.filter { $0.enabled && $0.provider != "telegram" }
        for provider in providers {
            let button = NSButton(title: providerTitle(provider.provider),
                                  target: self,
                                  action: #selector(didTapOAuth(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(provider.provider)
            views.append(button)
        }
        if oauthProviders.contains(where: { $0.provider == "telegram" && $0.enabled }) {
            let tgButton = NSButton(title: NSLocalizedString("vpm.auth.telegramLogin", comment: ""),
                                    target: self,
                                    action: #selector(didTapTelegram(_:)))
            tgButton.bezelStyle = .rounded
            views.append(tgButton)
        }
        guard !views.isEmpty else { return }
        views.forEach { thirdPartyContainer.addArrangedSubview($0) }
        let hint = NSTextField(labelWithString: NSLocalizedString("vpm.auth.thirdPartyHint", comment: ""))
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        thirdPartyContainer.addArrangedSubview(hint)
    }

    private func providerTitle(_ provider: String) -> String {
        switch provider {
        case "google": return NSLocalizedString("vpm.auth.googleLogin", comment: "")
        case "x": return NSLocalizedString("vpm.auth.xLogin", comment: "")
        default: return provider
        }
    }

    @objc private func oauthFailed() {
        telegramStatusLabel.stringValue = NSLocalizedString("vpm.auth.oauthFailed", comment: "")
    }

    @objc private func didTapOAuth(_ sender: NSButton) {
        guard let provider = sender.identifier?.rawValue else { return }
        telegramStatusLabel.stringValue = NSLocalizedString("vpm.auth.waitingProvider", comment: "")
        VPMOAuthService.shared.startOAuth(provider: provider,
                                          presentingWindow: view.window) { [weak self] error in
            self?.telegramStatusLabel.stringValue = error ?? ""
        }
    }

    @objc private func didTapTelegram(_ sender: NSButton) {
        setBusy(true)
        VPMOAuthService.shared.telegramLoginStart { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            switch result {
            case let .success(resp):
                self.showTelegramPanel(resp)
            case let .failure(error):
                self.telegramStatusLabel.stringValue = error.displayMessage
            }
        }
    }

    private func showTelegramPanel(_ resp: VPMTGLoginStartResponse) {
        telegramCode = resp.code
        telegramStartURL = resp.startUrl
        telegramStatusLabel.stringValue = String(format: NSLocalizedString("vpm.auth.telegramCodePrompt", comment: ""),
                                                 resp.botUsername, resp.code)
        let openButton = NSButton(title: NSLocalizedString("vpm.auth.openTelegram", comment: ""),
                                  target: self,
                                  action: #selector(didTapOpenTelegram(_:)))
        openButton.bezelStyle = .rounded
        thirdPartyContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        thirdPartyContainer.addArrangedSubview(openButton)
        startTelegramPolling(code: resp.code)
    }

    @objc private func didTapOpenTelegram(_ sender: NSButton) {
        guard let startURL = telegramStartURL, let url = URL(string: startURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private var telegramStartURL: String?

    private func startTelegramPolling(code: String) {
        telegramPollTimer?.invalidate()
        telegramPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            VPMOAuthService.shared.telegramLoginStatus(code: code) { result in
                switch result {
                case let .success(resp):
                    switch resp.status {
                    case "VERIFIED":
                        timer.invalidate()
                        VPMAuthService.storeSession(accessToken: resp.accessToken, email: nil)
                    case "UNBOUND":
                        timer.invalidate()
                        self.telegramStatusLabel.stringValue = NSLocalizedString("vpm.auth.telegramUnbound", comment: "")
                    case "EXPIRED":
                        timer.invalidate()
                        self.telegramStatusLabel.stringValue = NSLocalizedString("vpm.auth.telegramExpired", comment: "")
                    default:
                        break // PENDING
                    }
                case let .failure(error):
                    timer.invalidate()
                    self.telegramStatusLabel.stringValue = error.displayMessage
                }
            }
        }
    }

    deinit {
        telegramPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }


    private func makeRow(label: NSTextField, field: NSTextField, fixedFieldWidth: CGFloat) -> NSStackView {
        field.widthAnchor.constraint(equalToConstant: fixedFieldWidth).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func setupUI() {
        emailTextField.placeholderString = NSLocalizedString("vpm.auth.email", comment: "")
        passwordTextField.placeholderString = NSLocalizedString("vpm.auth.password", comment: "")
        tokenTextField.placeholderString = NSLocalizedString("vpm.auth.resetToken", comment: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4

        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(didTapAction(_:))

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        thirdPartyContainer.orientation = .horizontal
        thirdPartyContainer.spacing = 8
        thirdPartyContainer.alignment = .centerY

        telegramStatusLabel.textColor = .secondaryLabelColor
        telegramStatusLabel.lineBreakMode = .byWordWrapping
        telegramStatusLabel.maximumNumberOfLines = 4

        modeSegment.target = self
        modeSegment.action = #selector(didChangeMode(_:))

        let formStack = NSStackView(views: [emailTextField, passwordTextField, tokenRow, extraRow])
        formStack.orientation = .vertical
        formStack.spacing = 10

        let buttonRow = NSStackView(views: [actionButton, progress])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let rootStack = NSStackView(views: [modeSegment, formStack, buttonRow, statusLabel, thirdPartyContainer, telegramStatusLabel])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            emailTextField.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            passwordTextField.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: rootStack.widthAnchor),
        ])
    }

    // MARK: - Mode switching

    @objc private func didChangeMode(_ sender: NSSegmentedControl) {
        switchMode(sender.selectedSegment)
    }

    func switchMode(_ mode: Int) {
        modeSegment.selectedSegment = mode
        tokenTextField.stringValue = ""
        extraTextField.stringValue = ""
        statusLabel.stringValue = ""
        if let sendCodeButton = sendCodeButton {
            sendCodeButton.removeFromSuperview()
            self.sendCodeButton = nil
        }

        switch mode {
        case 0: // 登录
            tokenRow.isHidden = true
            extraRow.isHidden = true
            actionButton.title = NSLocalizedString("vpm.auth.loginAction", comment: "")
        case 1: // 注册
            tokenRow.isHidden = true
            extraLabel.stringValue = NSLocalizedString("vpm.auth.inviteCodeLabel", comment: "")
            extraTextField.placeholderString = NSLocalizedString("vpm.auth.inviteCode", comment: "")
            extraRow.isHidden = false
            actionButton.title = NSLocalizedString("vpm.auth.registerAction", comment: "")
        default: // 找回密码
            tokenRow.isHidden = false
            extraLabel.stringValue = NSLocalizedString("vpm.auth.newPasswordLabel", comment: "")
            extraTextField.placeholderString = NSLocalizedString("vpm.auth.newPassword", comment: "")
            extraRow.isHidden = false
            actionButton.title = NSLocalizedString("vpm.auth.resetAction", comment: "")
            attachSendCodeButton()
        }
    }

    private func attachSendCodeButton() {
        let button = NSButton(title: NSLocalizedString("vpm.auth.sendResetCode", comment: ""),
                              target: self,
                              action: #selector(didTapSendCode(_:)))
        button.bezelStyle = .rounded
        button.setFrameSize(NSSize(width: 120, height: 24))
        sendCodeButton = button
        guard let formStack = actionButton.superview?.superview as? NSStackView else { return }
        formStack.insertArrangedSubview(button, at: formStack.arrangedSubviews.count)
    }

    // MARK: - Actions

    @objc private func didTapSendCode(_ sender: NSButton) {
        let email = emailTextField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else {
            statusLabel.stringValue = NSLocalizedString("vpm.auth.emailRequired", comment: "")
            return
        }
        setBusy(true)
        VPMAuthService.requestPasswordReset(email: email) { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            switch result {
            case let .success(resp):
                if let devCode = resp.devCode {
                    self.tokenTextField.stringValue = devCode
                    self.statusLabel.stringValue = NSLocalizedString("vpm.auth.devCodeFilled", comment: "")
                } else {
                    self.statusLabel.stringValue = NSLocalizedString("vpm.auth.resetCodeSent", comment: "")
                }
            case let .failure(error):
                self.statusLabel.stringValue = error.displayMessage
            }
        }
    }

    @objc private func didTapAction(_ sender: NSButton) {
        let email = emailTextField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordTextField.stringValue
        switch modeSegment.selectedSegment {
        case 0:
            guard !email.isEmpty, !password.isEmpty else {
                statusLabel.stringValue = NSLocalizedString("vpm.auth.emailPasswordRequired", comment: "")
                return
            }
            setBusy(true)
            VPMAuthService.login(email: email, password: password) { [weak self] result in
                guard let self = self else { return }
                self.setBusy(false)
                switch result {
                case .success:
                    self.statusLabel.stringValue = NSLocalizedString("vpm.auth.loginSuccess", comment: "")
                case let .failure(error):
                    self.statusLabel.stringValue = error.displayMessage
                }
            }
        case 1:
            let inviteCode = extraTextField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty, password.count >= 8 else {
                statusLabel.stringValue = NSLocalizedString("vpm.auth.registerRequirement", comment: "")
                return
            }
            setBusy(true)
            VPMAuthService.register(email: email, password: password, inviteCode: inviteCode) { [weak self] result in
                guard let self = self else { return }
                self.setBusy(false)
                switch result {
                case .success:
                    self.statusLabel.stringValue = NSLocalizedString("vpm.auth.registerSuccess", comment: "")
                case let .failure(error):
                    self.statusLabel.stringValue = error.displayMessage
                }
            }
        default:
            let token = tokenTextField.stringValue.trimmingCharacters(in: .whitespaces)
            let newPassword = extraTextField.stringValue
            guard !email.isEmpty, !token.isEmpty, newPassword.count >= 8 else {
                statusLabel.stringValue = NSLocalizedString("vpm.auth.resetRequirement", comment: "")
                return
            }
            setBusy(true)
            VPMAuthService.resetPassword(email: email, token: token, newPassword: newPassword) { [weak self] result in
                guard let self = self else { return }
                self.setBusy(false)
                switch result {
                case .success:
                    self.statusLabel.stringValue = NSLocalizedString("vpm.auth.resetSuccess", comment: "")
                    self.switchMode(0)
                case let .failure(error):
                    self.statusLabel.stringValue = error.displayMessage
                }
            }
        }
    }

    func setBusy(_ busy: Bool) {
        actionButton.isEnabled = !busy
        sendCodeButton?.isEnabled = !busy
        if busy {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }
}
