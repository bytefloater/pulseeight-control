import Foundation
#if canImport(Security)
    import Security
#endif

/// Where the admin password lives. Never settings.json.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String?, for account: String) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum SecretStores {
    /// Keychain on Apple platforms. Elsewhere a user-only file until the Credential Manager and
    /// libsecret stores exist.
    public static func makeDefault() -> SecretStore {
        // Dev switch: lets tests run against a throwaway P8_CONFIG_DIR without touching the keychain.
        if ProcessInfo.processInfo.environment["P8_SECRET_STORE"] == "file" { return FileSecretStore() }
        #if canImport(Security)
            return KeychainSecretStore()
        #else
            return FileSecretStore()
        #endif
    }
}

#if canImport(Security)
    public struct KeychainSecretStore: SecretStore {
        public static let service = "com.pulseeight.control"

        public init() {}

        private func query(_ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account,
            ]
        }

        public func secret(for account: String) throws -> String? {
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

        public func setSecret(_ value: String?, for account: String) throws {
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
public struct FileSecretStore: SecretStore {
    public var url: URL

    public init(url: URL = ConfigPaths.secretsFile) { self.url = url }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return all
    }

    public func secret(for account: String) throws -> String? {
        load()[account]
    }

    public func setSecret(_ value: String?, for account: String) throws {
        var all = load()
        if let value, !value.isEmpty { all[account] = value } else { all[account] = nil }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
        #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}
