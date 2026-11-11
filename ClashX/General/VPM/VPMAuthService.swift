//
//  VPMAuthService.swift
//  ClashX
//
//  邮箱注册/登录/找回密码与会话状态管理。
//

import Foundation

class VPMAuthService {
    /// 当前登录邮箱（仅用于展示）。
    static var displayEmail: String {
        return Settings.vpmDisplayEmail
    }

    static func login(email: String, password: String, completeHandler: @escaping (Result<VPMLoginResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/auth/login",
                                    method: .post,
                                    body: ["email": email, "password": password, "rememberMe": true],
                                    requiresAuth: false) { (result: Result<VPMLoginResponse, VPMError>) in
            if case let .success(resp) = result {
                VPMAPIClient.updateAccessToken(resp.accessToken)
                Settings.vpmDisplayEmail = email
                notifyLoginStateChanged()
            }
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    static func register(email: String,
                         password: String,
                         inviteCode: String,
                         completeHandler: @escaping (Result<VPMRegisterResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/auth/register",
                                    method: .post,
                                    body: ["email": email,
                                           "password": password,
                                           "verificationToken": "",
                                           "inviteCode": inviteCode],
                                    requiresAuth: false) { (result: Result<VPMRegisterResponse, VPMError>) in
            if case let .success(resp) = result {
                VPMAPIClient.updateAccessToken(resp.accessToken)
                Settings.vpmDisplayEmail = email
                notifyLoginStateChanged()
            }
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    static func requestPasswordReset(email: String, completeHandler: @escaping (Result<VPMRequestResetResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/auth/password:request-reset",
                                    method: .post,
                                    body: ["email": email],
                                    requiresAuth: false) { (result: Result<VPMRequestResetResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    static func resetPassword(email: String, token: String, newPassword: String, completeHandler: @escaping (Result<VPMResetPasswordResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/auth/password:reset",
                                    method: .post,
                                    body: ["email": email, "token": token, "newPassword": newPassword],
                                    requiresAuth: false) { result in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    static func logout() {
        VPMAPIClient.logout()
    }

    /// 任意登录方式拿到 accessToken 后统一落地并广播登录态变化（OAuth/TG 共用）。
    static func storeSession(accessToken: String?, email: String?) {
        VPMAPIClient.updateAccessToken(accessToken)
        if let email = email {
            Settings.vpmDisplayEmail = email
        }
        notifyLoginStateChanged()
    }

    static func notifyLoginStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vpmLoginStateChanged, object: nil)
        }
    }
}
