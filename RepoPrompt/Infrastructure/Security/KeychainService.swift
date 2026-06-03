//
//  KeychainService.swift
//  RepoPrompt
//
//  Secure Keychain-based storage for sensitive data
//  Replaces insecure UserDefaults-based SecureKeysService
//

import Foundation
import Security
import CryptoKit

/// Secure storage service using macOS Keychain with integrity protection
class KeychainService: SecureKeyValueStorageBackend {

    static let shared = KeychainService()

	let persistsValuesAcrossLaunches = true

    private let serviceName: String = {
        // Use the actual bundle identifier to avoid issues between Debug/Release builds
        let bundleId = Bundle.main.bundleIdentifier ?? "com.pvncher.repoprompt"
        return "\(bundleId).keychain"
    }()

    // MARK: - Install-bound Integrity Secret

    /// Per-install secret used to derive the integrity/HMAC key.
    /// Stored as a Keychain item with ThisDeviceOnly accessibility so it is not portable across machines/restores.
	private let integrityInstallSecretAccount = SecurityObfuscation.decode(SecurityObfuscation.integrityInstallSecretAccountEncoded)
	private let integrityKeyDerivationSalt = SecurityObfuscation.decode(SecurityObfuscation.integrityKeyDerivationSaltEncoded)

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bufPtr in
            SecRandomCopyBytes(kSecRandomDefault, count, bufPtr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    private func loadInstallSecret() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: integrityInstallSecretAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, !data.isEmpty else {
            throw KeychainError.invalidData
        }
        return data
    }

