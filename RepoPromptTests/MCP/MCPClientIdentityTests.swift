import XCTest
@testable import RepoPrompt

final class MCPClientIdentityTests: XCTestCase {
	func testMatchesKnownClientFamilyAcrossCaseSeparatorAndVersionVariants() {
		XCTAssertTrue(MCPClientIdentity.matches("claude-code", "Claude Code"))
		XCTAssertTrue(MCPClientIdentity.matches("claude-code", "Claude Code 1.2.3"))
		XCTAssertTrue(MCPClientIdentity.matches("gemini-cli-mcp-client", "gemini-cli"))
		XCTAssertTrue(MCPClientIdentity.matches("cursor", "cursor-agent"))
	}

	func testStorageKeyCanonicalizesKnownFamilies() {
		XCTAssertEqual(MCPClientIdentity.storageKey("Claude Code"), "claude-code")
		XCTAssertEqual(MCPClientIdentity.storageKey("gemini-cli"), "gemini-cli-mcp-client")
		XCTAssertEqual(MCPClientIdentity.storageKey("Cursor Agent"), "cursor")
		XCTAssertEqual(MCPClientIdentity.storageKey("unknown-client"), "unknown-client")
	}

	func testDoesNotMatchLookalikeClientNames() {
		XCTAssertFalse(MCPClientIdentity.matches("claude-code", "claudecoder"))
		XCTAssertFalse(MCPClientIdentity.matches("cursor", "cursorless"))
		XCTAssertFalse(MCPClientIdentity.matches("gemini-cli-mcp-client", "gemini-cli-helper"))
	}


	func testHeadlessAgentClientRecognitionUsesSharedMatcher() {
		XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("Claude Code"))
		XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("codex-mcp-client"))
		XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("cursor"))
		XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("cursor-agent"))
	}
}
