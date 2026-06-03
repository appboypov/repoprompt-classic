//
//  SecurityObfuscationTests.swift
//  RepoPromptTests
//
//  Tests for XOR-obfuscated string decoding used in security-sensitive code.
//

import XCTest
@testable import RepoPrompt

final class SecurityObfuscationTests: XCTestCase {

	// MARK: - Decode Function Tests

	func testDecodeEmptyArray() {
		XCTAssertEqual(SecurityObfuscation.decode([]), "")
	}

	func testDecodeSingleCharacter() {
		// 'a' = 97, 97 ^ 0x5A = 59
		XCTAssertEqual(SecurityObfuscation.decode([59]), "a")
	}

	func testDecodeRoundTrip() {
		let original = "test_string_123"
		let encoded = original.utf8.map { $0 ^ SecurityObfuscation.key }
		let decoded = SecurityObfuscation.decode(encoded)
		XCTAssertEqual(decoded, original)
	}

	// MARK: - KeychainService Keys Tests

	func testIntegrityInstallSecretAccountDecodes() {
		let decoded = SecurityObfuscation.decode(SecurityObfuscation.integrityInstallSecretAccountEncoded)
		XCTAssertEqual(decoded, "rp_integrity_install_secret_v1")
	}

	func testIntegrityKeyDerivationSaltDecodes() {
		let decoded = SecurityObfuscation.decode(SecurityObfuscation.integrityKeyDerivationSaltEncoded)
		XCTAssertEqual(decoded, "RepoPromptSecuritySalt-v2")
	}

	// MARK: - Agent Permission Secure Store Keys Tests

	func testAgentPermissionDocumentKeysDecode() {
		XCTAssertEqual(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionSubagentDocumentKeyEncoded), "rp.agent.permissions.subagent.v1")
		XCTAssertEqual(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionCodexDocumentKeyEncoded), "rp.agent.permissions.codex.v1")
		XCTAssertEqual(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionClaudeDocumentKeyEncoded), "rp.agent.permissions.claude.v1")
		XCTAssertEqual(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionGeminiDocumentKeyEncoded), "rp.agent.permissions.gemini.v1")
		XCTAssertEqual(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionOpenCodeDocumentKeyEncoded), "rp.agent.permissions.openCode.v1")
		XCTAssertEqual(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionCursorDocumentKeyEncoded), "rp.agent.permissions.cursor.v1")
	}

	// MARK: - Encoding Verification Tests

	func testEncodingMatchesExpected() {
		// Verify our encoding logic matches what's in the source files
		let testString = "rp_integrity_install_secret_v1"
		let encoded = testString.utf8.map { $0 ^ SecurityObfuscation.key }

		XCTAssertEqual(encoded, SecurityObfuscation.integrityInstallSecretAccountEncoded, "Encoding should match expected bytes")
	}

	func testXORIsSymmetric() {
		// XOR is its own inverse: (x ^ k) ^ k == x
		let original: [UInt8] = [1, 2, 3, 4, 5, 100, 200, 255]
		let encoded = original.map { $0 ^ SecurityObfuscation.key }
		let decoded = encoded.map { $0 ^ SecurityObfuscation.key }

		XCTAssertEqual(original, decoded, "XOR should be symmetric")
	}

	// MARK: - All Encoded Values Are Non-Empty Tests

	func testAllEncodedValuesAreNonEmpty() {
		XCTAssertFalse(SecurityObfuscation.integrityInstallSecretAccountEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.integrityKeyDerivationSaltEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.agentPermissionSubagentDocumentKeyEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.agentPermissionCodexDocumentKeyEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.agentPermissionClaudeDocumentKeyEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.agentPermissionGeminiDocumentKeyEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.agentPermissionOpenCodeDocumentKeyEncoded.isEmpty)
		XCTAssertFalse(SecurityObfuscation.agentPermissionCursorDocumentKeyEncoded.isEmpty)
	}

	func testAllDecodedValuesAreNonEmpty() {
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.integrityInstallSecretAccountEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.integrityKeyDerivationSaltEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionSubagentDocumentKeyEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionCodexDocumentKeyEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionClaudeDocumentKeyEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionGeminiDocumentKeyEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionOpenCodeDocumentKeyEncoded).isEmpty)
		XCTAssertFalse(SecurityObfuscation.decode(SecurityObfuscation.agentPermissionCursorDocumentKeyEncoded).isEmpty)
	}
}