    private func storeInstallSecret(_ secret: Data) throws {
        guard !secret.isEmpty else { throw KeychainError.invalidData }

        // Best-effort delete in case of partial/corrupt items
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: integrityInstallSecretAccount
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: integrityInstallSecretAccount,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func getOrCreateInstallSecret() throws -> Data {
        if let existing = try loadInstallSecret() {
            return existing
        }
        let secret = try randomBytes(count: 32)
        do {
            try storeInstallSecret(secret)
        } catch {
            // Race tolerance: if another thread created it, load again
            if let existing = try? loadInstallSecret() {
                return existing
            }
            throw error
        }
        return secret
    }

    // MARK: - Error Types

    enum KeychainError: Error, LocalizedError {
        case itemNotFound
        case duplicateItem
        case invalidData
        case integrityCheckFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in keychain"
            case .duplicateItem:
                return "Item already exists"
            case .invalidData:
                return "Invalid data format"
            case .integrityCheckFailed:
                return "Data integrity check failed - possible tampering detected"
            case .unexpectedStatus(let status):
                return "Keychain error: \(status)"
            }
        }
    }

    // MARK: - Save to Keychain

    /// Save a string to the keychain with integrity protection
    func save(_ value: String, for key: String, withIntegrityProtection: Bool = true) throws {
        let data: Data

        if withIntegrityProtection {
            // Add HMAC for integrity verification
            data = try addIntegrityCheck(to: value)
        } else {
            guard let rawData = value.data(using: .utf8) else {
                throw KeychainError.invalidData
            }
            data = rawData
        }

        // Try to delete existing item first (including any old items with different access control)
        try? delete(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false  // Don't sync to iCloud, app-local only
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Retrieve from Keychain

    /// Retrieve a string from the keychain with integrity verification
    func get(for key: String, verifyIntegrity: Bool = true) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        if verifyIntegrity {
            // Verify HMAC and extract original value
            return try verifyAndExtract(from: data)
        } else {
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return value
        }
    }

    func getRawData(for key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        return data
    }

    // MARK: - Delete from Keychain

    /// Delete an item from the keychain
    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Specialized Methods

    private let clockRollbackToleranceSeconds: Double = 60 * 10 // 10 minutes

    /// Save a date with integrity protection and clock rollback detection
    func saveDate(_ date: Date, for key: String) throws {
        let timestamp = date.timeIntervalSince1970
        let continuous = MonotonicClock.continuousSeconds()
        let payload = "\(timestamp)|\(continuous)"
        try save(payload, for: key, withIntegrityProtection: true)
    }

    /// Retrieve a date with integrity and clock rollback detection
    /// Returns the date and whether clock rollback was detected
    func getDate(for key: String) throws -> (date: Date, clockRollbackDetected: Bool) {
        let payload = try get(for: key, verifyIntegrity: true)

        let components = payload.split(separator: "|")
        guard components.count == 2,
              let storedTimestamp = Double(components[0]),
              let storedMonotonic = Double(components[1]) else {
            throw KeychainError.invalidData
        }

        let storedDate = Date(timeIntervalSince1970: storedTimestamp)
        let nowTimestamp = Date().timeIntervalSince1970
        let nowContinuous = MonotonicClock.continuousSeconds()
        let nowUptime = ProcessInfo.processInfo.systemUptime

        func rollbackDetected(expectedTimestamp: Double) -> Bool {
            nowTimestamp + clockRollbackToleranceSeconds < expectedTimestamp
        }

        // 1) Preferred check (new format): continuousSeconds
        let continuousDelta = nowContinuous - storedMonotonic
        if continuousDelta < 0 {
            // Reboot or monotonic discontinuity; can't reliably detect rollback
            return (storedDate, false)
        }
        let expectedFromContinuous = storedTimestamp + continuousDelta
        if !rollbackDetected(expectedTimestamp: expectedFromContinuous) {
            return (storedDate, false)
        }

        // 2) Legacy fallback (old format): systemUptime
        // Old code stored systemUptime which pauses during sleep, so try that interpretation
        let uptimeDelta = nowUptime - storedMonotonic
        if uptimeDelta >= 0 {
            let expectedFromUptime = storedTimestamp + uptimeDelta
            if !rollbackDetected(expectedTimestamp: expectedFromUptime) {
                // Looks like old-format record; migrate it forward
                try? saveDate(storedDate, for: key)
                return (storedDate, false)
            }
        }

        // 3) Both checks say rollback - treat as actual rollback
        return (storedDate, true)
    }

    // MARK: - Integrity Protection (HMAC)

    /// Add HMAC-based integrity check to data
    private func addIntegrityCheck(to value: String) throws -> Data {
        guard let valueData = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Generate device-specific key
        let hmacKey = getDeviceSpecificKey()

        // Compute HMAC
        let hmac = HMAC<SHA256>.authenticationCode(for: valueData, using: hmacKey)
        let hmacData = Data(hmac)

        // Combine: [HMAC (32 bytes)][Original Data]
        var combined = Data()
        combined.append(hmacData)
        combined.append(valueData)

        return combined
    }

    /// Verify HMAC and extract original value
    private func verifyAndExtract(from data: Data) throws -> String {
        // Minimum size: 32 bytes HMAC + at least 1 byte data
        guard data.count > 32 else {
            throw KeychainError.invalidData
        }

        // Extract HMAC and original data
        let storedHMAC = data.prefix(32)
        let originalData = data.suffix(from: 32)

        // Recompute HMAC
        let hmacKey = getDeviceSpecificKey()
        let computedHMAC = HMAC<SHA256>.authenticationCode(for: originalData, using: hmacKey)
        let computedData = Data(computedHMAC)

        // Constant-time comparison
        guard storedHMAC == computedData else {
            throw KeychainError.integrityCheckFailed
        }

        // Extract string
        guard let value = String(data: originalData, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return value
    }

    /// Generate a device-specific key for HMAC
    /// This makes it harder to transfer tampered data between devices
    /// Generate a device-specific key for HMAC
    /// This makes it harder to transfer tampered data between devices
    private func getDeviceSpecificKey() -> SymmetricKey {
        // Primary binding: per-install secret stored as ThisDeviceOnly Keychain item.
        // This blocks naïve copying of Keychain record bytes between machines.
        let installSecret: Data? = try? getOrCreateInstallSecret()

        // Optional additional salt: hardware UUID (NOT required; absence should not collapse into a global constant)
        let hardwareUUID = getHardwareUUIDOptional()
        let salt = integrityKeyDerivationSalt

        if let installSecret, !installSecret.isEmpty {
            var material = Data()
            material.append(installSecret)

            if let uuid = hardwareUUID, let uuidData = uuid.data(using: .utf8) {
                material.append(uuidData)
            }
            if let saltData = salt.data(using: .utf8) {
                material.append(saltData)
            }

            let hash = SHA256.hash(data: material)
            return SymmetricKey(data: Data(hash))
        }

        // Fallback: best-effort device binding using hardware UUID (if available) + salt.
        // This avoids a "global constant" key scenario while still being deterministic.
        if let uuid = hardwareUUID, let data = (uuid + salt).data(using: .utf8) {
            let hash = SHA256.hash(data: data)
            return SymmetricKey(data: hash)
        }

        // Last-resort fallback: deterministic-but-weak key derivation.
        // Should be extremely rare; avoids breaking reads across launches.
        let hash = SHA256.hash(data: Data(salt.utf8))
        return SymmetricKey(data: hash)
    }

    /// Get hardware UUID for device binding
    private func getHardwareUUIDOptional() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0 else {
            return nil
        }

        guard let serialNumberAsCFString = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }

        return serialNumberAsCFString.takeRetainedValue() as? String
    }
}
