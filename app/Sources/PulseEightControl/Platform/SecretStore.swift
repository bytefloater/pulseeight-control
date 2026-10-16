import Foundation
#if canImport(Security)
    import Security
#endif

/// Where the admin password lives. Never settings.json.
protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String?, for account: String) throws
}

struct SecretStoreError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum SecretStores {
    /// Keychain on macOS. Elsewhere a 0600 file until the Credential Manager and libsecret
    /// stores land in M5.
    static func makeDefault() -> SecretStore {
        #if canImport(Security)
            return KeychainSecretStore()
        #else
            return FileSecretStore()
        #endif
    }
}

#if canImport(Security)
    struct KeychainSecretStore: SecretStore {
        static let service = "com.pulseeight.control"

        private func query(_ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account,
            ]
        }

        func secret(for account: String) throws -> String? {
            var q = query(account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            switch SecItemCopyMatching(q as CFDictionary, &item) {
            case errSecSuccess:
                return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            case errSecItemNotFound:
                return nil
            case let status:
                throw SecretStoreError(message: "Keychain read failed (\(status))")
            }
        }

        func setSecret(_ value: String?, for account: String) throws {
            guard let value, !value.isEmpty else {
                let status = SecItemDelete(query(account) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw SecretStoreError(message: "Keychain delete failed (\(status))")
                }
                return
            }
            let data = Data(value.utf8)
            let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain update failed (\(update))")
            }
            var add = query(account)
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw SecretStoreError(message: "Keychain write failed (\(status))")
            }
        }
    }
#endif

/// Plaintext JSON file restricted to the current user. Interim fallback only.
struct FileSecretStore: SecretStore {
    var url: URL = ConfigPaths.secretsFile

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return all
    }

    func secret(for account: String) throws -> String? {
        load()[account]
    }

    func setSecret(_ value: String?, for account: String) throws {
        var all = load()
        if let value, !value.isEmpty { all[account] = value } else { all[account] = nil }
        try ConfigPaths.ensureDirectory()
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
        #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}
