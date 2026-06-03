import Foundation
import TPObfuscation

protocol SecureIntegrityStringStoring {
	func getPlainValue(for key: String) throws -> String?
	func savePlainValue(_ value: String, for key: String) throws
	func deletePlainValue(for key: String) throws

	func getIntegrityProtectedValue(for key: String) throws -> String?
	func saveIntegrityProtectedValue(_ value: String, for key: String) throws
	func deleteIntegrityProtectedValue(for key: String) throws
}

/// Secure key storage service backed by the runtime-selected persistent or process-local store.
/// Maintains the same API but provides much better security than UserDefaults.
class SecureKeysService {
	private let secureStorage: SecureKeyValueStorageBackend

	init(secureStorage: SecureKeyValueStorageBackend = SecureKeyValueStorageFactory.defaultBackend()) {
		self.secureStorage = secureStorage
	}

	// MARK: - API Key Storage (No Integrity Protection)

	func saveAPIKey(_ key: String, for identifier: String) throws {
		try secureStorage.save(key, for: identifier, withIntegrityProtection: false)
	}

	func getAPIKey(for identifier: String) async throws -> String? {
		do {
			return try secureStorage.get(for: identifier, verifyIntegrity: false)
		} catch KeychainService.KeychainError.itemNotFound {
			return nil
		} catch KeychainService.KeychainError.invalidData {
			// May be legacy integrity-protected data, try recovery
			if let value = try? recoverLegacyValue(for: identifier) {
				return value
			}
		} catch {
			// Try recovery for any other errors
			if let value = try? recoverLegacyValue(for: identifier) {
				return value
			}
		}

		return nil
	}

	/// Recover values that may have been saved with integrity protection in older versions
	private func recoverLegacyValue(for identifier: String) throws -> String? {
		let data = try secureStorage.getRawData(for: identifier)

		// Try as plain UTF-8 first
		if let value = String(data: data, encoding: .utf8), !value.isEmpty {
			try? secureStorage.save(value, for: identifier, withIntegrityProtection: false)
			return value
		}

		// Try stripping 32-byte HMAC prefix from legacy format
		if data.count > 32 {
			let payload = data.suffix(from: 32)
			if let value = String(data: payload, encoding: .utf8), !value.isEmpty {
				try? secureStorage.save(value, for: identifier, withIntegrityProtection: false)
				return value
			}
		}

		return nil
	}

	func deleteAPIKey(for identifier: String) throws {
		try? secureStorage.delete(for: identifier)
	}

	// MARK: - Plain String Storage (for non-secret preference documents)

	func savePlainValue(_ value: String, for key: String) throws {
		try secureStorage.save(value, for: key, withIntegrityProtection: false)
	}

	func getPlainValue(for key: String) throws -> String? {
		do {
			return try secureStorage.get(for: key, verifyIntegrity: false)
		} catch KeychainService.KeychainError.itemNotFound {
			return nil
		}
	}

	func deletePlainValue(for key: String) throws {
		try secureStorage.delete(for: key)
	}

	// MARK: - Integrity-Protected Storage (for security-critical cache values)

	func saveIntegrityProtectedValue(_ value: String, for key: String) throws {
		try secureStorage.save(value, for: key, withIntegrityProtection: true)
	}

	func getIntegrityProtectedValue(for key: String) throws -> String? {
		do {
			return try secureStorage.get(for: key, verifyIntegrity: true)
		} catch KeychainService.KeychainError.itemNotFound {
			return nil
		}
		// Let integrity failures propagate - that's the point
	}

	func deleteIntegrityProtectedValue(for key: String) throws {
		try secureStorage.delete(for: key)
	}

	// MARK: - Bundle Verification

	private let bundleVerificationKey = TPObStr.b.u.n.d.l.e.underscore.v.e.r.i.f.i.c.a.t.i.o.n
	private let verificationValiditySeconds = Double(60 * 60 * 24 * 3) // 3 days

	func saveBundleVerification() throws {
		let timestamp = Date().timeIntervalSince1970.description
		try saveIntegrityProtectedValue(timestamp, for: bundleVerificationKey)
	}

	func hasValidBundleVerification() throws -> Bool {
		guard let storedTimeStr = try getIntegrityProtectedValue(for: bundleVerificationKey),
			  let storedTime = Double(storedTimeStr) else {
			return false
		}

		let storedDate = Date(timeIntervalSince1970: storedTime)
		let now = Date()
		let timeInterval = now.timeIntervalSince(storedDate)

		// Clock rollback check
		if timeInterval < 0 {
			try clearBundleVerification()
			return false
		}

		return timeInterval <= verificationValiditySeconds
	}

	func clearBundleVerification() throws {
		try deleteIntegrityProtectedValue(for: bundleVerificationKey)
	}
}

extension SecureKeysService: SecureIntegrityStringStoring {}
