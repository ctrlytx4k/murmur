import Foundation
import Security

/// API keys in the macOS Keychain: a generic password per provider, service "<bundle id>.provider",
/// account = the provider's id. This is the only place a key is ever written.
public final class KeychainKeyStore: ProviderKeyStore {
    private let service: String
    /// Keys already read since launch, so the Keychain is asked once per provider, not once per take.
    /// Memory only; gone when Murmur quits.
    private var read: [String: String] = [:]

    public init(service: String = "\(Bundle.main.bundleIdentifier ?? "app.murmur.Murmur").provider") {
        self.service = service
    }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    public func key(for id: String) -> String? {
        if let known = read[id] { return known }
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)
        read[id] = key
        return key
    }

    @discardableResult
    public func setKey(_ key: String, for id: String) -> Bool {
        let data = Data(key.utf8)
        read[id] = nil
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(id)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Murmur AI provider key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func removeKey(for id: String) {
        read[id] = nil
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// Provider requests over URLSession. Nothing is cached or kept: no cookies, no disk cache, no credentials store.
public final class URLSessionProviderTransport: ProviderTransport {
    private let session: URLSession

    public nonisolated init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ProviderAPI.timeout
        configuration.timeoutIntervalForResource = ProviderAPI.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        return (data, http)
    }
}

/// Stands in for the network where there must not be one: the demo, snapshots, and a build with no providers.
public final class NoProviderTransport: ProviderTransport {
    public nonisolated init() {}
    public nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ProviderError.unreachable }
}
