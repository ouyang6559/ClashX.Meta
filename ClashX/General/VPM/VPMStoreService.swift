//
//  VPMStoreService.swift
//  ClashX
//
//  套餐购买：商品/支付方式/报价/下单/订单轮询。
//

import Foundation

class VPMStoreService {
    static let shared = VPMStoreService()

    private var pollTimer: Timer?

    func listProducts(completeHandler: @escaping (Result<VPMProductListResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/products") { (result: Result<VPMProductListResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    func listPaymentMethods(completeHandler: @escaping (Result<VPMPaymentMethodsResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/payment-methods") { (result: Result<VPMPaymentMethodsResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    func quote(productId: String, autoRenew: Bool, completeHandler: @escaping (Result<VPMQuoteResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/orders:quote",
                                    method: .post,
                                    body: ["productId": productId, "autoRenew": autoRenew]) { (result: Result<VPMQuoteResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    func checkout(quoteId: String, paymentMethod: String, completeHandler: @escaping (Result<VPMCheckoutResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/orders:checkout",
                                    method: .post,
                                    body: ["quoteId": quoteId, "paymentMethod": paymentMethod, "replaceAcknowledgement": ""],
                                    idempotencyKey: UUID().uuidString) { (result: Result<VPMCheckoutResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    func orderStatus(orderId: String, completeHandler: @escaping (Result<VPMOrderStatusResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/orders/\(orderId)") { (result: Result<VPMOrderStatusResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    /// 每 interval 秒轮询订单直到终态或超时（回调 onDone(是否成功)）。
    func pollOrder(orderId: String,
                   interval: TimeInterval = 5,
                   timeout: TimeInterval = 30 * 60,
                   onStatus: ((String) -> Void)? = nil,
                   onDone: @escaping (Bool) -> Void) {
        pollTimer?.invalidate()
        var elapsed: TimeInterval = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            elapsed += interval
            if elapsed > timeout {
                timer.invalidate()
                onDone(false)
                return
            }
            self.orderStatus(orderId: orderId) { result in
                switch result {
                case let .success(resp):
                    onStatus?(resp.status)
                    // FULFILLED = 已支付并完成权益发放；PAID 属于中间态时同样视为成功入口。
                    if resp.status == "FULFILLED" || resp.status == "PAID" {
                        timer.invalidate()
                        onDone(true)
                    } else if resp.status == "FAILED" || resp.status == "CANCELLED" {
                        timer.invalidate()
                        onDone(false)
                    }
                case let .failure(error):
                    Logger.log("VPM poll order failed: \(error.reason)", level: .debug)
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

extension Notification.Name {
    static let vpmEntitlementChanged = Notification.Name("com.ClashX.vpm.entitlementChanged")
}

/// 金额展示：minor 单位字符串 → 货币字符串。
enum VPMMoneyFormat {
    static func display(minor: String, currency: String) -> String {
        guard let value = Double(minor) else { return minor }
        if currency == "CNY" {
            return String(format: "¥%.2f", value / 100)
        }
        return "\(minor) \(currency)"
    }
}
