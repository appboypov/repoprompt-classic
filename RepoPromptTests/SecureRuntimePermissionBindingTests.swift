import XCTest
@testable import RepoPrompt

@MainActor
final class SecureRuntimePermissionBindingTests: XCTestCase {
	private enum PreservedSecurePayload {
		case absent
		case value(String)
		case unavailable
	}

	private enum PreservedDefaultsValue {
		case absent
		case value(Any)
	}

	private final class StandardPermissionStorageRestorer {
		private let domains: [AgentPermissionSecureDomain]
		private let defaultKeys: [String]
		private let secureKeys = SecureKeysService()
		private var securePayloadByDomain: [AgentPermissionSecureDomain: PreservedSecurePayload] = [:]
		private var defaultsValueByKey: [String: PreservedDefaultsValue] = [:]

		init(domains: [AgentPermissionSecureDomain], defaultKeys: [String]) {
			self.domains = domains
			self.defaultKeys = defaultKeys
			let defaults = UserDefaults.standard

			for domain in domains {
				let key = domain.storageKey
				do {
					if let payload = try secureKeys.getIntegrityProtectedValue(for: key) {
						securePayloadByDomain[domain] = .value(payload)
					} else {
						securePayloadByDomain[domain] = .absent
					}
					try? secureKeys.deleteIntegrityProtectedValue(for: key)
				} catch {
					securePayloadByDomain[domain] = .unavailable
				}
			}

			for key in defaultKeys {
				if let value = defaults.object(forKey: key) {
					defaultsValueByKey[key] = .value(value)
				} else {
					defaultsValueByKey[key] = .absent
				}
				defaults.removeObject(forKey: key)
			}
			AgentPermissionSecureStore.shared.clearCachedDocuments()
		}

		func restore() {
			let defaults = UserDefaults.standard
			for domain in domains {
				let key = domain.storageKey
				switch securePayloadByDomain[domain] ?? .unavailable {
				case .value(let payload):
					try? secureKeys.saveIntegrityProtectedValue(payload, for: key)
				case .absent:
					try? secureKeys.deleteIntegrityProtectedValue(for: key)
				case .unavailable:
					break
				}
			}
			for key in defaultKeys {
				switch defaultsValueByKey[key] ?? .absent {
				case .value(let value):
					defaults.set(value, forKey: key)
				case .absent:
					defaults.removeObject(forKey: key)
				}
			}
			AgentPermissionSecureStore.shared.clearCachedDocuments()
		}
	}

	private static let codexLegacyKeys = [
		"codexAgentTools.bash.enabled",
		"codexAgentTools.bash.approvalPolicy",
		"codexAgentTools.bash.sandboxMode",
		"codexAgentTools.approvalsReviewer",
		"codexAgentTools.mcpServerToggles"
	]

	private static let claudeLegacyKeys = [
		"claudeCodeAllowNativeBashTool",
		"claudeCodePermissionMode",
		"claudeCodeMCPStrictModeEnabled"
	]

	private static let acpLegacyKeys = [
		"geminiACPSessionMode",
		"openCodeACPSessionMode",
		"cursorACPToolPermissionLevel"
	]

	private func selectedOption(in binding: AgentProviderControlsBinding) throws -> AgentPermissionOptionBinding {
		try XCTUnwrap(binding.permission.options.first { $0.isSelected })
	}

	func testCodexAppServerOptionsAndSnapshotReadSharedSecurePreferences() async throws {
		let restorer = StandardPermissionStorageRestorer(
			domains: [.codex],
			defaultKeys: Self.codexLegacyKeys
		)
		defer { restorer.restore() }

		let externalEntry = MCPIntegrationHelper.CodexServerEntry(
			rawName: "ExternalSrv",
			normalizedName: "externalsrv",
			cliPathComponent: "externalsrv"
		)

		CodexAgentToolPreferences.setPermissionLevel(.fullAccess)
		CodexAgentToolPreferences.setBashToolEnabled(false)
		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: externalEntry.normalizedName,
			isEnabled: true
		)

		// Write contradictory legacy values after the secure write. The production runtime
		// helpers should read the secure document, not these plaintext mirrors.
		let defaults = UserDefaults.standard
		defaults.set(true, forKey: "codexAgentTools.bash.enabled")
		defaults.set(CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue, forKey: "codexAgentTools.bash.approvalPolicy")
		defaults.set(CodexAgentToolPreferences.SandboxMode.workspaceWrite.persistedValue, forKey: "codexAgentTools.bash.sandboxMode")
		defaults.set(CodexAgentToolPreferences.ApprovalReviewer.autoReview.persistedValue, forKey: "codexAgentTools.approvalsReviewer")
		defaults.set([externalEntry.normalizedName: false], forKey: "codexAgentTools.mcpServerToggles")
		AgentPermissionSecureStore.shared.clearCachedDocuments()

		let snapshot = CodexAgentToolPreferences.snapshot(for: [externalEntry])
		XCTAssertFalse(snapshot.bashToolEnabled)
		XCTAssertEqual(snapshot.approvalPolicy, .never)
		XCTAssertEqual(snapshot.sandboxMode, .dangerFullAccess)
		XCTAssertEqual(snapshot.approvalReviewer, .user)
		XCTAssertTrue(snapshot.enabledMCPServerNames.contains(externalEntry.normalizedName))

