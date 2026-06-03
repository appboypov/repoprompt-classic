import XCTest
@testable import RepoPrompt

final class CodexProviderHelpersTests: XCTestCase {
	private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
		let fm = FileManager.default
		let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
		addTeardownBlock {
			try? fm.removeItem(at: tempDir)
		}
		return try body(tempDir)
	}

	private func makeEnvironment(home: URL, path: String? = nil) -> [String: String] {
		[
			"HOME": home.path,
			"PATH": path ?? home.path,
			"SHELL": "/definitely/missing-shell"
		]
	}

	private func writeCodexFile(at url: URL, executable: Bool) throws {
		try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: NSNumber(value: Int(executable ? 0o755 : 0o644))],
			ofItemAtPath: url.path
		)
	}

	func testCodexExecutablePreflightResolvesBunInstallWhenShellLookupUnavailable() throws {
		try withTempDirectory { home in
			let bunBin = home.appendingPathComponent(".bun/bin", isDirectory: true)
			try FileManager.default.createDirectory(at: bunBin, withIntermediateDirectories: true)
			let codexExecutable = bunBin.appendingPathComponent("codex")
			try writeCodexFile(at: codexExecutable, executable: true)

			let resolution = CodexProviderHelpers.resolveCodexExecutable(
				environment: makeEnvironment(home: home, path: "/usr/bin:/bin"),
				additionalPathHints: ["~/.bun/bin"]
			)

			XCTAssertEqual(resolution.status, .available)
			XCTAssertEqual(resolution.resolvedCommand, codexExecutable.path)
			XCTAssertEqual(resolution.userMessage, "")
		}
	}

	func testCodexExecutablePreflightReportsBareFallbackAsNotFound() throws {
		try withTempDirectory { home in
			let resolution = CodexProviderHelpers.resolveCodexExecutable(
				environment: makeEnvironment(home: home),
				additionalPathHints: []
			)

			XCTAssertEqual(resolution.status, .notFound)
			XCTAssertEqual(resolution.resolvedCommand, "codex")
			XCTAssertTrue(resolution.userMessage.contains("Codex CLI executable was not found"))
			XCTAssertTrue(CodexProviderHelpers.isCodexExecutableUnavailableMessage(resolution.userMessage))
		}
	}

	func testCodexExecutablePreflightReportsMissingResolvedPath() throws {
		try withTempDirectory { home in
			let missingCodex = home.appendingPathComponent("missing-codex")
			let resolution = CodexProviderHelpers.resolveCodexExecutable(
				commandName: missingCodex.path,
				environment: makeEnvironment(home: home),
				additionalPathHints: []
			)

			XCTAssertEqual(resolution.status, .missingResolvedPath)
			XCTAssertEqual(resolution.resolvedCommand, missingCodex.path)
			XCTAssertTrue(resolution.userMessage.contains("that file does not exist"))
			XCTAssertTrue(CodexProviderHelpers.isCodexExecutableUnavailableMessage(resolution.userMessage))
		}
	}

	func testCodexExecutablePreflightReportsDirectory() throws {
		try withTempDirectory { home in
			let codexDirectory = home.appendingPathComponent("codex", isDirectory: true)
			try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

			let resolution = CodexProviderHelpers.resolveCodexExecutable(
				environment: makeEnvironment(home: home),
				additionalPathHints: []
			)

			XCTAssertEqual(resolution.status, .resolvedToDirectory)
			XCTAssertEqual(resolution.resolvedCommand, codexDirectory.path)
			XCTAssertTrue(resolution.userMessage.contains("path is a directory"))
			XCTAssertTrue(CodexProviderHelpers.isCodexExecutableUnavailableMessage(resolution.userMessage))
		}
	}

	func testCodexExecutablePreflightReportsNotExecutable() throws {
		try withTempDirectory { home in
			let codexFile = home.appendingPathComponent("codex")
			try writeCodexFile(at: codexFile, executable: false)

			let resolution = CodexProviderHelpers.resolveCodexExecutable(
				environment: makeEnvironment(home: home),
				additionalPathHints: []
			)

			XCTAssertEqual(resolution.status, .notExecutable)
			XCTAssertEqual(resolution.resolvedCommand, codexFile.path)
			XCTAssertTrue(resolution.userMessage.contains("not executable"))
			XCTAssertTrue(CodexProviderHelpers.isCodexExecutableUnavailableMessage(resolution.userMessage))
		}
	}

	func testExecutableUnavailableClassifierDoesNotMatchManagedAuthGuidance() {
		XCTAssertFalse(CodexProviderHelpers.isCodexExecutableUnavailableMessage("Please sign in with ChatGPT to continue."))
		XCTAssertFalse(CodexProviderHelpers.isCodexExecutableUnavailableMessage("Codex managed auth refresh failed; run codex login."))
	}

	func testExtractBrokenServerNameHandlesBackticksAndNewline() {
		let stderr = """
		Error: invalid transport
		in `mcp_servers.RepoPrompt`
		"""
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "RepoPrompt")
	}

	func testExtractBrokenServerNameHandlesSingleQuotesInline() {
		let stderr = "Error: invalid transport in 'mcp_servers.datadog'"
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "datadog")
	}

	func testExtractBrokenServerNameHandlesDoubleQuotesAndMixedCase() {
		let stderr = "ERROR: INVALID TRANSPORT IN \"mcp_servers.Some-Server_01\""
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "Some-Server_01")
	}

	func testExtractBrokenServerNameHandlesNoQuotes() {
		let stderr = "Error: invalid transport in mcp_servers.repo prompt config"
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "repo prompt config")
	}

	func testExtractBrokenServerNameReturnsFirstMatchWhenMultiple() {
		let stderr = """
		Error: invalid transport in 'mcp_servers.first'
		Additional details...
		Error: invalid transport in 'mcp_servers.second'
		"""
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "first")
	}

	func testExtractBrokenServerNameReturnsNilForUnrelatedErrors() {
		let stderr = "Fatal: something else happened"
		XCTAssertNil(CodexProviderHelpers.extractBrokenServerName(from: stderr))
	}

	func testExtractBrokenServerNameHandlesMCPClientTimeout() {
		let stderr = "2025-11-15T01:03:19.923947Z ERROR codex_core::codex: MCP client for `RepoPrompt` failed to start: request timed out"
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "RepoPrompt")
	}

	func testExtractBrokenServerNameHandlesMCPClientFailureWithoutBackticks() {
		let stderr = "MCP client for 'ServerName' failed to start"
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "ServerName")
	}

	func testExtractBrokenServerNameHandlesMCPClientWithDoubleQuotes() {
		let stderr = "MCP client for \"Some Server\" failed to start: connection refused"
		XCTAssertEqual(CodexProviderHelpers.extractBrokenServerName(from: stderr), "Some Server")
	}

	func testCodexFallbackModelIfNeededMapsReasoningTierForModelNotFound() {
		let detail = """
		{
		  "error": {
		    "message": "The requested model 'gpt-5.3-codex' does not exist.",
		    "type": "invalid_request_error",
		    "param": "model",
		    "code": "model_not_found"
		  }
		}
		"""
		XCTAssertEqual(
			CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "gpt-5.3-codex-medium", errorDetail: detail),
			"gpt-5.2-codex-medium"
		)
		XCTAssertEqual(
			CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "gpt-5.3-codex-low", errorDetail: detail),
			"gpt-5.2-codex-low"
		)
		XCTAssertEqual(
			CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "gpt-5.3-codex-high", errorDetail: detail),
			"gpt-5.2-codex-high"
		)
		XCTAssertEqual(
			CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "gpt-5.3-codex-xhigh", errorDetail: detail),
			"gpt-5.2-codex-xhigh"
		)
	}

	func testCodexFallbackModelIfNeededReturnsNilForNonMatchingCases() {
		let missingDetail = "The requested model 'gpt-5.3-codex' does not exist. code=model_not_found"
		XCTAssertNil(CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: nil, errorDetail: missingDetail))
		XCTAssertNil(CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "default", errorDetail: missingDetail))
		XCTAssertNil(CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "gpt-5.2-codex-medium", errorDetail: missingDetail))
		XCTAssertNil(CodexProviderHelpers.codexFallbackModelIfNeeded(attemptedModel: "gpt-5.3-codex-medium", errorDetail: "Rate limited"))
	}

	func testNormalizedAssistantDeltaForAppendInsertsNewlineAtSentenceSeam() {
		let normalized = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
			existingText: "Build is still running.",
			delta: "I’m keeping the same xcodetester job active."
		)
		XCTAssertEqual(normalized, "\nI’m keeping the same xcodetester job active.")
	}

	func testNormalizedAssistantDeltaForAppendDoesNotChangeExistingWhitespaceSeparatedText() {
		let normalized = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
			existingText: "Build is still running.",
			delta: " I’m keeping the same xcodetester job active."
		)
		XCTAssertEqual(normalized, " I’m keeping the same xcodetester job active.")
	}

	func testNormalizedAssistantDeltaForAppendDoesNotBreakLowercaseContinuation() {
		let normalized = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
			existingText: "Use e.g.",
			delta: "when the shorter form is fine."
		)
		XCTAssertEqual(normalized, "when the shorter form is fine.")
	}

	func testNormalizedAssistantDeltaForAppendDoesNotChangeFencedCodeBlockContent() {
		let normalized = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
			existingText: "```swift\nlet value = foo.",
			delta: "Bar()\n```"
		)
		XCTAssertEqual(normalized, "Bar()\n```")
	}

	func testNormalizedAssistantDeltaForAppendDoesNotChangeInlineCodeContent() {
		let normalized = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
			existingText: "Call `foo.",
			delta: "Bar()` before retrying."
		)
		XCTAssertEqual(normalized, "Bar()` before retrying.")
	}

	func testNormalizedAssistantDeltaForAppendDoesNotChangeMemberLikeSeam() {
		let normalized = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
			existingText: "Use foo.",
			delta: "Bar() when ready."
		)
		XCTAssertEqual(normalized, "Bar() when ready.")
	}
}
