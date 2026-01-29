//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import Foundation
import CryptoKit
import Security

/// Manages encryption for sensitive health data at rest
/// Uses AES-GCM encryption with keys stored in the Keychain
final class EncryptionManager {

    static let shared = EncryptionManager()

    private let keychainService = "com.chrissharp.flowrecovery.encryption"
    private let keychainAccount = "session-encryption-key"

    private init() {}

    // MARK: - Public API

    /// Encrypt data using AES-GCM
    /// - Parameter data: Plain data to encrypt
    /// - Returns: Encrypted data (nonce + ciphertext + tag)
    func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealedBox = try AES.GCM.seal(data, using: key)

        // Combine nonce + ciphertext + tag for storage
        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }
        return combined
    }

    /// Decrypt data encrypted with encrypt()
    /// - Parameter encryptedData: Data from encrypt() (nonce + ciphertext + tag)
    /// - Returns: Original plain data
    func decrypt(_ encryptedData: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Check if encryption is available
    var isAvailable: Bool {
        do {
            _ = try getOrCreateKey()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Key Management

    private func getOrCreateKey() throws -> SymmetricKey {
        // Try to retrieve existing key
        if let existingKeyData = try? retrieveKeyFromKeychain() {
            return SymmetricKey(data: existingKeyData)
        }

        // Create new key
        let newKey = SymmetricKey(size: .bits256)
        try storeKeyInKeychain(newKey)
        return newKey
    }

    private func storeKeyInKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Delete any existing key first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError(status)
        }
    }

    private func retrieveKeyFromKeychain() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let keyData = result as? Data else {
            throw EncryptionError.keyNotFound
        }

        return keyData
    }

    // MARK: - Errors

    enum EncryptionError: Error, LocalizedError {
        case encryptionFailed
        case decryptionFailed
        case keyNotFound
        case keychainError(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encryptionFailed:
                return "Failed to encrypt data"
            case .decryptionFailed:
                return "Failed to decrypt data"
            case .keyNotFound:
                return "Encryption key not found in keychain"
            case .keychainError(let status):
                return "Keychain error: \(status)"
            }
        }
    }
}
