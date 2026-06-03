import XCTest
@testable import RepoPrompt

@MainActor
final class AgentProviderPreferenceSnapshotStoreTests: XCTestCase {
	private final class InMemorySecureStrings: SecureIntegrityStringStoring {
		var values: [String: String] = [:]

		func getPlainValue(for key: String) throws -> String? {
			values[key]
		}

		func savePlainValue(_ value: String, for key: String) throws {
			values[key] = value
		}

		func deletePlainValue(for key: String) throws {
			values.removeValue(forKey: key)
		}

		func getIntegrityProtectedValue(for key: String) throws -> String? {
			values[key]
		}

		func saveIntegrityProtectedValue(_ value: String, for key: String) throws {
			values[key] = value
		}

		func deleteIntegrityProtectedValue(for key: String) throws {
			values.removeValue(forKey: key)
		}
	}

	private func makeDefaults() -> UserDefaults {
		let suiteName = "AgentProviderPreferenceSnapshotStoreTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	private func makeStore(
		defaults: UserDefaults,
		securePermissions: AgentPermissionSecureStore? = nil,
		codexEntries: [MCPIntegrationHelper.CodexServerEntry] = []
	) -> AgentProviderPreferenceSnapshotStore {
		AgentProviderPreferenceSnapshotStore(
			defaults: defaults,
			securePermissions: securePermissions,
			codexMCPServerEntries: { codexEntries }
		)
	}

	private func makeSecureStore(
		defaults: UserDefaults,
		secureStrings: InMemorySecureStrings = InMemorySecureStrings()
	) -> AgentPermissionSecureStore {
		AgentPermissionSecureStore(
			secureStrings: secureStrings,
			legacyDefaults: defaults,
			notificationCenter: NotificationCenter()
		)
	}

	private func selectedOption(in binding: AgentProviderControlsBinding) throws -> AgentPermissionOptionBinding {
		try XCTUnwrap(binding.permission.options.first { $0.isSelected })
	}

	func testProviderBindingIDMapsClaudeVariantsTogether() {
		XCTAssertEqual(DiscoverAgentKind.codexExec.providerBindingID, .codex)
		XCTAssertEqual(DiscoverAgentKind.claudeCode.providerBindingID, .claude)
		XCTAssertEqual(DiscoverAgentKind.claudeCodeGLM.providerBindingID, .claude)
		XCTAssertEqual(DiscoverAgentKind.kimiCode.providerBindingID, .claude)
		XCTAssertEqual(DiscoverAgentKind.customClaudeCompatible.providerBindingID, .claude)
		XCTAssertEqual(DiscoverAgentKind.gemini.providerBindingID, .gemini)
		XCTAssertEqual(DiscoverAgentKind.openCode.providerBindingID, .openCode)
		XCTAssertEqual(DiscoverAgentKind.cursor.providerBindingID, .cursor)
	}

	func testClaudeToolSearchDefaultsOffUntilExplicitlyEnabled() {
		let defaults = makeDefaults()

		XCTAssertFalse(ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults))

