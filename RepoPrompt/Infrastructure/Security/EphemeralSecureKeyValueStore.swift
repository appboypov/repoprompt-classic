import CryptoKit
import Foundation

/// Process-local secure storage used whenever runtime signing evidence is not trusted.
final class EphemeralSecureKeyValueStore: SecureKeyValueStorageBackend {
	static let shared = EphemeralSecureKeyValueStore()

	let persistsValuesAcrossLaunches = false

	private var entries: [String: Data] = [:]
	private let hmacKey = SymmetricKey(size: .bits256)
	private let lock = NSLock()

	init() {}

	func save(_ value: String, for key: String, withIntegrityProtection: Bool = true) throws {
		guard let valueData = value.data(using: .utf8) else {
			throw KeychainService.KeychainError.invalidData
		}

		let data: Data
		if withIntegrityProtection {
			var protectedData = Data(HMAC<SHA256>.authenticationCode(for: valueData, using: hmacKey))
			protectedData.append(valueData)
			data = protectedData
		} else {
			data = valueData
		}

		withLock {
			entries[key] = data
		}
	}

	func get(for key: String, verifyIntegrity: Bool = true) throws -> String {
		let data = try withLock {
			guard let data = entries[key] else {
				throw KeychainService.KeychainError.itemNotFound
			}
			return data
		}

		if verifyIntegrity {
			return try verifyAndExtract(from: data)
		}
		guard let value = String(data: data, encoding: .utf8) else {
			throw KeychainService.KeychainError.invalidData
		}
		return value
	}

	func getRawData(for key: String) throws -> Data {
		try withLock {
			guard let data = entries[key] else {
				throw KeychainService.KeychainError.itemNotFound
			}
			return data
		}
	}

	func delete(for key: String) throws {
		_ = withLock {
			entries.removeValue(forKey: key)
		}
	}

	private func verifyAndExtract(from data: Data) throws -> String {
		guard data.count > 32 else {
			throw KeychainService.KeychainError.invalidData
		}

		let storedHMAC = data.prefix(32)
		let originalData = data.suffix(from: 32)
		let computedHMAC = Data(HMAC<SHA256>.authenticationCode(for: originalData, using: hmacKey))
		guard storedHMAC == computedHMAC else {
			throw KeychainService.KeychainError.integrityCheckFailed
		}
		guard let value = String(data: originalData, encoding: .utf8) else {
			throw KeychainService.KeychainError.invalidData
		}
		return value
	}

	private func withLock<T>(_ body: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}
}
