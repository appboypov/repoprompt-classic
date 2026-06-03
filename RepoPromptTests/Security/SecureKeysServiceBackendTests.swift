import XCTest
@testable import RepoPrompt

final class SecureKeysServiceBackendTests: XCTestCase {
	func testAPIKeySaveAndGetUsePlainStorage() async throws {
		let backend = RecordingSecureStorageBackend()
		let service = SecureKeysService(secureStorage: backend)

		try service.saveAPIKey("secret", for: "api")
		let retrieved = try await service.getAPIKey(for: "api")
		XCTAssertEqual(retrieved, "secret")
		XCTAssertEqual(backend.operations, [
			.save("secret", "api", false),
			.get("api", false)
		])
	}

	func testPlainAndIntegrityMethodsUseRequestedModes() throws {
		let backend = RecordingSecureStorageBackend()
		let service = SecureKeysService(secureStorage: backend)

		try service.savePlainValue("plain", for: "plain-key")
		XCTAssertEqual(try service.getPlainValue(for: "plain-key"), "plain")
		try service.deletePlainValue(for: "plain-key")
		try service.saveIntegrityProtectedValue("protected", for: "protected-key")
		XCTAssertEqual(try service.getIntegrityProtectedValue(for: "protected-key"), "protected")
		try service.deleteIntegrityProtectedValue(for: "protected-key")

		XCTAssertEqual(backend.operations, [
			.save("plain", "plain-key", false),
			.get("plain-key", false),
			.delete("plain-key"),
			.save("protected", "protected-key", true),
			.get("protected-key", true),
			.delete("protected-key")
		])
	}

	func testLegacyAPIKeyRecoveryStripsHMACPrefixAndRewritesPlainValue() async throws {
		let backend = RecordingSecureStorageBackend()
		backend.getOverride = { _, _ in throw KeychainService.KeychainError.invalidData }
		var legacyData = Data(repeating: 0xFF, count: 32)
		legacyData.append(Data("legacy-secret".utf8))
		backend.rawDataOverride = { _ in legacyData }
		let service = SecureKeysService(secureStorage: backend)

		let retrieved = try await service.getAPIKey(for: "api")
		XCTAssertEqual(retrieved, "legacy-secret")
		XCTAssertEqual(backend.operations, [
			.get("api", false),
			.getRawData("api"),
			.save("legacy-secret", "api", false)
		])
	}

	func testMissingAPIKeyReturnsNil() async throws {
		let backend = RecordingSecureStorageBackend()
		let service = SecureKeysService(secureStorage: backend)

		let retrieved = try await service.getAPIKey(for: "missing")
		XCTAssertNil(retrieved)
		XCTAssertEqual(backend.operations, [.get("missing", false)])
	}

	func testAPIKeyDeleteRemainsBestEffort() throws {
		let backend = RecordingSecureStorageBackend()
		backend.deleteError = KeychainService.KeychainError.unexpectedStatus(OSStatus(-1))
		let service = SecureKeysService(secureStorage: backend)

		XCTAssertNoThrow(try service.deleteAPIKey(for: "api"))
		XCTAssertEqual(backend.operations, [.delete("api")])
	}
}

private final class RecordingSecureStorageBackend: SecureKeyValueStorageBackend {
	enum Operation: Equatable {
		case save(String, String, Bool)
		case get(String, Bool)
		case getRawData(String)
		case delete(String)
	}

	let persistsValuesAcrossLaunches = false
	var operations: [Operation] = []
	var getOverride: ((String, Bool) throws -> String)?
	var rawDataOverride: ((String) throws -> Data)?
	var deleteError: Error?

	private var entries: [String: Data] = [:]

	func save(_ value: String, for key: String, withIntegrityProtection: Bool) throws {
		operations.append(.save(value, key, withIntegrityProtection))
		entries[key] = Data(value.utf8)
	}

	func get(for key: String, verifyIntegrity: Bool) throws -> String {
		operations.append(.get(key, verifyIntegrity))
		if let getOverride {
			return try getOverride(key, verifyIntegrity)
		}
		guard let data = entries[key] else {
			throw KeychainService.KeychainError.itemNotFound
		}
		guard let value = String(data: data, encoding: .utf8) else {
			throw KeychainService.KeychainError.invalidData
		}
		return value
	}

	func getRawData(for key: String) throws -> Data {
		operations.append(.getRawData(key))
		if let rawDataOverride {
			return try rawDataOverride(key)
		}
		guard let data = entries[key] else {
			throw KeychainService.KeychainError.itemNotFound
		}
		return data
	}

	func delete(for key: String) throws {
		operations.append(.delete(key))
		if let deleteError {
			throw deleteError
		}
		entries.removeValue(forKey: key)
	}
}
