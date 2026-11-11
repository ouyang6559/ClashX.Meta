//
//  VPMKeychain.swift
//  ClashX
//
//  Created by VPM login mode. SecItem 轻封装，存放 VPM 会话凭证。
//

import Foundation
import Security

enum VPMKeychain {
    enum Accounts {
        static let accessToken = "vpm.accessToken"
    }

    private static let service = "com.west2online.ClashX.vpm"

    private static func baseQuery(account: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }

    static func set(value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Logger.log("VPMKeychain set \(account) failed: \(status)", level: .error)
        }
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(account: String) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.log("VPMKeychain remove \(account) failed: \(status)", level: .error)
        }
    }
}
