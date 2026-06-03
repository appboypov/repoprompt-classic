import Foundation

protocol SecureKeyValueStorageBackend: AnyObject {
	var persistsValuesAcrossLaunches: Bool { get }

	func save(_ value: String, for key: String, withIntegrityProtection: Bool) throws
	func get(for key: String, verifyIntegrity: Bool) throws -> String
	func getRawData(for key: String) throws -> Data
	func delete(for key: String) throws
}

enum SecureStorageBackendKind: Equatable {
	case persistentKeychain
	case ephemeral
}

enum SecureStorageRuntimePolicy {
	static func backendKind(for signingInfo: RuntimeCodeSigningInfo) -> SecureStorageBackendKind {
		guard signingInfo.detectionErrorDescription == nil,
				let teamIdentifier = signingInfo.teamIdentifier,
				isValidAppleTeamIdentifier(teamIdentifier),
				let codeIdentifier = signingInfo.codeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
				!codeIdentifier.isEmpty,
				signingInfo.isAdHocSignature == false,
				signingInfo.appleTeamValidation == .verified else {
			return .ephemeral
		}
		return .persistentKeychain
	}

	static func isValidAppleTeamIdentifier(_ teamIdentifier: String) -> Bool {
		let bytes = Array(teamIdentifier.utf8)
		guard bytes.count == 10 else { return false }
		return bytes.allSatisfy { byte in
			(byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57)
		}
	}
}

struct SecureStorageBackendSelection {
	let kind: SecureStorageBackendKind
	let backend: SecureKeyValueStorageBackend
}

enum SecureKeyValueStorageFactory {
	private static let cachedSelection: SecureStorageBackendSelection = {
		selectBackend(
			for: RuntimeCodeSigningDetector.currentProcessSigningInfo(),
			persistentBackend: { KeychainService.shared },
			ephemeralBackend: { EphemeralSecureKeyValueStore.shared }
		)
	}()

	static func defaultBackend() -> SecureKeyValueStorageBackend {
		cachedSelection.backend
	}

	static var usesPersistentKeychain: Bool {
		cachedSelection.kind == .persistentKeychain
	}

	static func selectBackend(
		for signingInfo: RuntimeCodeSigningInfo,
		persistentBackend: () -> SecureKeyValueStorageBackend,
		ephemeralBackend: () -> SecureKeyValueStorageBackend
	) -> SecureStorageBackendSelection {
		switch SecureStorageRuntimePolicy.backendKind(for: signingInfo) {
		case .persistentKeychain:
			return SecureStorageBackendSelection(kind: .persistentKeychain, backend: persistentBackend())
		case .ephemeral:
			return SecureStorageBackendSelection(kind: .ephemeral, backend: ephemeralBackend())
		}
	}
}