		ClaudeAgentToolPreferences.setToolSearchEnabled(true, defaults: defaults)
		XCTAssertTrue(ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults))

		ClaudeAgentToolPreferences.setToolSearchEnabled(false, defaults: defaults)
		XCTAssertFalse(ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults))
	}

	func testRuntimePermissionUsesUserConfiguredProviderPreferences() {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		CodexAgentToolPreferences.setSandboxMode(.dangerFullAccess, defaults: defaults)
		CodexAgentToolPreferences.setApprovalPolicy(.onFailure, defaults: defaults)
		CodexAgentToolPreferences.setApprovalReviewer(.autoReview, defaults: defaults)
		ClaudeAgentToolPreferences.setPermissionMode("customClaudeMode", defaults: defaults)
		GeminiAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let codex = store.runtimePermission(for: .codexExec, profile: .userConfigured)
		XCTAssertEqual(codex.codexSandboxMode, .dangerFullAccess)
		XCTAssertEqual(codex.codexApprovalPolicy, .onFailure)
		XCTAssertEqual(codex.codexApprovalReviewer, .autoReview)

		let claude = store.runtimePermission(for: .claudeCodeGLM, profile: .userConfigured)
		XCTAssertEqual(claude.claudePermissionMode, "customClaudeMode")

		let kimi = store.runtimePermission(for: .kimiCode, profile: .userConfigured)
		XCTAssertEqual(kimi.claudePermissionMode, "customClaudeMode")

		let customClaudeCompatible = store.runtimePermission(for: .customClaudeCompatible, profile: .userConfigured)
		XCTAssertEqual(customClaudeCompatible.claudePermissionMode, "customClaudeMode")

		let gemini = store.runtimePermission(for: .gemini, profile: .userConfigured)
		XCTAssertEqual(gemini.acpSessionModeID, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
		XCTAssertTrue(gemini.autoApproveAllACPToolPermissions)
		XCTAssertTrue(gemini.acceptsPendingACPApprovalWhenActivated)

		let openCode = store.runtimePermission(for: .openCode, profile: .userConfigured)
		XCTAssertEqual(openCode.acpSessionModeID, OpenCodeAgentConfig.managedFullAccessSessionModeID)
		XCTAssertTrue(openCode.acceptsPendingACPApprovalWhenActivated)

		let cursor = store.runtimePermission(for: .cursor, profile: .userConfigured)
		XCTAssertNil(cursor.acpSessionModeID)
		XCTAssertTrue(cursor.autoApproveAllACPToolPermissions)
	}

	func testSecureStoreBackedRuntimePermissionUsesInjectedSensitivePreferences() throws {
		let defaults = makeDefaults()
		let secureStore = makeSecureStore(defaults: defaults)
		let entry = MCPIntegrationHelper.CodexServerEntry(
			rawName: "ExternalSrv",
			normalizedName: "externalsrv",
			cliPathComponent: "externalsrv"
		)
		let store = makeStore(defaults: defaults, securePermissions: secureStore, codexEntries: [entry])

		store.setPermissionLevel(.codex(.fullAccess))
		store.setPermissionLevel(.claude(.fullAccess))
		store.setPermissionLevel(.gemini(.fullAccess))
		store.setPermissionLevel(.openCode(.fullAccess))
		store.setPermissionLevel(.cursor(.fullAccess))
		store.setCodexBashToolEnabled(true)
		store.setCodexMCPServerEnabled(normalizedName: entry.normalizedName, enabled: true)
		store.setClaudeBashToolEnabled(true)
		store.setClaudeMCPStrictModeEnabled(false)

		let codex = store.runtimePermission(for: .codexExec, profile: .userConfigured)
		XCTAssertEqual(codex.codexSandboxMode, .dangerFullAccess)
		XCTAssertEqual(codex.codexApprovalPolicy, .never)
		XCTAssertEqual(codex.codexApprovalReviewer, .user)
		XCTAssertEqual(CodexAgentToolPreferences.permissionLevel(defaults: defaults), .defaultPermission)

		let claude = store.runtimePermission(for: .claudeCode, profile: .userConfigured)
		XCTAssertEqual(claude.claudePermissionMode, ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode)
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .requireApproval)

		let gemini = store.runtimePermission(for: .gemini, profile: .userConfigured)
		XCTAssertEqual(gemini.acpSessionModeID, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
		XCTAssertTrue(gemini.autoApproveAllACPToolPermissions)
		XCTAssertTrue(gemini.acceptsPendingACPApprovalWhenActivated)

		let openCode = store.runtimePermission(for: .openCode, profile: .userConfigured)
		XCTAssertEqual(openCode.acpSessionModeID, OpenCodeAgentConfig.managedFullAccessSessionModeID)
		XCTAssertTrue(openCode.acceptsPendingACPApprovalWhenActivated)

		let cursor = store.runtimePermission(for: .cursor, profile: .userConfigured)
		XCTAssertTrue(cursor.autoApproveAllACPToolPermissions)

		let userBinding = store.controlsBinding(
			selectedAgent: .codexExec,
			permissionProfile: .userConfigured,
			isSubagent: false,
			externallyManagedReason: nil
		)
		let codexTools = try XCTUnwrap(userBinding.codexTools)
		XCTAssertTrue(codexTools.bashToolEnabled)
		XCTAssertEqual(codexTools.mcpServerStatesByNormalizedName[entry.normalizedName], true)

		let safeBinding = store.controlsBinding(
			selectedAgent: .codexExec,
			permissionProfile: .mcpSafeDefaults,
			isSubagent: true,
			externallyManagedReason: "safe"
		)
		let safeCodexTools = try XCTUnwrap(safeBinding.codexTools)
		XCTAssertFalse(safeCodexTools.bashToolEnabled, "Safe Managed still overrides secure permissive Bash")
		XCTAssertEqual(safeCodexTools.mcpServerStatesByNormalizedName[entry.normalizedName], false)
	}

	func testRuntimePermissionSafeDefaultsOverridePermissivePreferences() {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		CodexAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		GeminiAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let codex = store.runtimePermission(for: .codexExec, profile: .mcpSafeDefaults)
		XCTAssertEqual(codex.codexSandboxMode, .workspaceWrite)
		XCTAssertEqual(codex.codexApprovalPolicy, .onRequest)
		XCTAssertEqual(codex.codexApprovalReviewer, .user)

		let claude = store.runtimePermission(for: .claudeCode, profile: .mcpSafeDefaults)
		XCTAssertEqual(claude.claudePermissionMode, ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode)

		let gemini = store.runtimePermission(for: .gemini, profile: .mcpSafeDefaults)
		XCTAssertEqual(gemini.acpSessionModeID, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
		XCTAssertFalse(gemini.autoApproveAllACPToolPermissions)
		XCTAssertFalse(gemini.acceptsPendingACPApprovalWhenActivated)

		let openCode = store.runtimePermission(for: .openCode, profile: .mcpSafeDefaults)
		XCTAssertEqual(openCode.acpSessionModeID, OpenCodeAgentConfig.managedSessionModeID)
		XCTAssertFalse(openCode.acceptsPendingACPApprovalWhenActivated)

		let cursor = store.runtimePermission(for: .cursor, profile: .mcpSafeDefaults)
		XCTAssertNil(cursor.acpSessionModeID)
		XCTAssertFalse(cursor.autoApproveAllACPToolPermissions)
	}

	func testSafeDefaultsDisplayUsesEffectiveSafeLevelAndDisablesManagedOptions() throws {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)
		let reason = "Managed by test"

		CodexAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		GeminiAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let cases: [(DiscoverAgentKind, AgentProviderPermissionLevelID, String)] = [
			(.codexExec, .codex(.defaultPermission), "Default"),
			(.claudeCode, .claude(.requireApproval), "Require Approval"),
			(.gemini, .gemini(.default), "Default"),
			(.openCode, .openCode(.managedDefault), "Default"),
			(.cursor, .cursor(.managedDefault), "Default")
		]

		for (agent, selectedID, displayName) in cases {
			let binding = store.controlsBinding(
				selectedAgent: agent,
				permissionProfile: .mcpSafeDefaults,
				isSubagent: false,
				externallyManagedReason: reason
			)

			XCTAssertEqual(binding.permission.displayName, displayName, "Unexpected display name for \(agent)")
			XCTAssertFalse(binding.permission.isWarning, "Safe defaults should not render warning state for \(agent)")
			XCTAssertEqual(binding.permission.externallyManagedReason, reason)
			XCTAssertEqual(try selectedOption(in: binding).id, selectedID)
			XCTAssertTrue(binding.permission.options.allSatisfy { !$0.isEnabled })
		}
	}

	func testProviderOverrideDisplaySelectsConcreteLevelAndDisablesManagedOptions() throws {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)
		let reason = "Managed by custom sub-agent policy"

		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let binding = store.controlsBinding(
			selectedAgent: .claudeCode,
			permissionProfile: .providerOverride(.claude(.autoApproveEdits)),
			isSubagent: true,
			externallyManagedReason: reason
		)

		XCTAssertEqual(binding.permission.displayName, "Auto-approve Edits")
		XCTAssertFalse(binding.permission.isWarning)
		XCTAssertEqual(binding.permission.externallyManagedReason, reason)
		XCTAssertEqual(try selectedOption(in: binding).id, .claude(.autoApproveEdits))
		XCTAssertTrue(binding.permission.options.allSatisfy { !$0.isEnabled })
	}

	func testUserConfiguredDisplayUsesPersistedFullAccessAndLeavesOptionsEnabled() throws {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let binding = store.controlsBinding(
			selectedAgent: .cursor,
			permissionProfile: .userConfigured,
			isSubagent: false,
			externallyManagedReason: nil
		)

		XCTAssertEqual(binding.permission.displayName, "Full Access")
		XCTAssertTrue(binding.permission.isWarning)
		XCTAssertNil(binding.permission.externallyManagedReason)
		XCTAssertEqual(try selectedOption(in: binding).id, .cursor(.fullAccess))
		XCTAssertTrue(binding.permission.options.allSatisfy(\.isEnabled))
	}

	func testTopLevelSettingsControlsBindingUsesUserConfiguredEditableProvider() throws {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let binding = store.topLevelSettingsControlsBinding(providerID: .cursor)

		XCTAssertEqual(binding.selectedAgent, .cursor)
		XCTAssertEqual(binding.providerID, .cursor)
		XCTAssertEqual(binding.permission.displayName, "Full Access")
		XCTAssertTrue(binding.permission.isWarning)
		XCTAssertNil(binding.permission.externallyManagedReason)
		XCTAssertEqual(try selectedOption(in: binding).id, .cursor(.fullAccess))
		XCTAssertTrue(binding.permission.options.allSatisfy(\.isEnabled))
	}

	func testServiceTopLevelSettingsControlsBindingDelegatesToSnapshotStore() throws {
		let defaults = makeDefaults()
		let service = AgentModeProviderBindingService(preferences: makeStore(defaults: defaults))

		CodexAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let binding = service.topLevelSettingsControlsBinding(providerID: .codex)

		XCTAssertEqual(binding.selectedAgent, .codexExec)
		XCTAssertEqual(binding.providerID, .codex)
		XCTAssertEqual(try selectedOption(in: binding).id, .codex(.fullAccess))
		XCTAssertNil(binding.permission.externallyManagedReason)
		XCTAssertTrue(binding.permission.options.allSatisfy(\.isEnabled))
	}

	func testStoreSetPermissionLevelWritesExistingDefaultsAndBumpsOnlyProviderRevision() {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		XCTAssertEqual(store.revision(for: .cursor), 0)
		XCTAssertEqual(store.revision(for: .codex), 0)

		let providerID = store.setPermissionLevel(.cursor(.fullAccess))

		XCTAssertEqual(providerID, .cursor)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .fullAccess)
		XCTAssertEqual(store.revision(for: .cursor), 1)
		XCTAssertEqual(store.revision(for: .codex), 0)
	}

	func testSafeProfileOverridesClaudeToolLevelPreferences() throws {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		// Permissive user config: Bash on, strict-mode off, tool-search on, Full Access.
		ClaudeAgentToolPreferences.setBashToolEnabled(true, defaults: defaults)
		ClaudeAgentToolPreferences.setMCPStrictModeEnabled(false, defaults: defaults)
		ClaudeAgentToolPreferences.setToolSearchEnabled(true, defaults: defaults)
		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

		let safeBinding = store.controlsBinding(
			selectedAgent: .claudeCode,
			permissionProfile: .mcpSafeDefaults,
			isSubagent: true,
			externallyManagedReason: "safe"
		)
		let claudeTools = try XCTUnwrap(safeBinding.claudeTools)
		XCTAssertFalse(claudeTools.bashToolEnabled, "Safe Managed must force Claude Bash off")
		XCTAssertTrue(claudeTools.mcpStrictModeEnabled, "Safe Managed must force Claude MCP strict mode on")
		XCTAssertTrue(claudeTools.toolSearchEnabled, "Safe Managed keeps Claude tool search allowed")

		// User-configured profile still reflects the persisted permissive values.
		let userBinding = store.controlsBinding(
			selectedAgent: .claudeCode,
			permissionProfile: .userConfigured,
			isSubagent: false,
			externallyManagedReason: nil
		)
		let userClaudeTools = try XCTUnwrap(userBinding.claudeTools)
		XCTAssertTrue(userClaudeTools.bashToolEnabled)
		XCTAssertFalse(userClaudeTools.mcpStrictModeEnabled)
		XCTAssertTrue(userClaudeTools.toolSearchEnabled)
	}

	func testClaudeControlsBindingUsesSelectedModelSpecificEffort() throws {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		ClaudeAgentToolPreferences.setEffortLevel(
			.xhigh,
			forModelRaw: AgentModel.claudeOpus.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)
		ClaudeAgentToolPreferences.setEffortLevel(
			.high,
			forModelRaw: AgentModel.claudeSonnet.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)
		ClaudeAgentToolPreferences.setEffortLevel(.low, defaults: defaults)

		let opusBinding = store.controlsBinding(
			selectedAgent: .claudeCode,
			selectedModelRaw: AgentModel.claudeOpus.rawValue,
			permissionProfile: .userConfigured,
			isSubagent: false,
			externallyManagedReason: nil
		)
		XCTAssertEqual(try XCTUnwrap(opusBinding.claudeTools).effortLevel, .xhigh)

		let sonnetSafeBinding = store.controlsBinding(
			selectedAgent: .claudeCode,
			selectedModelRaw: AgentModel.claudeSonnet.rawValue,
			permissionProfile: .mcpSafeDefaults,
			isSubagent: true,
			externallyManagedReason: "safe"
		)
		XCTAssertEqual(try XCTUnwrap(sonnetSafeBinding.claudeTools).effortLevel, .high)

		let topLevelBinding = store.topLevelSettingsControlsBinding(providerID: .claude)
		XCTAssertEqual(try XCTUnwrap(topLevelBinding.claudeTools).effortLevel, .low)
	}

	func testServiceSetClaudeEffortLevelForModelPersistsModelSpecificPreference() {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)
		let service = AgentModeProviderBindingService(preferences: store)

		XCTAssertEqual(store.revision(for: .claude), 0)

		service.setClaudeEffortLevel(.xhigh, forModelRaw: AgentModel.claudeOpus.rawValue, agentKind: .claudeCode)

		XCTAssertEqual(store.revision(for: .claude), 1)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.storedEffortLevel(
				forModelRaw: AgentModel.claudeOpus.rawValue,
				agentKind: .claudeCode,
				defaults: defaults,
				includeLegacyFallback: false
			),
			.xhigh
		)
		XCTAssertEqual(
			service.claudeEffortLevel(forModelRaw: AgentModel.claudeOpus.rawValue, agentKind: .claudeCode),
			.xhigh
		)
	}

	func testSafeProfileOverridesCodexToolLevelPreferences() throws {
		let defaults = makeDefaults()
		let entry = MCPIntegrationHelper.CodexServerEntry(
			rawName: "ExternalSrv",
			normalizedName: "externalsrv",
			cliPathComponent: "externalsrv"
		)
		let store = makeStore(defaults: defaults, codexEntries: [entry])

		CodexAgentToolPreferences.setBashToolEnabled(true, defaults: defaults)
		CodexAgentToolPreferences.setSearchToolEnabled(true, defaults: defaults)
		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: entry.normalizedName,
			isEnabled: true,
			defaults: defaults
		)

		let safeBinding = store.controlsBinding(
			selectedAgent: .codexExec,
			permissionProfile: .mcpSafeDefaults,
			isSubagent: true,
			externallyManagedReason: "safe"
		)
		let codexTools = try XCTUnwrap(safeBinding.codexTools)
		XCTAssertFalse(codexTools.bashToolEnabled, "Safe Managed must force Codex Bash off")
		XCTAssertTrue(codexTools.searchToolEnabled, "Safe Managed keeps Codex search allowed")
		let safeState = codexTools.mcpServerStatesByNormalizedName[entry.normalizedName]
		XCTAssertEqual(safeState, false, "Safe Managed must suppress user-toggled Codex MCP servers")

		let userBinding = store.controlsBinding(
			selectedAgent: .codexExec,
			permissionProfile: .userConfigured,
			isSubagent: false,
			externallyManagedReason: nil
		)
		let userCodexTools = try XCTUnwrap(userBinding.codexTools)
		XCTAssertTrue(userCodexTools.bashToolEnabled)
		XCTAssertEqual(userCodexTools.mcpServerStatesByNormalizedName[entry.normalizedName], true)
	}

	func testServiceResolvesSubagentPolicyForCustomGlobalPerProvider() {
		let defaults = makeDefaults()
		let service = AgentModeProviderBindingService(preferences: makeStore(defaults: defaults))

		AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
			.claude(.autoApproveEdits),
			for: .claude,
			defaults: defaults
		)
		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
			.codex(.readOnly),
			for: .codex,
			defaults: defaults
		)

		XCTAssertEqual(
			service.permissionProfileForMCPActivation(isSubagent: true, provider: .claude),
			.providerOverride(.claude(.autoApproveEdits))
		)
		XCTAssertEqual(
			service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex),
			.providerOverride(.codex(.readOnly))
		)
		XCTAssertEqual(
			service.permissionProfileForMCPActivation(isSubagent: true, provider: .gemini),
			.providerOverride(.gemini(.default))
		)
		// The legacy nil-provider variant falls back to Safe Managed when the global is custom.
		XCTAssertEqual(
			service.permissionProfileForMCPActivation(isSubagent: true),
			.mcpSafeDefaults
		)
		// Top-level MCP activations use the same sub-agent policy as parented sub-agents.
		XCTAssertEqual(
			service.permissionProfileForMCPActivation(isSubagent: false, provider: .claude),
			.providerOverride(.claude(.autoApproveEdits))
		)
	}

	func testProviderOverrideRuntimePermissionUsesConcreteProviderLevel() {
		let defaults = makeDefaults()
		let store = makeStore(defaults: defaults)

		CodexAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		GeminiAgentToolPreferences.setPermissionLevel(.default, defaults: defaults)
		OpenCodeAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults)
		CursorAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults)

		let codex = store.runtimePermission(for: .codexExec, profile: .providerOverride(.codex(.autoReview)))
		XCTAssertEqual(codex.codexSandboxMode, .workspaceWrite)
		XCTAssertEqual(codex.codexApprovalPolicy, .onRequest)
		XCTAssertEqual(codex.codexApprovalReviewer, .autoReview)

		let claude = store.runtimePermission(for: .claudeCode, profile: .providerOverride(.claude(.autoApproveEdits)))
		XCTAssertEqual(claude.claudePermissionMode, ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode)

		let gemini = store.runtimePermission(for: .gemini, profile: .providerOverride(.gemini(.fullAccess)))
		XCTAssertEqual(gemini.acpSessionModeID, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
		XCTAssertTrue(gemini.autoApproveAllACPToolPermissions)
		XCTAssertTrue(gemini.acceptsPendingACPApprovalWhenActivated)

		let openCode = store.runtimePermission(for: .openCode, profile: .providerOverride(.openCode(.fullAccess)))
		XCTAssertEqual(openCode.acpSessionModeID, OpenCodeAgentConfig.managedFullAccessSessionModeID)
		XCTAssertTrue(openCode.acceptsPendingACPApprovalWhenActivated)

		let cursor = store.runtimePermission(for: .cursor, profile: .providerOverride(.cursor(.fullAccess)))
		XCTAssertTrue(cursor.autoApproveAllACPToolPermissions)

		let mismatched = store.runtimePermission(for: .cursor, profile: .providerOverride(.claude(.fullAccess)))
		XCTAssertFalse(mismatched.autoApproveAllACPToolPermissions)
	}

	func testServiceMCPProfileAndManagedReasonLogic() {
		let defaults = makeDefaults()
		let service = AgentModeProviderBindingService(preferences: makeStore(defaults: defaults))

		XCTAssertEqual(service.permissionProfileForMCPActivation(isSubagent: false), .mcpSafeDefaults)
		XCTAssertEqual(service.permissionProfileForMCPActivation(isSubagent: true), .mcpSafeDefaults)
		XCTAssertEqual(
			service.externallyManagedPermissionReason(isSubagent: false, permissionProfile: .mcpSafeDefaults),
			"MCP-started agents use the sub-agent Safe Managed permission defaults."
		)
		XCTAssertEqual(
			service.externallyManagedPermissionReason(isSubagent: true, permissionProfile: .mcpSafeDefaults),
			"MCP-started agents use the sub-agent Safe Managed permission defaults."
		)

		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false, defaults: defaults)

		XCTAssertEqual(service.permissionProfileForMCPActivation(isSubagent: false), .userConfigured)
		XCTAssertEqual(service.permissionProfileForMCPActivation(isSubagent: true), .userConfigured)
		XCTAssertEqual(
			service.externallyManagedPermissionReason(isSubagent: true, permissionProfile: .userConfigured),
			"MCP-started agents inherit your provider-configured permissions. Change the global sub-agent policy before starting an agent."
		)
		XCTAssertEqual(
			service.externallyManagedPermissionReason(isSubagent: true, permissionProfile: .providerOverride(.claude(.autoApproveEdits))),
			"MCP-started agents use the Custom per-provider mode selected in Agent Permissions."
		)
		XCTAssertNil(service.externallyManagedPermissionReason(isSubagent: false, isMCPControlled: false, permissionProfile: .userConfigured))
	}
}
