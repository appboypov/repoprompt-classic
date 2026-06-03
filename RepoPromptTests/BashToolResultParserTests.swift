import XCTest
@testable import RepoPrompt

final class BashToolResultParserTests: XCTestCase {
	private func assertMetadataMatchesFullParse(
		raw: String,
		argsJSON: String? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let full = BashToolResultParser.parse(raw: raw, argsJSON: argsJSON)
		let metadata = BashToolResultParser.parseMetadata(raw: raw)

		XCTAssertEqual(metadata.isRunning, full.isRunning, file: file, line: line)
		XCTAssertEqual(metadata.statusWord, full.statusWord, file: file, line: line)
		XCTAssertEqual(metadata.exitCode, full.exitCode, file: file, line: line)
		XCTAssertEqual(metadata.processID, full.processID, file: file, line: line)
		XCTAssertEqual(metadata.isSummaryOnly, full.isSummaryOnly, file: file, line: line)
	}

	func testParseRunningCommandUsesRunningStateAndExtractsCommand() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "running",
		  "command": "npm start"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.command, "npm start")
	}

	func testParseCompletedCommandUsesNotRunningState() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "command": "npm start"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.command, "npm start")
	}

	func testParseCommandWithoutTerminalStateTreatsAsRunning() {
		let payload = """
		{
		  "type": "commandExecution",
		  "processId": "12345",
		  "command": "npm --version"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.command, "npm --version")
	}

	func testParseUsesArgsCommandWhenResultOmitsCommand() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "completed"
		}
		"""
		let args = #"{"command":"npm --version"}"#

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: args)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.command, "npm --version")
	}

	func testParseUsesArgsArgvWhenResultOmitsCommand() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "completed"
		}
		"""
		let args = #"{"argv":["npm","--version"]}"#

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: args)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.command, "npm --version")
	}

	func testParseUsesNestedInvocationArgumentsCommandWhenResultOmitsCommand() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "completed"
		}
		"""
		let args = #"{"invocation":{"arguments":"{\"cmd\":\"pnpm lint\"}"}}"#

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: args)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.command, "pnpm lint")
	}

	func testParsePlainTextFallbackUsesArgsCommand() {
		let args = #"{"command":"ls -la"}"#
		let parsed = BashToolResultParser.parse(raw: "Process exited", argsJSON: args)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.command, "ls -la")
	}

	func testParsePlainTextFallbackSurfacesOutput() {
		let parsed = BashToolResultParser.parse(raw: "line 1\nline 2\n", argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.output, "line 1\nline 2\n")
	}

	func testParseCommandDeltaFieldSurfacesOutput() {
		let payload = """
		{
		"type": "commandExecution",
		"status": "running",
		"delta": "chunk line"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.output, "chunk line")
	}

	func testParseCommandWithSuccessFlagIsNotRunning() {
		let payload = """
		{
		  "type": "commandExecution",
		  "processId": "12345",
		  "success": true,
		  "command": "npm --version"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithOkFlagIsNotRunning() {
		let payload = """
		{
		  "type": "commandExecution",
		  "processId": "12345",
		  "ok": true,
		  "command": "npm --version"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithErrorFieldIsNotRunning() {
		let payload = """
		{
		  "type": "commandExecution",
		  "processId": "12345",
		  "error": "permission denied",
		  "command": "npm --version"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithStatusOkAndProcessIDIsNotRunning() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "ok",
		  "processId": "12345",
		  "command": "npm --version"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "ok")
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithoutTypeButWithExitCodeIsNotRunning() {
		let payload = """
		{
		  "status": "completed",
		  "exitCode": 0,
		  "processId": "12345",
		  "command": "npm --version"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.exitCode, 0)
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithInProgressStatusTreatsAsRunning() {
		let payload = """
		{
		"type": "commandExecution",
		"status": "inProgress",
		"processId": "12345",
		"command": "sleep 1"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "inprogress")
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithNegativeExitCodeKeepsRunningWhenProcessStillPresent() {
		let payload = """
		{
		"type": "commandExecution",
		"status": "failed",
		"exitCode": -1,
		"processId": "12345",
		"command": "npm run dev"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.exitCode, -1)
		XCTAssertEqual(parsed.processID, "12345")
	}

	func testParseCommandWithNegativeExitAndDurationTreatsAsTerminal() {
		let payload = """
		{
		"type": "commandExecution",
		"status": "failed",
		"exitCode": -1,
		"processId": "12345",
		"durationMs": 1200,
		"command": "npm run dev"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "failed")
		XCTAssertEqual(parsed.exitCode, -1)
	}

	func testParseStrippedCompletionPayloadWithoutExitCodeTreatsAsTerminal() {
		// After CodexNativeSessionController strips the negative exitCode from a
		// completion payload, the result has status + processId + durationMs but
		// no exitCode. This must NOT be treated as running.
		let payload = """
		{
		"type": "commandExecution",
		"status": "failed",
		"processId": "85178",
		"durationMs": 53758,
		"aggregatedOutput": "hello world"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "failed")
		XCTAssertNil(parsed.exitCode)
	}

	func testParseCommandWithProcessIdOnlyAndTerminalStatusNoExitTreatsAsTerminal() {
		// A minimal payload with terminal status + processId but no exit code or
		// duration should still be terminal (statusWord takes precedence).
		let payload = """
		{
		"type": "commandExecution",
		"status": "failed",
		"processId": "12345"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "failed")
	}

	func testParseSupportsCommandLineFieldForSubtitle() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "running",
		  "commandLine": "npm run lint"
		}
		"""

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.command, "npm run lint")
	}

	func testParseSummaryOnlyPayloadMarksSummaryOnly() {
		let payload = #"{"type":"commandExecution","status":"success","summary_only":true}"#

		let parsed = BashToolResultParser.parse(raw: payload, argsJSON: nil)

		XCTAssertTrue(parsed.isSummaryOnly)
		XCTAssertFalse(parsed.isRunning)
	}

	func testParsePlainTextRunningSessionOutputTreatsAsRunning() {
		let raw = "Chunk ID: 1\nProcess running with session ID 25909\nOutput:\nhello\n"

		let parsed = BashToolResultParser.parse(raw: raw, argsJSON: nil)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "running")
		XCTAssertEqual(parsed.processID, "session:25909")
	}

	func testParsePlainTextCompletedExitCodeTreatsAsTerminal() {
		let raw = "Process completed with exit code 0\n"

		let parsed = BashToolResultParser.parse(raw: raw, argsJSON: nil)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertEqual(parsed.exitCode, 0)
	}

	func testParseMetadataMatchesFullParseForStructuredRunningPayload() {
		let payload = #"{"type":"commandExecution","status":"running","processId":"12345","command":"npm run dev","aggregatedOutput":"hello"}"#

		assertMetadataMatchesFullParse(raw: payload)
	}

	func testParseMetadataMatchesFullParseForStructuredTerminalPayloadWithTimingHint() {
		let payload = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"12345","durationMs":1200,"aggregatedOutput":"done"}"#

		assertMetadataMatchesFullParse(raw: payload)
	}

	func testParseMetadataMatchesFullParseForPlainTextRunningPayload() {
		let raw = "Chunk ID: 1\nProcess running with session ID 25909\nOutput:\nhello\n"

		assertMetadataMatchesFullParse(raw: raw)
	}

	func testParseMetadataPreservesSummaryOnlyFlag() {
		let payload = #"{"type":"commandExecution","status":"success","summary_only":true}"#

		let metadata = BashToolResultParser.parseMetadata(raw: payload)

		XCTAssertTrue(metadata.isSummaryOnly)
		XCTAssertFalse(metadata.isRunning)
	}
}
