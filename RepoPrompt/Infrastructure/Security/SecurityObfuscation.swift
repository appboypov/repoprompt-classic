//
//  SecurityObfuscation.swift
//  RepoPrompt
//
//  Centralized XOR obfuscation for security-sensitive strings.
//  Encoded values are internal for testability; decoded values stay private to each consumer.
//

import Foundation

enum SecurityObfuscation {
	static let key: UInt8 = 0x5A

	static func decode(_ bytes: [UInt8]) -> String {
		let decoded = bytes.map { $0 ^ key }
		return String(bytes: decoded, encoding: .utf8) ?? ""
	}

	// MARK: - KeychainService Keys

	static let integrityInstallSecretAccountEncoded: [UInt8] = [
		40, 42, 5, 51, 52, 46, 63, 61, 40, 51, 46, 35, 5, 51, 52, 41,
		46, 59, 54, 54, 5, 41, 63, 57, 40, 63, 46, 5, 44, 107
	]

	static let integrityKeyDerivationSaltEncoded: [UInt8] = [
		8, 63, 42, 53, 10, 40, 53, 55, 42, 46, 9, 63, 57, 47, 40, 51,
		46, 35, 9, 59, 54, 46, 119, 44, 104
	]

	// MARK: - Agent Permission Secure Store Keys

	static let agentPermissionSubagentDocumentKeyEncoded: [UInt8] = [
		40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
		51, 53, 52, 41, 116, 41, 47, 56, 59, 61, 63, 52, 46, 116, 44, 107
	]

	static let agentPermissionCodexDocumentKeyEncoded: [UInt8] = [
		40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
		51, 53, 52, 41, 116, 57, 53, 62, 63, 34, 116, 44, 107
	]

	static let agentPermissionClaudeDocumentKeyEncoded: [UInt8] = [
		40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
		51, 53, 52, 41, 116, 57, 54, 59, 47, 62, 63, 116, 44, 107
	]

	static let agentPermissionGeminiDocumentKeyEncoded: [UInt8] = [
		40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
		51, 53, 52, 41, 116, 61, 63, 55, 51, 52, 51, 116, 44, 107
	]

	static let agentPermissionOpenCodeDocumentKeyEncoded: [UInt8] = [
		40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
		51, 53, 52, 41, 116, 53, 42, 63, 52, 25, 53, 62, 63, 116, 44, 107
	]

	static let agentPermissionCursorDocumentKeyEncoded: [UInt8] = [
		40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
		51, 53, 52, 41, 116, 57, 47, 40, 41, 53, 40, 116, 44, 107
	]
}
