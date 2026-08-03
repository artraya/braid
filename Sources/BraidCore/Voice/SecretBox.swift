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
            if let existing = try load(service: service) {
                // An item created by an earlier build carries an ACL naming
                // that binary, so every rebuild triggers a password prompt.
                // Rewrite it once with the same bytes and a permissive ACL:
                // nothing encrypted with it becomes unreadable, and the
                // prompting stops.
                if !isPermissive(service: service) {
                    try? rewritePermissively(existing, service: service)
                }
                return existing
            }
            let fresh = SymmetricKey(size: .bits256)
            try store(fresh, service: service)
            return fresh
        }
    }

    /// An ACL whose trusted-application list is empty means "any application,
    /// no prompt".
    ///
    /// This is a deliberate trade, not an oversight. The prompt defends against
    /// another process on *this Mac* reading the key — but such a process can
    /// already read the Vault, the transcripts and the audio, so the prompt buys
    /// almost nothing while costing a password on every rebuild. What the
    /// encryption actually defends against is the database file travelling
    /// somewhere without this Keychain: a backup drive, a synced folder,
    /// another machine. That property is unaffected by the ACL.
    private func permissiveAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("Braid voice data" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        guard let acls = SecAccessCopyMatchingACLList(
            access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return access }
        for acl in acls {
            // A nil application list is the "any application" case; an empty
            // prompt selector means it never asks.
            SecACLSetContents(acl, nil, "" as CFString, SecKeychainPromptSelector())
        }
        return access
    }

    private func isPermissive(service: String) -> Bool {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let keychainItem = item else { return false }
        var access: SecAccess?
        // swiftlint:disable:next force_cast
        guard SecKeychainItemCopyAccess(keychainItem as! SecKeychainItem, &access) == errSecSuccess,
              let access,
              let acls = SecAccessCopyMatchingACLList(
                access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return false }
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &selector) == errSecSuccess
            else { return false }
            // Any ACL still naming specific applications is what prompts.
            if applications != nil { return false }
        }
        return true
    }

    private func rewritePermissively(_ key: SymmetricKey, service: String) throws {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        try store(key, service: service)
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
            // Never synced to iCloud Keychain: the key stays on this Mac.
            kSecAttrSynchronizable as String: false,
        ]
        if let access = permissiveAccess() {
            add[kSecAttrAccess as String] = access
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
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
