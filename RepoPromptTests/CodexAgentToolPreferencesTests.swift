import XCTest
@testable import RepoPrompt

final class CodexAgentToolPreferencesTests: XCTestCase {
	private func makeDefaults() -> UserDefaults {
		let suiteName = "CodexAgentToolPreferencesTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	func testDefaultToolPreferences() {
		let defaults = makeDefaults()

		XCTAssertTrue(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults))
		XCTAssertTrue(CodexAgentToolPreferences.searchToolEnabled(defaults: defaults))
		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .onRequest)
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .workspaceWrite)
		XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(defaults: defaults), .user)
	}

	func testApprovalPolicySerializersUseExpectedRequestAndConfigValues() {
		XCTAssertEqual(
			CodexAgentToolPreferences.ApprovalPolicy.onRequest.appServerRequestValue(style: .configStyle),
			"on-request"
		)
		XCTAssertEqual(
			CodexAgentToolPreferences.ApprovalPolicy.onRequest.appServerRequestValue(style: .camelCase),
			"onRequest"
		)
		XCTAssertEqual(CodexAgentToolPreferences.ApprovalPolicy.onRequest.appServerConfigOverrideValue, "on-request")
		XCTAssertEqual(
			CodexAgentToolPreferences.ApprovalPolicy.unlessTrusted.appServerRequestValue(style: .configStyle),
			"untrusted"
		)
		XCTAssertEqual(
			CodexAgentToolPreferences.ApprovalPolicy.unlessTrusted.appServerRequestValue(style: .camelCase),
			"unlessTrusted"
		)
		XCTAssertEqual(CodexAgentToolPreferences.ApprovalPolicy.unlessTrusted.appServerConfigOverrideValue, "untrusted")
	}

	func testApprovalReviewerSerializersUseLegacyAutoReviewValueForCompatibility() {
		XCTAssertEqual(CodexAgentToolPreferences.ApprovalReviewer.user.appServerRequestValue, "user")
		XCTAssertEqual(CodexAgentToolPreferences.ApprovalReviewer.user.appServerConfigOverrideValue, "user")
		XCTAssertEqual(CodexAgentToolPreferences.ApprovalReviewer.autoReview.appServerRequestValue, "guardian_subagent")
		XCTAssertEqual(CodexAgentToolPreferences.ApprovalReviewer.autoReview.appServerConfigOverrideValue, "guardian_subagent")
	}

	func testSandboxModeSerializersUseExpectedRequestAndConfigValues() {
		XCTAssertEqual(
			CodexAgentToolPreferences.SandboxMode.readOnly.appServerRequestValue(style: .configStyle),
			"read-only"
		)
		XCTAssertEqual(
			CodexAgentToolPreferences.SandboxMode.readOnly.appServerRequestValue(style: .camelCase),
			"readOnly"
		)
		XCTAssertEqual(CodexAgentToolPreferences.SandboxMode.readOnly.appServerConfigOverrideValue, "read-only")
		XCTAssertEqual(
			CodexAgentToolPreferences.SandboxMode.workspaceWrite.appServerRequestValue(style: .configStyle),
			"workspace-write"
		)
		XCTAssertEqual(
			CodexAgentToolPreferences.SandboxMode.workspaceWrite.appServerRequestValue(style: .camelCase),
			"workspaceWrite"
		)
		XCTAssertEqual(CodexAgentToolPreferences.SandboxMode.workspaceWrite.appServerConfigOverrideValue, "workspace-write")
	}

	func testApprovalPolicyDecodesLegacyStoredValues() {
		let defaults = makeDefaults()
		defaults.set("on-request", forKey: "codexAgentTools.bash.approvalPolicy")
		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .onRequest)

		defaults.set("onFailure", forKey: "codexAgentTools.bash.approvalPolicy")
		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .onFailure)

		defaults.set("unless-trusted", forKey: "codexAgentTools.bash.approvalPolicy")
		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .unlessTrusted)

		defaults.set("untrusted", forKey: "codexAgentTools.bash.approvalPolicy")
		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .unlessTrusted)
	}

	func testApprovalReviewerDecodesAcceptedStoredValues() {
		let defaults = makeDefaults()
		defaults.set("auto_review", forKey: "codexAgentTools.approvalsReviewer")
		XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(defaults: defaults), .autoReview)

		defaults.set("guardian_subagent", forKey: "codexAgentTools.approvalsReviewer")
		XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(defaults: defaults), .autoReview)

		defaults.set("user", forKey: "codexAgentTools.approvalsReviewer")
		XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(defaults: defaults), .user)
	}

	func testSandboxModeDecodesLegacyStoredValues() {
		let defaults = makeDefaults()
		defaults.set("read-only", forKey: "codexAgentTools.bash.sandboxMode")
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .readOnly)

		defaults.set("workspace-write", forKey: "codexAgentTools.bash.sandboxMode")
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .workspaceWrite)

		defaults.set("danger-full-access", forKey: "codexAgentTools.bash.sandboxMode")
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .dangerFullAccess)
	}

	func testSettersPersistCanonicalStoredValues() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setApprovalPolicy(.unlessTrusted, defaults: defaults)
		CodexAgentToolPreferences.setSandboxMode(.dangerFullAccess, defaults: defaults)
		CodexAgentToolPreferences.setApprovalReviewer(.autoReview, defaults: defaults)

		XCTAssertEqual(defaults.string(forKey: "codexAgentTools.bash.approvalPolicy"), "unless-trusted")
		XCTAssertEqual(defaults.string(forKey: "codexAgentTools.bash.sandboxMode"), "danger-full-access")
		XCTAssertEqual(defaults.string(forKey: "codexAgentTools.approvalsReviewer"), "auto-review")
	}

	func testRepoPromptServerIsAlwaysEnabled() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: MCPIntegrationHelper.repoPromptMCPServerName,
			isEnabled: false,
			defaults: defaults
		)

		XCTAssertTrue(
			CodexAgentToolPreferences.mcpServerEnabled(
				normalizedName: MCPIntegrationHelper.repoPromptMCPServerName,
				defaults: defaults
			)
		)
	}

	func testMCPServerTogglePersistsForNonRepoPromptServers() {
		let defaults = makeDefaults()
		let datadog = "datadog"

		XCTAssertFalse(CodexAgentToolPreferences.mcpServerEnabled(normalizedName: datadog, defaults: defaults))

		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: datadog,
			isEnabled: true,
			defaults: defaults
		)
		XCTAssertTrue(CodexAgentToolPreferences.mcpServerEnabled(normalizedName: datadog, defaults: defaults))

		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: datadog,
			isEnabled: false,
			defaults: defaults
		)
		XCTAssertFalse(CodexAgentToolPreferences.mcpServerEnabled(normalizedName: datadog, defaults: defaults))
	}

	func testEnabledMCPServerNamesIncludesRepoPromptAndEnabledServers() {
		let defaults = makeDefaults()
		let entries: [MCPIntegrationHelper.CodexServerEntry] = [
			.init(rawName: "RepoPrompt", normalizedName: "RepoPrompt", cliPathComponent: "RepoPrompt"),
			.init(rawName: "datadog", normalizedName: "datadog", cliPathComponent: "datadog"),
			.init(rawName: "context7", normalizedName: "context7", cliPathComponent: "context7")
		]

		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: "context7",
			isEnabled: true,
			defaults: defaults
		)

		let enabledNames = CodexAgentToolPreferences.enabledMCPServerNames(for: entries, defaults: defaults)
		XCTAssertTrue(enabledNames.contains("RepoPrompt"))
		XCTAssertTrue(enabledNames.contains("context7"))
		XCTAssertFalse(enabledNames.contains("datadog"))
	}

	func testPermissionLevelReadOnlyMapsToOnRequestAndReadOnlySandbox() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setPermissionLevel(.readOnly, defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .onRequest)
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .readOnly)
	}

	func testPermissionLevelDefaultMapsToOnRequestAndWorkspaceWriteSandbox() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setPermissionLevel(.defaultPermission, defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .onRequest)
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .workspaceWrite)
		XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(defaults: defaults), .user)
	}

	func testPermissionLevelAutoReviewMapsToOnRequestWorkspaceWriteAndAutoReviewReviewer() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setPermissionLevel(.autoReview, defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .onRequest)
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .workspaceWrite)
		XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(defaults: defaults), .autoReview)
		XCTAssertEqual(CodexAgentToolPreferences.permissionLevel(defaults: defaults), .autoReview)
	}

	func testPermissionLevelFullAccessMapsToNeverAndDangerFullAccessSandbox() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(defaults: defaults), .never)
		XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(defaults: defaults), .dangerFullAccess)
	}

	func testReasoningEffortRoundTripsPerModelSlug() {
		let defaults = makeDefaults()

		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.3-codex-high", defaults: defaults)
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.medium, forModelRaw: "gpt-5.4-medium", defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: "gpt-5.3-codex", defaults: defaults), .high)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: "gpt-5.4", defaults: defaults), .medium)

		let stored = CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)
		XCTAssertEqual(stored["gpt-5.3-codex"], .high)
		XCTAssertEqual(stored["gpt-5.4"], .medium)
	}

	func testReasoningEffortServiceTierSlugPreservesSupportedFastTier() {
		let defaults = makeDefaults()

		XCTAssertEqual(
			CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: "gpt-5.4-fast-high"),
			"gpt-5.4-fast"
		)
		XCTAssertEqual(
			CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: "gpt-5.2-fast-high"),
			"gpt-5.2"
		)

		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.4-fast-high", defaults: defaults)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: "gpt-5.4-fast", defaults: defaults), .high)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)["gpt-5.4-fast"], .high)
	}

	func testPerModelReasoningEffortWriteMirrorsLegacyScalarForRollback() {
		let defaults = makeDefaults()

		CodexAgentToolPreferences.setLastUsedReasoningEffort(.xhigh, forModelRaw: "gpt-5.4-xhigh", defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults), .xhigh)
		XCTAssertEqual(defaults.string(forKey: "codexAgent.reasoning.lastUsedEffort"), "xhigh")
	}

	func testClearingPerModelReasoningEffortDoesNotClearScalarFallback() {
		let defaults = makeDefaults()
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.3-codex-high", defaults: defaults)

		CodexAgentToolPreferences.setLastUsedReasoningEffort(nil, forModelRaw: "gpt-5.3-codex", defaults: defaults)

		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)["gpt-5.3-codex"], nil)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults), .high)
	}

	func testLastUsedReasoningEffortMigratesFromLegacyKey() {
		let defaults = makeDefaults()
		defaults.set("high", forKey: "agentMode.codex.lastUsedReasoningEffort")

		let effort = CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults)

		XCTAssertEqual(effort, .high)
		XCTAssertEqual(defaults.string(forKey: "codexAgent.reasoning.lastUsedEffort"), "high")
		XCTAssertNil(defaults.object(forKey: "agentMode.codex.lastUsedReasoningEffort"))
	}

	func testLastUsedReasoningEffortIgnoresInvalidLegacyValue() {
		let defaults = makeDefaults()
		defaults.set("invalid", forKey: "agentMode.codex.lastUsedReasoningEffort")

		let effort = CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults)

		XCTAssertNil(effort)
		XCTAssertNil(defaults.object(forKey: "codexAgent.reasoning.lastUsedEffort"))
		XCTAssertEqual(defaults.string(forKey: "agentMode.codex.lastUsedReasoningEffort"), "invalid")
	}
}
