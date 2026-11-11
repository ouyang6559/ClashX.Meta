//
//  VPMError.swift
//  ClashX
//
//  VPM API 统一错误：解析 {code,reason,message,metadata}，reason 映射本地化文案。
//

import Foundation

struct VPMError: Error {
    let code: Int
    let reason: String
    let message: String

    /// 展示文案：已知 reason 用本地化文案，否则回退服务器 message。
    var displayMessage: String {
        if let localized = VPMErrorReasonMap.localizedReason(for: reason) {
            return localized
        }
        return message.isEmpty ? NSLocalizedString("vpm.error.unknown", comment: "") : message
    }

    static func from(data: Data?, statusCode: Int, fallback: String) -> VPMError {
        if let data = data, let body = try? JSONDecoder().decode(VPMAPIErrorBody.self, from: data),
            let reason = body.reason {
            return VPMError(code: body.code ?? statusCode, reason: reason, message: body.message ?? fallback)
        }
        return VPMError(code: statusCode, reason: "UNKNOWN", message: fallback)
    }
}

private struct VPMAPIErrorBody: Decodable {
    let code: Int?
    let reason: String?
    let message: String?
}

/// vpm 错误 reason → 本地化文案；未收录的 reason 返回 nil（回退服务器 message）。
enum VPMErrorReasonMap {
    static func localizedReason(for reason: String) -> String? {
        let key = "vpm.reason.\(reason)"
        let localized = NSLocalizedString(key, comment: "")
        return localized == key ? nil : localized
    }
}

extension Notification.Name {
    static let vpmSessionExpired = Notification.Name("com.ClashX.vpm.sessionExpired")
    static let vpmLoginStateChanged = Notification.Name("com.ClashX.vpm.loginStateChanged")
}
