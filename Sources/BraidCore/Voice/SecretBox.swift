import Foundation
import CryptoKit
import Security

/// Symmetric encryption for the audio-derived data Braid keeps on disk: the
/// Voice Database, and the Transcripts held for naming.
///
/// The key is generated once and stored in the Keychain marked
/// `ThisDeviceOnly`, so it is excluded from Keychain sync and from a Keychain
/// restored onto another Mac. That is what makes ADR-0007's promise structural:
/// a copy of the database file — on a backup drive, in a synced folder, on
/// someone else's machine — decrypts to nothing. Export (R29) is the only way
/// voice data ever becomes readable, and the user has to ask for it.
public struct SecretBox: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case unreadable

        public var description: String {
            switch self {
            case .keychain(let status): "keychain error \(status)"
            case .unreadable: "stored data could not be decrypted with this Mac's key"
            }
        }
    }

    private enum Source: Sendable {
        case keychain(service: String)
        case raw(SymmetricKey)
    }

    private let source: Source

    public init(service: String = "no.braid.key.voicedb") {
        self.source = .keychain(service: service)
    }

    private init(source: Source) {
        self.source = source
    }

    /// A box with a throwaway key held only in memory. For tests, which should
    /// exercise real encryption without touching the user's Keychain.
    public static func ephemeral() -> SecretBox {
        SecretBox(source: .raw(SymmetricKey(size: .bits256)))
    }

    public func seal(_ data: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(data, using: try key())
        return sealed.combined
    }

    public func open(_ data: Data) throws -> Data {
        let key = try key()
        guard let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: key) else {
            throw Failure.unreadable
        }
        return plain
    }

    // MARK: - Key

    private func key() throws -> SymmetricKey {
        switch source {
        case .raw(let key):
            return key
        case .keychain(let service):
            if let existing = try load(service: service) { return existing }
            let fresh = SymmetricKey(size: .bits256)
            try store(fresh, service: service)
            return fresh
        }
    }

    private func load(service: String) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    private func store(_ key: SymmetricKey, service: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
        ]
        // This device only: never synced to iCloud Keychain, never restored to
        // another Mac. Deliberately stronger than the app's old API-key items,
        // because a leaked API key can be rotated and a voiceprint cannot.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Destroys the key, which destroys every readable trace of everything
    /// sealed with it. Used by "delete the database" (R29).
    public func destroyKey() {
        guard case .keychain(let service) = source else { return }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }
}
