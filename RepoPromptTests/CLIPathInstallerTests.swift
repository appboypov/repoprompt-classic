import XCTest
@testable import RepoPrompt

final class CLIPathInstallerTests: XCTestCase {
	func testClaudeRPScriptExportsClaudeProcessEnvironmentOverrides() {
		let script = CLIPathInstaller.test_claudeRPScriptContent()

		XCTAssertTrue(script.contains("export MCP_TIMEOUT=${MCP_TIMEOUT:-30000}"))
		XCTAssertTrue(script.contains("export MCP_TOOL_TIMEOUT=${MCP_TOOL_TIMEOUT:-10800000}"))
		XCTAssertTrue(script.contains("export MAX_MCP_OUTPUT_TOKENS=${MAX_MCP_OUTPUT_TOKENS:-25000}"))
		XCTAssertTrue(script.contains("exec claude --mcp-config"))
		XCTAssertTrue(script.contains("--strict-mcp-config"))
	}
}
