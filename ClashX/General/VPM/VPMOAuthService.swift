//
//  VPMOAuthService.swift
//  ClashX
//
//  第三方授权登录（Google/X/Telegram）。
//  OAuth: 系统 Web 认证会话（macOS 10.15+）或默认浏览器 + clashx://vpm-auth 深链回调。
//  Telegram: 登录码 + Bot /start + 轮询。
//

import AuthenticationServices
import Cocoa

/// 10.15+ Web 认证会话的强引用容器（避免在宿主类上标注可用性）。
@available(macOS 10.15, *)
private final class VPMWebAuthSessionBox {
    var session: ASWebAuthenticationSession?
}

class VPMOAuthService: NSObject {
    static let shared = VPMOAuthService()

    private var webAuthSessionBox: AnyObject?

    private static let deepLink = "clashx://vpm-auth"

    // MARK: - Providers

    func fetchProviders(completeHandler: @escaping ([VPMOAuthProvider]) -> Void) {
        VPMAPIClient.shared.request("/api/v1/auth/oauth/providers",
                                    requiresAuth: false) { (result: Result<VPMOAuthProvidersResponse, VPMError>) in
            switch result {
            case let .success(resp):
                DispatchQueue.main.async { completeHandler(resp.items) }
            case let .failure(error):
                Logger.log("VPM fetch oauth providers failed: \(error.displayMessage)", level: .debug)
                DispatchQueue.main.async { completeHandler([]) }
            }
        }
    }

    // MARK: - OAuth (Google / X)

    func startOAuth(provider: String, presentingWindow: NSWindow?, statusHandler: @escaping (String?) -> Void) {
        statusHandler(nil)
        VPMAPIClient.shared.request("/api/v1/auth/oauth/\(provider):start",
                                    method: .post,
                                    body: ["deepLink": VPMOAuthService.deepLink],
                                    requiresAuth: false) { [weak self] (result: Result<VPMOAuthStartResponse, VPMError>) in
            guard let self = self else { return }
            switch result {
            case let .success(resp):
                DispatchQueue.main.async {
                    self.presentAuthURL(urlString: resp.authUrl, presentingWindow: presentingWindow, statusHandler: statusHandler)
                }
            case let .failure(error):
                DispatchQueue.main.async { statusHandler(error.displayMessage) }
            }
        }
    }

    private func presentAuthURL(urlString: String, presentingWindow: NSWindow?, statusHandler: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else {
            statusHandler(NSLocalizedString("vpm.error.requestFailed", comment: ""))
            return
        }
        if #available(macOS 10.15, *) {
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "clashx") { [weak self] callbackURL, _ in
                guard let self = self else { return }
                guard let callbackURL = callbackURL else {
                    DispatchQueue.main.async { statusHandler(nil) } // 用户取消
                    return
                }
                self.handleAuthCallbackURL(callbackURL, statusHandler: statusHandler)
            }
            session.presentationContextProvider = self
            let box = VPMWebAuthSessionBox()
            box.session = session
            webAuthSessionBox = box
            if session.start() { return }
        }
        // macOS 10.13/10.14 降级：默认浏览器完成授权，回调走 Apple Event deep link。
        NSWorkspace.shared.open(url)
    }

    /// clashx://vpm-auth?ticket=... 统一入口（Apple Event 与 Web 认证会话共用）。
    func handleAuthCallbackURL(_ url: URL, statusHandler: ((String?) -> Void)? = nil) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            Logger.log("VPM oauth callback error: \(error)", level: .warning)
            statusHandler?(NSLocalizedString("vpm.auth.oauthFailed", comment: ""))
            NotificationCenter.default.post(name: .vpmOAuthFailed, object: nil)
            return
        }
        guard let ticket = components.queryItems?.first(where: { $0.name == "ticket" })?.value else { return }
        exchange(ticket: ticket, statusHandler: statusHandler)
    }

    func exchange(ticket: String, statusHandler: ((String?) -> Void)?) {
        VPMAPIClient.shared.request("/api/v1/auth/oauth:exchange",
                                    method: .post,
                                    body: ["ticket": ticket],
                                    requiresAuth: false) { (result: Result<VPMLoginResponse, VPMError>) in
            switch result {
            case let .success(resp):
                VPMAuthService.storeSession(accessToken: resp.accessToken, email: nil)
                statusHandler?(nil)
            case let .failure(error):
                statusHandler?(error.displayMessage)
                NotificationCenter.default.post(name: .vpmOAuthFailed, object: nil)
            }
        }
    }

    // MARK: - Telegram

    func telegramLoginStart(completeHandler: @escaping (Result<VPMTGLoginStartResponse, VPMError>) -> Void) {
        VPMAPIClient.shared.request("/api/v1/auth/telegram:login:start",
                                    method: .post,
                                    requiresAuth: false) { (result: Result<VPMTGLoginStartResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }

    func telegramLoginStatus(code: String, completeHandler: @escaping (Result<VPMTGLoginStatusResponse, VPMError>) -> Void) {
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code
        VPMAPIClient.shared.request("/api/v1/auth/telegram:login:status?code=\(encoded)",
                                    requiresAuth: false) { (result: Result<VPMTGLoginStatusResponse, VPMError>) in
            DispatchQueue.main.async { completeHandler(result) }
        }
    }
}

@available(macOS 10.15, *)
extension VPMOAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApp.mainWindow ?? ASPresentationAnchor()
    }
}

extension Notification.Name {
    static let vpmOAuthFailed = Notification.Name("com.ClashX.vpm.oauthFailed")
}
