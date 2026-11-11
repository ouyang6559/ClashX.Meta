//
//  VPMModels.swift
//  ClashX
//
//  VPM 门户 API 数据模型。字段名与 vpm backend 响应一一对应；
//  金额/流量类数值由服务端以十进制字符串返回（避免 JS 精度问题），客户端按 String 解码。
//

import Foundation

// MARK: - Auth

struct VPMLoginResponse: Decodable {
    let accessToken: String
    let expiresAt: String?
    let customerId: String
}

struct VPMRegisterResponse: Decodable {
    let customerId: String
    let accessToken: String
    let expiresAt: String?
}

struct VPMRefreshResponse: Decodable {
    let accessToken: String
    let expiresAt: String?
}

struct VPMRequestResetResponse: Decodable {
    let sent: Bool
    let devCode: String?
}

// MARK: - OAuth / Telegram

struct VPMOAuthProvider: Decodable {
    let provider: String
    let enabled: Bool
}

struct VPMOAuthProvidersResponse: Decodable {
    let items: [VPMOAuthProvider]
}

struct VPMOAuthStartResponse: Decodable {
    let authUrl: String
    let expiresAt: String?
}

struct VPMTGLoginStartResponse: Decodable {
    let code: String
    let botUsername: String
    let startUrl: String
    let expiresAt: String?
}

struct VPMTGLoginStatusResponse: Decodable {
    let status: String // PENDING | UNBOUND | VERIFIED | EXPIRED
    let accessToken: String?
    let expiresAt: String?
    let customerId: String?
    let telegramName: String?
}

// MARK: - Commerce

struct VPMProductListResponse: Decodable {
    let items: [VPMProduct]
    let currency: String?
}

struct VPMProduct: Decodable {
    let id: String
    let code: String
    let name: String
    let level: String
    let durationDays: Int
    let cycleDays: Int
    let quotaBytes: String
    let deviceLimit: Int
    let priceMinor: String
    let currency: String
    let provisional: Bool?
}

struct VPMQuoteResponse: Decodable {
    let quoteId: String
    let productId: String
    let productName: String
    let totalMinor: String
    let walletPartMinor: String
    let externalPartMinor: String
    let currency: String
    let replacementRequired: Bool?
    let expectedEntitlementVersion: Int?
    let expiresAt: String
    let autoRenew: Bool
}

struct VPMOrder: Decodable {
    let id: String
    let status: String // PENDING | PAID | FULFILLED | CANCELLED | FAILED
    let totalMinor: String?
}

struct VPMPaymentAction: Decodable {
    let type: String // QR_CODE | PAY_URL | ADDRESS
    let provider: String
    let qrData: String?
    let payUrl: String?
    let address: String?
    let token: String?
    let amount: String?
    let network: String?
    let expiresAt: String?
}

struct VPMCheckoutResponse: Decodable {
    let order: VPMOrder
    let paymentAction: VPMPaymentAction?
}

struct VPMPaymentEntry: Decodable {
    let provider: String
    let status: String
    let currency: String
    let transactionId: String?
    let amountMinor: String?
    let paidAt: String?
}

struct VPMOrderStatusResponse: Decodable {
    let id: String
    let status: String
    let totalMinor: String?
    let payments: [VPMPaymentEntry]?
}

struct VPMPaymentMethod: Decodable {
    let id: String // alipay | wechat | usdt | usdc | mock | wallet
    let kind: String // QR | CRYPTO
    let token: String?
    let network: String?
    let enabled: Bool
}

struct VPMPaymentMethodsResponse: Decodable {
    let items: [VPMPaymentMethod]
}

// MARK: - Entitlement / Traffic

struct VPMENTitlement: Decodable {
    let level: String
    let active: Bool
    let quotaBytes: String?
    let deviceLimit: Int?
    let autoRenew: Bool?
    let productName: String?
    let startAt: String?
    let endAt: String?
    let cycleDays: Int?
}

struct VPMTrafficInfo: Decodable {
    let usedBytes: String
    let baseQuotaBytes: String
    let grantedBytes: String
    let remainingBytes: String
    let resetAt: String
    let percent: Double
}

struct VPMDashboardResponse: Decodable {
    let traffic: VPMTrafficInfo
    let serverTime: String?
}

// MARK: - Devices / Subscription

struct VPMDevice: Decodable {
    let id: String
    let name: String
    let platform: String
    let status: String
    let online: Bool?
    let clientProfileId: String?
}

struct VPMDeviceListResponse: Decodable {
    let items: [VPMDevice]
}

struct VPMDeviceCreateResponse: Decodable {
    let id: String
    let name: String
    let platform: String
    let status: String
}

struct VPMDeviceSubscriptionResponse: Decodable {
    let deviceId: String
    let status: String
    let subscriptionUrls: [String: String] // format -> url，format: clash | singbox | v2ray | wireguard
    let nodeCount: Int
}
