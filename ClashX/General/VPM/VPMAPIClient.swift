//
//  VPMAPIClient.swift
//  ClashX
//
//  VPM 门户 API 客户端：Bearer JWT + 401 自动刷新重试 + Idempotency-Key 支持。
//  刷新令牌（vpm_refresh cookie）依赖 HTTPCookieStorage 持久化，随会话自动携带。
//

import Alamofire
import Foundation

class VPMAPIClient {
    static let shared = VPMAPIClient()

    private let session: Session
    private let decoder = JSONDecoder()
    private let refreshQueue = DispatchQueue(label: "com.ClashX.vpm.refresh")

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        session = Session(configuration: configuration)
    }

    // MARK: - Session state

    static var baseURL: String {
        var base = Settings.vpmAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    static var accessToken: String? {
        get { VPMKeychain.get(account: VPMKeychain.Accounts.accessToken) }
    }

    static var isLoggedIn: Bool {
        guard let token = accessToken else { return false }
        return !token.isEmpty
    }

    static func updateAccessToken(_ token: String?) {
        if let token = token, !token.isEmpty {
            VPMKeychain.set(value: token, account: VPMKeychain.Accounts.accessToken)
        } else {
            VPMKeychain.remove(account: VPMKeychain.Accounts.accessToken)
        }
    }

    /// 登出：吊销服务端会话、清理本地凭证与刷新 cookie。
    static func logout() {
        shared.session.request(VPMAPIClient.baseURL + "/api/v1/auth/logout",
                               method: .post,
                               headers: authHeaders(requiresAuth: true)).response { _ in }
        updateAccessToken(nil)
        Settings.vpmDisplayEmail = ""
        clearCookies()
        NotificationCenter.default.post(name: .vpmLoginStateChanged, object: nil)
    }

    /// 用户在设置中切换服务器地址时清空旧 cookie，避免刷新令牌串站。
    static func clearCookies() {
        guard let url = URL(string: baseURL), let host = url.host else { return }
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] where cookie.domain.contains(host) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }


    private static func authHeaders(requiresAuth: Bool, idempotencyKey: String? = nil) -> HTTPHeaders {
        var headers: HTTPHeaders = [:]
        if requiresAuth, let token = accessToken {
            headers["Authorization"] = "Bearer \(token)"
        }
        if let key = idempotencyKey {
            headers["Idempotency-Key"] = key
        }
        return headers
    }

    // MARK: - Typed request

    func request<T: Decodable>(_ path: String,
                               method: HTTPMethod = .get,
                               body: [String: Any]? = nil,
                               requiresAuth: Bool = true,
                               idempotencyKey: String? = nil,
                               completeHandler: @escaping (Result<T, VPMError>) -> Void) {
        perform(path,
                method: method,
                body: body,
                requiresAuth: requiresAuth,
                idempotencyKey: idempotencyKey,
                allowRefreshRetry: requiresAuth) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(data):
                do {
                    completeHandler(.success(try self.decoder.decode(T.self, from: data)))
                } catch {
                    Logger.log("VPM decode \(path) failed: \(error)", level: .error)
                    completeHandler(.failure(VPMError(code: 0, reason: "DECODE_FAILED", message: error.localizedDescription)))
                }
            case let .failure(error):
                completeHandler(.failure(error))
            }
        }
    }

    // MARK: - Raw request with refresh retry

    private func perform(_ path: String,
                         method: HTTPMethod,
                         body: [String: Any]?,
                         requiresAuth: Bool,
                         idempotencyKey: String?,
                         allowRefreshRetry: Bool,
                         completeHandler: @escaping (Result<Data, VPMError>) -> Void) {
        guard let url = URL(string: VPMAPIClient.baseURL + path) else {
            completeHandler(.failure(VPMError(code: 0, reason: "VALIDATION_FAILED", message: "invalid baseURL")))
            return
        }
        session.request(url,
                        method: method,
                        parameters: body,
                        encoding: JSONEncoding.default,
                        headers: VPMAPIClient.authHeaders(requiresAuth: requiresAuth, idempotencyKey: idempotencyKey))
            .validate(statusCode: 200..<500)
            .responseData { [weak self] response in
                guard let self = self else { return }
                let status = response.response?.statusCode ?? 0
                switch response.result {
                case let .success(data):
                    if (200..<300).contains(status) {
                        completeHandler(.success(data))
                        return
                    }
                    if status == 401 && requiresAuth && allowRefreshRetry {
                        Logger.log("VPM access token expired, refreshing", level: .debug)
                        self.refresh { refreshed in
                            if refreshed {
                                self.perform(path,
                                             method: method,
                                             body: body,
                                             requiresAuth: requiresAuth,
                                             idempotencyKey: idempotencyKey,
                                             allowRefreshRetry: false,
                                             completeHandler: completeHandler)
                            } else {
                                NotificationCenter.default.post(name: .vpmSessionExpired, object: nil)
                                completeHandler(.failure(VPMError.from(data: data, statusCode: status, fallback: NSLocalizedString("vpm.error.sessionExpired", comment: ""))))
                            }
                        }
                    } else {
                        completeHandler(.failure(VPMError.from(data: data, statusCode: status, fallback: NSLocalizedString("vpm.error.requestFailed", comment: ""))))
                    }
                case let .failure(error):
                    completeHandler(.failure(VPMError(code: status, reason: "NETWORK_ERROR", message: error.localizedDescription)))
                }
            }
    }

    // 并发的多个 401 只触发一次刷新。
    private var isRefreshing = false
    private var pendingRefreshCallbacks: [(Bool) -> Void] = []

    func refresh(completeHandler: @escaping (Bool) -> Void) {
        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingRefreshCallbacks.append(completeHandler)
            guard !self.isRefreshing else { return }
            self.isRefreshing = true
            guard let url = URL(string: VPMAPIClient.baseURL + "/api/v1/auth/refresh") else {
                self.finishRefreshing(false)
                return
            }
            self.session.request(url,
                                 method: .post,
                                 parameters: ["rememberMe": true],
                                 encoding: JSONEncoding.default)
                .validate(statusCode: 200..<300)
                .responseData { [weak self] response in
                    guard let self = self else { return }
                    var refreshed = false
                    if let data = try? response.result.get(),
                        let resp = try? self.decoder.decode(VPMRefreshResponse.self, from: data) {
                        VPMAPIClient.updateAccessToken(resp.accessToken)
                        refreshed = true
                    }
                    self.finishRefreshing(refreshed)
                }
        }
    }

    private func finishRefreshing(_ refreshed: Bool) {
        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            let callbacks = self.pendingRefreshCallbacks
            self.pendingRefreshCallbacks.removeAll()
            self.isRefreshing = false
            DispatchQueue.main.async {
                callbacks.forEach { $0(refreshed) }
            }
        }
    }
}
