import Security
import XCTest
@testable import RepoPrompt

final class SecureStorageRuntimePolicyTests: XCTestCase {
	func testVerifiedAppleTeamSignedBuildUsesPersistentKeychain() {
		XCTAssertEqual(SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo()), .persistentKeychain)
	}

	func testAdHocAndUnknownSignatureFlagsUseEphemeralStorage() {
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(isAdHocSignature: true)),
			.ephemeral
		)
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(isAdHocSignature: nil)),
			.ephemeral
		)
	}

	func testRejectedOrUnavailableAppleAnchorValidationUsesEphemeralStorage() {
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(appleTeamValidation: .rejected(OSStatus(-1)))),
			.ephemeral
		)
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(appleTeamValidation: .unavailable("self-signed"))),
			.ephemeral
		)
	}

	func testMissingOrMalformedTeamIdentifierUsesEphemeralStorage() {
		for teamIdentifier in [nil, "", "SHORT", "abcdefghij", "A1B2C3D4E-"] as [String?] {
			XCTAssertEqual(
				SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(teamIdentifier: teamIdentifier)),
				.ephemeral,
				"Expected volatile storage for team identifier \(String(describing: teamIdentifier))"
			)
		}
	}

	func testMissingOrBlankCodeIdentifierUsesEphemeralStorage() {
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(codeIdentifier: nil)),
			.ephemeral
		)
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(codeIdentifier: "  \n")),
			.ephemeral
		)
	}

	func testDetectorErrorUsesEphemeralStorageEvenWithOtherwiseTrustedFacts() {
		XCTAssertEqual(
			SecureStorageRuntimePolicy.backendKind(for: makeSigningInfo(detectionErrorDescription: "unavailable")),
			.ephemeral
		)
	}

	func testEphemeralSelectionDoesNotEvaluatePersistentBackendClosure() {
		var constructedPersistentBackend = false
		var constructedEphemeralBackend = false

		let selection = SecureKeyValueStorageFactory.selectBackend(
			for: makeSigningInfo(isAdHocSignature: true),
			persistentBackend: {
				constructedPersistentBackend = true
				return StubSecureStorageBackend(persistsValuesAcrossLaunches: true)
			},
			ephemeralBackend: {
				constructedEphemeralBackend = true
				return StubSecureStorageBackend(persistsValuesAcrossLaunches: false)
			}
		)

		XCTAssertEqual(selection.kind, .ephemeral)
		XCTAssertFalse(constructedPersistentBackend)
		XCTAssertTrue(constructedEphemeralBackend)
	}

	func testPersistentSelectionDoesNotEvaluateEphemeralBackendClosure() {
		var constructedPersistentBackend = false
		var constructedEphemeralBackend = false

		let selection = SecureKeyValueStorageFactory.selectBackend(
			for: makeSigningInfo(),
			persistentBackend: {
				constructedPersistentBackend = true
				return StubSecureStorageBackend(persistsValuesAcrossLaunches: true)
			},
			ephemeralBackend: {
				constructedEphemeralBackend = true
				return StubSecureStorageBackend(persistsValuesAcrossLaunches: false)
			}
		)

		XCTAssertEqual(selection.kind, .persistentKeychain)
		XCTAssertTrue(constructedPersistentBackend)
		XCTAssertFalse(constructedEphemeralBackend)
	}

	private func makeSigningInfo(
		teamIdentifier: String? = "A1B2C3D4E5",
		codeIdentifier: String? = "com.pvncher.repoprompt",
		isAdHocSignature: Bool? = false,
		appleTeamValidation: AppleTeamSigningValidation = .verified,
		detectionErrorDescription: String? = nil
	) -> RuntimeCodeSigningInfo {
		RuntimeCodeSigningInfo(
			teamIdentifier: teamIdentifier,
			codeIdentifier: codeIdentifier,
			isAdHocSignature: isAdHocSignature,
			appleTeamValidation: appleTeamValidation,
			detectionErrorDescription: detectionErrorDescription
		)
	}
}

private final class StubSecureStorageBackend: SecureKeyValueStorageBackend {
	let persistsValuesAcrossLaunches: Bool

	init(persistsValuesAcrossLaunches: Bool) {
		self.persistsValuesAcrossLaunches = persistsValuesAcrossLaunches
	}

	func save(_ value: String, for key: String, withIntegrityProtection: Bool) throws {}

	func get(for key: String, verifyIntegrity: Bool) throws -> String {
		throw KeychainService.KeychainError.itemNotFound
	}

	func getRawData(for key: String) throws -> Data {
		throw KeychainService.KeychainError.itemNotFound
	}

	func delete(for key: String) throws {}
}
