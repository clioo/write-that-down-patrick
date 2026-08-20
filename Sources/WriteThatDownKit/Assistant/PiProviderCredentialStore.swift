import Foundation
import Security

/// Keeps Pi-compatible provider credentials in the macOS Keychain. Pi receives
/// a short-lived `auth.json` inside the isolated request directory; keys and
/// OAuth refresh tokens are never placed in arguments, preferences, or logs.
public final class PiProviderCredentialStore: @unchecked Sendable {
    public static let service = "com.writethatdown.PiProviderCredentials"
    private let serviceName: String

    public init(serviceName: String = PiProviderCredentialStore.service) {
        self.serviceName = serviceName
    }

    public func credentialData(for providerID: String) throws -> Data? {
        try Self.validateProviderID(providerID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ConversationAssistantError.requestFailed(Self.securityMessage(status))
        }
        _ = try Self.validatedCredentialObject(data)
        return data
    }

    public func saveCredentialData(_ data: Data, for providerID: String) throws {
        try Self.validateProviderID(providerID)
        _ = try Self.validatedCredentialObject(data)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: providerID,
        ]
        let update = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw ConversationAssistantError.requestFailed(Self.securityMessage(update))
        }
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConversationAssistantError.requestFailed(Self.securityMessage(status))
        }
    }

    public func deleteCredential(for providerID: String) throws {
        try Self.validateProviderID(providerID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: providerID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConversationAssistantError.requestFailed(Self.securityMessage(status))
        }
    }

    public func configuredProviderIDs() throws -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ConversationAssistantError.requestFailed(Self.securityMessage(status))
        }
        let rows = items as? [[String: Any]] ?? (items as? [String: Any]).map { [$0] } ?? []
        return Set(rows.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    func exportAuthFile(to url: URL, providerID: String? = nil) throws {
        let credentials: [String: Data]
        if let providerID {
            credentials = try credentialData(for: providerID).map { [providerID: $0] } ?? [:]
        } else {
            credentials = try allCredentialData()
        }
        var object: [String: Any] = [:]
        for (id, data) in credentials {
            object[id] = try Self.validatedCredentialObject(data)
        }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: encoded, attributes: [.posixPermissions: 0o600]) else {
            throw ConversationAssistantError.launchFailed("Could not create Pi credential file.")
        }
    }

    func importCredential(from authFile: URL, providerID: String) throws {
        let data = try Data(contentsOf: authFile)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credential = root[providerID]
        else {
            throw ConversationAssistantError.invalidResponse
        }
        let credentialData = try JSONSerialization.data(withJSONObject: credential, options: [.sortedKeys])
        try saveCredentialData(credentialData, for: providerID)
    }

    /// One-time compatibility migration for users who configured OpenCode Go
    /// before the multi-provider settings panel existed.
    public func migrateLegacyOpenCodeGoKeyIfNeeded(
        legacyStore: OpenCodeGoCredentialStore = OpenCodeGoCredentialStore()
    ) throws {
        guard try credentialData(for: "opencode-go") == nil,
              let key = try legacyStore.loadAPIKey(),
              !key.isEmpty
        else { return }
        let data = try JSONSerialization.data(withJSONObject: ["type": "api_key", "key": key])
        try saveCredentialData(data, for: "opencode-go")
    }

    private func allCredentialData() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for account in try configuredProviderIDs() {
            if let data = try credentialData(for: account) { result[account] = data }
        }
        return result
    }

    private static func validatedCredentialObject(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String
        else { throw ConversationAssistantError.invalidResponse }
        switch type {
        case "api_key":
            let key = value["key"] as? String
            let environment: [String: String]?
            if let rawEnvironment = value["env"] as? [String: Any] {
                let stringPairs = rawEnvironment.compactMapValues { $0 as? String }
                guard stringPairs.count == rawEnvironment.count else {
                    throw ConversationAssistantError.invalidResponse
                }
                environment = stringPairs
            } else if value["env"] == nil {
                environment = nil
            } else {
                throw ConversationAssistantError.invalidResponse
            }
            guard (value["key"] == nil || key != nil),
                  key?.isEmpty == false || environment?.isEmpty == false
            else { throw ConversationAssistantError.invalidResponse }
        case "oauth":
            guard value["refresh"] is String,
                  value["access"] is String,
                  value["expires"] is NSNumber
            else { throw ConversationAssistantError.invalidResponse }
        default:
            throw ConversationAssistantError.invalidResponse
        }
        return value
    }

    static func validateProviderID(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              value.count <= 100,
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { throw ConversationAssistantError.invalidProvider(value) }
    }

    private static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}
