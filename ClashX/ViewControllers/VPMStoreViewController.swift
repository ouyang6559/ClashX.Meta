//
//  VPMStoreViewController.swift
//  ClashX
//
//  套餐购买窗口：商品列表 → 支付方式 → 支付动作展示（二维码/链接/加密货币地址）→ 订单轮询。
//

import Cocoa
import CoreImage

class VPMStoreViewController: NSViewController {
    private let productsStack = NSStackView(views: [])
    private let methodPopup = NSPopUpButton(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let paymentArea = NSStackView(views: [])

    private var products: [VPMProduct] = []
    private var methods: [VPMPaymentMethod] = []
    private var pendingQuoteId: String?
    private var pendingOrderId: String?
    private var selectedProduct: VPMProduct?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reloadProducts()
        reloadMethods()
    }

    private func setupUI() {
        productsStack.orientation = .vertical
        productsStack.spacing = 6
        methodPopup.target = self
        methodPopup.action = #selector(didSelectMethod(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 6
        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        paymentArea.orientation = .vertical
        paymentArea.spacing = 8
        paymentArea.alignment = .centerX

        let methodRow = NSStackView(views: [NSTextField(labelWithString: NSLocalizedString("vpm.store.paymentMethod", comment: "")), methodPopup])
        methodRow.orientation = .horizontal
        methodRow.spacing = 8

        let rootStack = NSStackView(views: [
            NSTextField(labelWithString: NSLocalizedString("vpm.store.title", comment: "")),
            productsStack,
            methodRow,
            paymentArea,
            NSStackView(views: [progress, statusLabel]),
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            rootStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: rootStack.widthAnchor),
            methodPopup.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    // MARK: - Data loading

    func reloadProducts() {
        paymentArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        productsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        setBusy(true)
        VPMStoreService.shared.listProducts { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            switch result {
            case let .success(resp):
                self.products = resp.items
                self.renderProducts(currency: resp.currency ?? "CNY")
            case let .failure(error):
                self.statusLabel.stringValue = error.displayMessage
            }
        }
    }

    private func reloadMethods() {
        VPMStoreService.shared.listPaymentMethods { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(resp):
                self.methods = resp.items.filter { $0.enabled }
                self.methodPopup.removeAllItems()
                for method in self.methods {
                    self.methodPopup.addItem(withTitle: self.methodTitle(method))
                }
            case let .failure(error):
                Logger.log("VPM payment methods failed: \(error.reason)", level: .debug)
            }
        }
    }

    private func methodTitle(_ method: VPMPaymentMethod) -> String {
        switch method.id {
        case "alipay": return NSLocalizedString("vpm.pay.alipay", comment: "")
        case "wechat": return NSLocalizedString("vpm.pay.wechat", comment: "")
        case "usdt": return method.network.map { "USDT (\($0))" } ?? "USDT"
        case "usdc": return method.network.map { "USDC (\($0))" } ?? "USDC"
        case "mock": return NSLocalizedString("vpm.pay.mock", comment: "")
        case "wallet": return NSLocalizedString("vpm.pay.wallet", comment: "")
        default: return method.id
        }
    }

    private func renderProducts(currency: String) {
        for product in products {
            let row = NSStackView(views: [])
            row.orientation = .horizontal
            row.spacing = 10
            let nameLabel = NSTextField(labelWithString: product.name)
            nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let detail = String(format: NSLocalizedString("vpm.store.productDetail", comment: ""),
                                product.durationDays, product.deviceLimit)
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            detailLabel.textColor = .secondaryLabelColor
            let price = VPMMoneyFormat.display(minor: product.priceMinor, currency: currency)
            let priceLabel = NSTextField(labelWithString: price)
            priceLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let buyButton = NSButton(title: NSLocalizedString("vpm.store.buy", comment: ""),
                                     target: self,
                                     action: #selector(didTapBuy(_:)))
            buyButton.bezelStyle = .rounded
            buyButton.identifier = NSUserInterfaceItemIdentifier(product.id)
            [nameLabel, detailLabel, priceLabel, buyButton].forEach { row.addArrangedSubview($0) }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: productsStack.widthAnchor).isActive = true
            productsStack.addArrangedSubview(row)
        }
    }

    // MARK: - Purchase flow

    @objc private func didTapBuy(_ sender: NSButton) {
        guard let productId = sender.identifier?.rawValue else { return }
        selectedProduct = products.first { $0.id == productId }
        setBusy(true)
        statusLabel.stringValue = ""
        VPMStoreService.shared.quote(productId: productId, autoRenew: false) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(quote):
                self.pendingQuoteId = quote.quoteId
                let method = self.selectedMethod()
                self.setBusy(false)
                if method == nil {
                    self.statusLabel.stringValue = NSLocalizedString("vpm.store.noPaymentMethod", comment: "")
                    return
                }
                self.checkout(method: method!)
            case let .failure(error):
                self.setBusy(false)
                self.statusLabel.stringValue = error.displayMessage
            }
        }
    }

    private func selectedMethod() -> VPMPaymentMethod? {
        let idx = methodPopup.indexOfSelectedItem
        guard idx >= 0 && idx < methods.count else { return nil }
        return methods[idx]
    }

    @objc private func didSelectMethod(_ sender: NSPopUpButton) {
        // 重新选择支付方式时清空上一笔的支付面板。
        paymentArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statusLabel.stringValue = ""
    }

    private func checkout(method: VPMPaymentMethod) {
        guard let quoteId = pendingQuoteId else { return }
        setBusy(true)
        VPMStoreService.shared.checkout(quoteId: quoteId, paymentMethod: method.id) { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            switch result {
            case let .success(resp):
                self.pendingOrderId = resp.order.id
                if resp.order.status == "FULFILLED" {
                    self.onOrderPaid()
                    return
                }
                if let action = resp.paymentAction {
                    self.renderPaymentAction(action)
                    self.waitForOrder(orderId: resp.order.id)
                } else {
                    self.waitForOrder(orderId: resp.order.id)
                }
            case let .failure(error):
                self.statusLabel.stringValue = error.displayMessage
            }
        }
    }

    private func renderPaymentAction(_ action: VPMPaymentAction) {
        paymentArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch action.type {
        case "QR_CODE":
            if let qrData = action.qrData, let image = VPMQRCodeGenerator.image(for: qrData, size: 180) {
                let imageView = NSImageView(image: image)
                paymentArea.addArrangedSubview(imageView)
            }
            if let payUrl = action.payUrl {
                addCopyAndOpenRow(text: payUrl)
            } else if let qrData = action.qrData {
                addCopyRow(text: qrData, label: NSLocalizedString("vpm.pay.copyLink", comment: ""))
            }
        case "PAY_URL":
            if let payUrl = action.payUrl {
                let openButton = NSButton(title: NSLocalizedString("vpm.pay.openInBrowser", comment: ""),
                                          target: self,
                                          action: #selector(didTapOpenPayURL(_:)))
                openButton.bezelStyle = .rounded
                paymentArea.addArrangedSubview(openButton)
                addCopyRow(text: payUrl, label: NSLocalizedString("vpm.pay.copyLink", comment: ""))
            }
        default: // ADDRESS（USDT/USDC）
            if let address = action.address {
                let addressLabel = NSTextField(labelWithString: "\(action.token ?? "") (\(action.network ?? "")): \(address)")
                addressLabel.lineBreakMode = .byCharWrapping
                addressLabel.maximumNumberOfLines = 3
                addressLabel.isSelectable = true
                paymentArea.addArrangedSubview(addressLabel)
                if let amount = action.amount {
                    let amountLabel = NSTextField(labelWithString: String(format: NSLocalizedString("vpm.pay.amountPrompt", comment: ""), amount, action.token ?? ""))
                    paymentArea.addArrangedSubview(amountLabel)
                }
                addCopyRow(text: address, label: NSLocalizedString("vpm.pay.copyAddress", comment: ""))
            }
        }
        let waiting = NSTextField(labelWithString: NSLocalizedString("vpm.pay.waiting", comment: ""))
        waiting.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        waiting.textColor = .secondaryLabelColor
        paymentArea.addArrangedSubview(waiting)
    }

    private var lastPayURL: String?
    private var lastCopyText: String?

    private func addCopyAndOpenRow(text: String) {
        lastPayURL = text
        lastCopyText = text
        let copyButton = NSButton(title: NSLocalizedString("vpm.pay.copyLink", comment: ""),
                                  target: self,
                                  action: #selector(didTapCopy(_:)))
        let openButton = NSButton(title: NSLocalizedString("vpm.pay.openInBrowser", comment: ""),
                                  target: self,
                                  action: #selector(didTapOpenPayURL(_:)))
        copyButton.bezelStyle = .rounded
        openButton.bezelStyle = .rounded
        let row = NSStackView(views: [copyButton, openButton])
        row.orientation = .horizontal
        row.spacing = 10
        paymentArea.addArrangedSubview(row)
    }

    private func addCopyRow(text: String, label: String) {
        lastCopyText = text
        let copyButton = NSButton(title: label, target: self, action: #selector(didTapCopy(_:)))
        copyButton.bezelStyle = .rounded
        paymentArea.addArrangedSubview(copyButton)
    }

    @objc private func didTapCopy(_ sender: NSButton) {
        guard let text = lastCopyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = NSLocalizedString("vpm.pay.copied", comment: "")
    }

    @objc private func didTapOpenPayURL(_ sender: NSButton) {
        guard let url = lastPayURL.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    private func waitForOrder(orderId: String) {
        VPMStoreService.shared.pollOrder(orderId: orderId, onStatus: nil) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.onOrderPaid()
            } else {
                self.statusLabel.stringValue = NSLocalizedString("vpm.pay.failedOrTimeout", comment: "")
            }
        }
    }

    private func onOrderPaid() {
        statusLabel.stringValue = NSLocalizedString("vpm.pay.success", comment: "")
        NSUserNotificationCenter.default.post(title: NSLocalizedString("vpm.store.title", comment: ""),
                                              info: NSLocalizedString("vpm.pay.success", comment: ""))
        NotificationCenter.default.post(name: .vpmEntitlementChanged, object: nil)
        VPMDeviceService.shared.ensureSubscriptionAfterLogin()
        reloadProducts()
    }

    private func setBusy(_ busy: Bool) {
        progress.isHidden = !busy
        if busy {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }
}

/// CIQRCodeGenerator 封装。
enum VPMQRCodeGenerator {
    static func image(for content: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(size / output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

class VPMStoreWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = NSLocalizedString("vpm.store.title", comment: "")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.contentViewController = VPMStoreViewController()
    }

    func show() {
        (window?.contentViewController as? VPMStoreViewController)?.reloadProducts()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
