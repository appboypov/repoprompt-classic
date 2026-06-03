import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelAutoEditGuidanceTests: XCTestCase {
	private func makeGuidance(
		agent: DiscoverAgentKind,
		autoEditEnabled: Bool,
		codexPermissionLevel: CodexAgentToolPreferences.PermissionLevel = .defaultPermission,
		claudePermissionLevel: ClaudeAgentToolPreferences.PermissionLevel = .autoApproveEdits,
		claudeBashToolEnabled: Bool = true
	) -> AgentModeViewModel.AutoEditPermissionGuidance? {
		AgentModeViewModel.autoEditPermissionGuidance(
			agent: agent,
			autoEditEnabled: autoEditEnabled,
			codexPermissionLevel: codexPermissionLevel,
			claudePermissionLevel: claudePermissionLevel,
			claudeBashToolEnabled: claudeBashToolEnabled
		)
	}

	func testAutoEditOnSuppressesGuidance() {
		XCTAssertNil(makeGuidance(agent: .codexExec, autoEditEnabled: true))
		XCTAssertNil(makeGuidance(agent: .claudeCode, autoEditEnabled: true))
	}

	func testCodexDefaultPermissionSuggestsReadOnly() {
		let guidance = makeGuidance(agent: .codexExec, autoEditEnabled: false)

		XCTAssertEqual(guidance?.provider, .codex)
		XCTAssertEqual(guidance?.action, .setCodexReadOnly)
		XCTAssertEqual(guidance?.actionTitle, "Set Read Only")
		XCTAssertEqual(guidance?.message, "Codex sandbox allows file edits — set Read Only")
	}

	func testCodexReadOnlyNeedsNoGuidance() {
		XCTAssertNil(
			makeGuidance(
				agent: .codexExec,
				autoEditEnabled: false,
				codexPermissionLevel: .readOnly
			)
		)
	}

	func testClaudeUnsafePermissionSuggestsRequireApproval() {
		let guidance = makeGuidance(agent: .claudeCode, autoEditEnabled: false)

		XCTAssertEqual(guidance?.provider, .claude)
		XCTAssertEqual(guidance?.action, .setClaudeRequireApproval)
		XCTAssertEqual(guidance?.actionTitle, "Set Require Approval")
		XCTAssertEqual(guidance?.message, "Claude sandbox allows file edits — set Require Approval")
	}

	// Bash tool state is no longer part of the Claude recommendation — only permission level matters.
	func testClaudeUnsafePermissionWithBashOffSuggestsRequireApproval() {
		let guidance = makeGuidance(
			agent: .claudeCode,
			autoEditEnabled: false,
			claudePermissionLevel: .autoApproveEdits,
			claudeBashToolEnabled: false
		)

		XCTAssertEqual(guidance?.provider, .claude)
		XCTAssertEqual(guidance?.action, .setClaudeRequireApproval)
		XCTAssertEqual(guidance?.actionTitle, "Set Require Approval")
		XCTAssertEqual(guidance?.message, "Claude sandbox allows file edits — set Require Approval")
	}

	func testClaudeRequireApprovalNeedsNoGuidance() {
		XCTAssertNil(
			makeGuidance(
				agent: .claudeCode,
				autoEditEnabled: false,
				claudePermissionLevel: .requireApproval
			)
		)
	}

	// Bash tool being on while Require Approval is set no longer triggers guidance.
	func testClaudeRequireApprovalWithBashOnNeedsNoGuidance() {
		XCTAssertNil(
			makeGuidance(
				agent: .claudeCode,
				autoEditEnabled: false,
				claudePermissionLevel: .requireApproval,
				claudeBashToolEnabled: true
			)
		)
	}

	func testGeminiNeedsNoGuidance() {
		XCTAssertNil(makeGuidance(agent: .gemini, autoEditEnabled: false))
	}
}
