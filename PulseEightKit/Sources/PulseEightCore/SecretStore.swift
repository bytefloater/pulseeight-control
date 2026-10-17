import Foundation
#if canImport(Security)
    import Security
#endif
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
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
        public static let defaultService = "com.pulseeight.control"

        /// The keychain service the item lives under. Tests pass their own, so they never touch the real one.
        public var service: String

        public init(service: String = defaultService) { self.service = service }

        private func query(_ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
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
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(all)

        #if os(Windows)
            try data.write(to: url, options: .atomic)
        #else
            try writeRestricted(data, in: directory)
        #endif
    }

    #if !os(Windows)
        /// Writes a temporary file that is created with mode 0600 and then renamed over the real one. An
        /// ordinary write followed by chmod leaves the password readable by other users in between, and
        /// would keep the permissions of a file that already existed with looser ones.
        private func writeRestricted(_ data: Data, in directory: URL) throws {
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else {
                throw SecretStoreError(message: "Couldn't write \(url.lastPathComponent) (\(String(cString: strerror(errno))))")
            }
            do {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                guard rename(temporary.path, url.path) == 0 else {
                    throw SecretStoreError(message: "Couldn't replace \(url.lastPathComponent) (\(String(cString: strerror(errno))))")
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    #endif
}
