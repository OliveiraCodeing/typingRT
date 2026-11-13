import Foundation
import Security

public protocol RequestyCredentialStoring: Sendable {
    func read() async throws -> String?
    func save(_ value: String) async throws
    func delete() async throws
}

public enum RequestyCredentialError: Error, LocalizedError, Sendable, Equatable {
    case invalidKey
    case invalidStoredKey
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            "Bitte einen gültigen, nicht leeren Requesty-Schlüssel eingeben."
        case .invalidStoredKey:
            "Der gespeicherte Requesty-Zugang ist nicht lesbar. Bitte den Schlüssel erneut speichern."
        case .unavailable:
            "Der Schlüsselbund ist nicht zugänglich. Bitte entsperren beziehungsweise den Zugriff erlauben und erneut versuchen."
        }
    }
}

// The synchronous Security boundary is called only from RequestyCredentials' actor.
// It is injectable so ordinary tests never access the user's real keychain.
protocol RequestyCredentialBackend: Sendable {
    func read(service: String) throws -> Data?
    func save(_ data: Data, service: String) throws
    func delete(service: String) throws
}

/// A separate, non-main actor keeps blocking Keychain IPC away from UI/audio.
/// Credentials are never mirrored into preferences, files, or a presence flag.
public actor RequestyCredentials: RequestyCredentialStoring {
    private let service: String
    private let backend: any RequestyCredentialBackend

    public init(service: String) {
        self.service = service
        backend = SecurityRequestyCredentialBackend()
    }

    init(service: String, backend: any RequestyCredentialBackend) {
        self.service = service
        self.backend = backend
    }

    public func read() async throws -> String? {
        try Task.checkCancellation()
        guard !service.isEmpty else { throw RequestyCredentialError.unavailable }
        let data: Data?
        do { data = try backend.read(service: service) }
        catch { throw RequestyCredentialError.unavailable }
        try Task.checkCancellation()
        guard let data else { return nil }
        guard data.count <= 8_192, let value = String(data: data, encoding: .utf8),
              let validated = RequestyValidation.apiKey(value), value == validated else {
            throw RequestyCredentialError.invalidStoredKey
        }
        return value
    }

    public func save(_ value: String) async throws {
        try Task.checkCancellation()
        guard let validated = RequestyValidation.apiKey(value) else {
            throw RequestyCredentialError.invalidKey
        }
        guard !service.isEmpty else { throw RequestyCredentialError.unavailable }
        // Update in place. Never delete the existing credential before a successful save.
        do { try backend.save(Data(validated.utf8), service: service) }
        catch { throw RequestyCredentialError.unavailable }
    }

    public func delete() async throws {
        try Task.checkCancellation()
        guard !service.isEmpty else { throw RequestyCredentialError.unavailable }
        do { try backend.delete(service: service) }
        catch { throw RequestyCredentialError.unavailable }
    }
}

private struct SecurityRequestyCredentialBackend: RequestyCredentialBackend {
    private func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "requesty-api-key",
            kSecAttrSynchronizable as String: false
        ]
    }

    func read(service: String) throws -> Data? {
        var attributes = query(service: service)
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RequestyCredentialError.unavailable
        }
        return data
    }

    func save(_ data: Data, service: String) throws {
        let attributes = query(service: service)
        let change = [kSecValueData as String: data]
        let updated = SecItemUpdate(attributes as CFDictionary, change as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw RequestyCredentialError.unavailable }
        var addition = attributes
        addition[kSecValueData as String] = data
        let added = SecItemAdd(addition as CFDictionary, nil)
        if added == errSecSuccess { return }
        // Another actor/process could have created this same service/account meanwhile.
        guard added == errSecDuplicateItem,
              SecItemUpdate(attributes as CFDictionary, change as CFDictionary) == errSecSuccess else {
            throw RequestyCredentialError.unavailable
        }
    }

    func delete(service: String) throws {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RequestyCredentialError.unavailable
        }
    }
}