		let options = CodexNativeSessionController.Options.agentModeDefault(forceExperimentalSteering: false)
		let overrides = await options.configOverridesProvider()
		XCTAssertEqual(overrides["features.shell_tool"] as? Bool, false)
		XCTAssertEqual(overrides["features.unified_exec"] as? Bool, false)
		XCTAssertEqual(overrides["approval_policy"] as? String, CodexAgentToolPreferences.ApprovalPolicy.never.appServerConfigOverrideValue)
		XCTAssertEqual(overrides["sandbox_mode"] as? String, CodexAgentToolPreferences.SandboxMode.dangerFullAccess.appServerConfigOverrideValue)
		XCTAssertEqual(overrides["approvals_reviewer"] as? String, CodexAgentToolPreferences.ApprovalReviewer.user.appServerConfigOverrideValue)
	}

	func testClaudeAgentModeConfigReadsSharedSecurePermissions() {
		let restorer = StandardPermissionStorageRestorer(
			domains: [.claude],
			defaultKeys: Self.claudeLegacyKeys
		)
		defer { restorer.restore() }

		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess)
		ClaudeAgentToolPreferences.setBashToolEnabled(false)
		ClaudeAgentToolPreferences.setMCPStrictModeEnabled(false)

		let defaults = UserDefaults.standard
		defaults.set(ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode, forKey: "claudeCodePermissionMode")
		defaults.set(true, forKey: "claudeCodeAllowNativeBashTool")
		defaults.set(true, forKey: "claudeCodeMCPStrictModeEnabled")
		AgentPermissionSecureStore.shared.clearCachedDocuments()

		let config = ClaudeCodeAgentConfig.agentMode(
			toolSearchEnabled: true,
			effortLevel: .medium
		)
		XCTAssertEqual(config.permissionMode, ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode)
		XCTAssertFalse(config.allowNativeBashTool)
		XCTAssertFalse(config.mcpStrictMode)
	}

	func testACPRuntimeBindingReadsSharedSecureSessionAndAutoApprovePreferences() {
		let restorer = StandardPermissionStorageRestorer(
			domains: [.gemini, .openCode, .cursor],
			defaultKeys: Self.acpLegacyKeys
		)
		defer { restorer.restore() }

		GeminiAgentToolPreferences.setPermissionLevel(.fullAccess)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess)
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess)

		let defaults = UserDefaults.standard
		defaults.set(GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID, forKey: "geminiACPSessionMode")
		defaults.set(OpenCodeAgentConfig.managedSessionModeID, forKey: "openCodeACPSessionMode")
		defaults.set(CursorAgentToolPreferences.PermissionLevel.managedDefault.rawValue, forKey: "cursorACPToolPermissionLevel")
		AgentPermissionSecureStore.shared.clearCachedDocuments()

		let store = AgentProviderPreferenceSnapshotStore()

		let gemini = store.runtimePermission(for: .gemini, profile: .userConfigured)
		XCTAssertEqual(gemini.acpSessionModeID, GeminiAgentToolPreferences.PermissionLevel.fullAccess.sessionModeID)
		XCTAssertTrue(gemini.acceptsPendingACPApprovalWhenActivated)

		let openCode = store.runtimePermission(for: .openCode, profile: .userConfigured)
		XCTAssertEqual(openCode.acpSessionModeID, OpenCodeAgentConfig.managedFullAccessSessionModeID)
		XCTAssertTrue(openCode.acceptsPendingACPApprovalWhenActivated)

		let cursor = store.runtimePermission(for: .cursor, profile: .userConfigured)
		XCTAssertTrue(cursor.autoApproveAllACPToolPermissions)
		XCTAssertTrue(cursor.acceptsPendingACPApprovalWhenActivated)
	}

	func testViewModelProviderSetterRefreshesActiveBindingAfterSecureWrite() throws {
		let restorer = StandardPermissionStorageRestorer(
			domains: [.cursor],
			defaultKeys: ["cursorACPToolPermissionLevel"]
		)
		defer { restorer.restore() }

		CursorAgentToolPreferences.setPermissionLevel(.managedDefault)

		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			NoOpSecureRuntimeCodexController()
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }

		let session = vm.session(for: tabID)
		session.selectedAgent = .cursor
		session.permissionProfile = .userConfigured
		vm.applySessionToBindings(session)

		let initialBinding = try XCTUnwrap(vm.activeProviderControlsBinding)
		let initialRevision = initialBinding.revision
		XCTAssertEqual(try selectedOption(in: initialBinding).id, .cursor(.managedDefault))

		vm.setProviderPermissionLevel(.cursor(.fullAccess))

		let updatedBinding = try XCTUnwrap(vm.activeProviderControlsBinding)
		XCTAssertEqual(try selectedOption(in: updatedBinding).id, .cursor(.fullAccess))
		XCTAssertTrue(updatedBinding.runtimePermission.autoApproveAllACPToolPermissions)
		XCTAssertGreaterThan(updatedBinding.revision, initialRevision)
	}
}

private final class NoOpSecureRuntimeCodexController: CodexSessionControlling {
	var hasActiveThread: Bool { false }
	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { continuation in
			continuation.finish()
		}
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID ?? "noop",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {}
	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
