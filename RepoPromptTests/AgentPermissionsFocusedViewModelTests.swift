import XCTest
@testable import RepoPrompt

/// Tests for the focused Agent Permissions settings view models.
///
/// Covers the direct-provider VM, sub-agent policy VM, shared diagnostics VM, and
/// capability-summary builder that replaced the old mixed Agent Permissions VM.
@MainActor
final class AgentPermissionsFocusedViewModelTests: XCTestCase {
	private final class InMemorySecureStrings: SecureIntegrityStringStoring {
		var values: [String: String] = [:]
		var readErrors: [String: Error] = [:]
		var failSaves = false

		func getPlainValue(for key: String) throws -> String? {
			if let error = readErrors[key] {
				throw error
			}
			return values[key]
		}

		func savePlainValue(_ value: String, for key: String) throws {
			if failSaves {
				throw NSError(domain: "AgentPermissionsFocusedViewModelTests", code: -1)
			}
			values[key] = value
		}

		func deletePlainValue(for key: String) throws {
			values.removeValue(forKey: key)
		}

		func getIntegrityProtectedValue(for key: String) throws -> String? {
			if let error = readErrors[key] {
				throw error
			}
			return values[key]
		}

		func saveIntegrityProtectedValue(_ value: String, for key: String) throws {
			if failSaves {
				throw NSError(domain: "AgentPermissionsFocusedViewModelTests", code: -1)
			}
			values[key] = value
		}

		func deleteIntegrityProtectedValue(for key: String) throws {
			values.removeValue(forKey: key)
		}
	}

	private func makeDefaults() -> UserDefaults {
		let suiteName = "AgentPermissionsFocusedViewModelTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	private func makeService(defaults: UserDefaults) -> AgentModeProviderBindingService {
		AgentModeProviderBindingService(
			preferences: AgentProviderPreferenceSnapshotStore(
				defaults: defaults,
				codexMCPServerEntries: { [] }
			)
		)
	}

	private func makeService(
		defaults: UserDefaults,
		secureStore: AgentPermissionSecureStore
	) -> AgentModeProviderBindingService {
		AgentModeProviderBindingService(
			preferences: AgentProviderPreferenceSnapshotStore(
				defaults: defaults,
				securePermissions: secureStore,
				codexMCPServerEntries: { [] }
			)
		)
	}

	private func makeSecureStore(
		secureStrings: InMemorySecureStrings,
		defaults: UserDefaults,
		notificationCenter: NotificationCenter
	) -> AgentPermissionSecureStore {
		AgentPermissionSecureStore(
			secureStrings: secureStrings,
			legacyDefaults: defaults,
			notificationCenter: notificationCenter
		)
	}

	func testFallbackSettersWritePreferencesWithoutBindingService() {
		let defaults = makeDefaults()
		let viewModel = AgentProviderPermissionsSettingsViewModel(defaults: defaults)

		XCTAssertEqual(viewModel.revision, 0)

		viewModel.setPermissionLevel(.claude(.fullAccess))
		XCTAssertEqual(
			ClaudeAgentToolPreferences.permissionLevel(defaults: defaults),
			.fullAccess
		)
		XCTAssertEqual(viewModel.revision, 1)

		viewModel.setCodexBashToolEnabled(false)
		XCTAssertFalse(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults))
		XCTAssertEqual(viewModel.revision, 2)

		viewModel.setClaudeMCPStrictModeEnabled(false)
		XCTAssertFalse(ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults))
		XCTAssertEqual(viewModel.revision, 3)
	}

	func testBindingServiceIsCalledForPermissionLevelAndBumpsStoreRevision() {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)

		var callbackProviderID: AgentProviderBindingID?
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			onProviderPreferenceChanged: { callbackProviderID = $0 }
		)

		XCTAssertEqual(service.preferences.revision(for: .codex), 0)

		viewModel.setPermissionLevel(.codex(.fullAccess))

		XCTAssertEqual(callbackProviderID, .codex)
		XCTAssertEqual(
			CodexAgentToolPreferences.permissionLevel(defaults: defaults),
			.fullAccess
		)
		XCTAssertEqual(service.preferences.revision(for: .codex), 1)
		XCTAssertEqual(viewModel.revision, 1)
	}

	func testGeminiPermissionSetterRoutesThroughServiceAndFiresCallback() {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)

		var callbackProviderID: AgentProviderBindingID?
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			onProviderPreferenceChanged: { callbackProviderID = $0 }
		)

		viewModel.setPermissionLevel(.gemini(.fullAccess))

		XCTAssertEqual(callbackProviderID, .gemini)
		XCTAssertEqual(
			GeminiAgentToolPreferences.permissionLevel(defaults: defaults),
			.fullAccess
		)
	}

	func testControlsBindingReflectsCurrentPreferenceStateForConnectedProvider() throws {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service
		)

		viewModel.setClaudeBashToolEnabled(false)
		viewModel.setClaudeMCPStrictModeEnabled(false)

		let binding = try XCTUnwrap(
			viewModel.controlsBinding(for: .claude)
		)
		let claudeTools = try XCTUnwrap(binding.claudeTools)
		XCTAssertFalse(claudeTools.bashToolEnabled)
		XCTAssertFalse(claudeTools.mcpStrictModeEnabled)
	}

	func testControlsBindingReturnsNilWithoutBindingService() {
		let defaults = makeDefaults()
		let viewModel = AgentProviderPermissionsSettingsViewModel(defaults: defaults)

		XCTAssertNil(viewModel.controlsBinding(for: .claude))
	}

	func testClaudeEffortChangeRoutesThroughOnClaudeEffortCallbackWhenProvided() {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)

		var providerCallbackCount = 0
		var claudeEffortCallbackCount = 0
		var capturedLevel: ClaudeCodeEffortLevel?
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			onProviderPreferenceChanged: { _ in providerCallbackCount += 1 },
			onClaudeEffortLevelChanged: { level in
				claudeEffortCallbackCount += 1
				capturedLevel = level
			}
		)

		viewModel.setClaudeEffortLevel(.high)

		XCTAssertEqual(claudeEffortCallbackCount, 1)
		XCTAssertEqual(capturedLevel, .high)
		// Generic provider callback should NOT fire for Claude effort when the
		// dedicated effort hook is set, because the production wiring routes through
		// `AgentModeViewModel.setClaudeEffortLevel(_:)` which already calls
		// `providerPreferenceDidChange(.claude, ...)` internally.
		XCTAssertEqual(providerCallbackCount, 0)
		XCTAssertEqual(viewModel.revision, 1)
	}

	func testClaudeEffortChangeWritesDirectlyWhenCallbackAbsent() {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service
		)

		viewModel.setClaudeEffortLevel(.xhigh)

		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(defaults: defaults),
			.xhigh
		)
		XCTAssertEqual(service.preferences.revision(for: .claude), 1)
	}

	// MARK: - Secure 5: storage diagnostics / degraded handling

	func testDegradedStateIsFalseForHealthySecureStore() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		let service = makeService(defaults: defaults, secureStore: secureStore)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			notificationCenter: notificationCenter
		)

		XCTAssertFalse(viewModel.isSecurePermissionStorageDegraded)
		XCTAssertTrue(viewModel.storageDiagnostics.isEmpty)
	}

	func testInitSurfacesIntegrityFailureAsDegraded() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		secureStrings.readErrors[AgentPermissionSecureDomain.claude.storageKey] =
			KeychainService.KeychainError.integrityCheckFailed
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		// Seed the diagnostic by reading the affected domain before the VM is built
		// so the initial diagnostics snapshot reflects the failure.
		_ = secureStore.claudePermissions()
		XCTAssertEqual(secureStore.diagnostic(for: .claude)?.kind, .integrityCheckFailed)

		let service = makeService(defaults: defaults, secureStore: secureStore)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			notificationCenter: notificationCenter
		)

		XCTAssertTrue(viewModel.isSecurePermissionStorageDegraded)
		XCTAssertTrue(
			viewModel.storageDiagnostics.contains { $0.domain == .claude && $0.kind == .integrityCheckFailed }
		)
	}

	func testFailedSecureWriteMarksDegradedAndRevertsEffectiveValue() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		let service = makeService(defaults: defaults, secureStore: secureStore)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			notificationCenter: notificationCenter
		)

		XCTAssertFalse(viewModel.isSecurePermissionStorageDegraded)

		// Force the next secure write to fail so the unsafe selection cannot persist.
		secureStrings.failSaves = true

		viewModel.setPermissionLevel(.cursor(.fullAccess))

		XCTAssertTrue(viewModel.isSecurePermissionStorageDegraded)
		XCTAssertTrue(
			viewModel.storageDiagnostics.contains { $0.domain == .cursor && $0.kind == .keychainWriteFailed }
		)
		// Effective value must revert to the safe previous/default value because the
		// secure write failed.
		XCTAssertEqual(
			CursorAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
			.managedDefault
		)
	}

	func testSecureStoreChangeNotificationRefreshesViewModel() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		let viewModel = AgentSubagentPermissionsSettingsViewModel(
			defaults: defaults,
			securePermissions: secureStore,
			notificationCenter: notificationCenter
		)

		XCTAssertEqual(viewModel.globalPolicy, .safeManaged)
		XCTAssertFalse(viewModel.isSecurePermissionStorageDegraded)

		// Simulate an external mutation (e.g. AgentInputBar popover) writing through the
		// same secure store while the Settings page is open.
		XCTAssertTrue(
			secureStore.updateSubagentPermissions { document in
				document.globalPolicyRaw = AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue
			}
		)

		let expectation = expectation(description: "VM receives secure store change notification")
		DispatchQueue.main.async {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)

		XCTAssertEqual(viewModel.globalPolicy, .inheritProviderSettings)
	}

	func testRefreshStorageDiagnosticsIgnoresInformationalKinds() {
		// The VM only flips degraded=true for safety-affecting diagnostic kinds. Pure
		// informational kinds (`migratedFromLegacy`, `legacyScrubFailed`) must not trip
		// the banner state.
		//
		// `AgentPermissionSecureStore` does not emit those kinds today, so we exercise
		// the filter by ensuring a normal migration path does not mark the VM degraded.
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		_ = secureStore.cursorPermissions() // triggers legacy migration path

		let service = makeService(defaults: defaults, secureStore: secureStore)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			notificationCenter: notificationCenter
		)

		XCTAssertFalse(viewModel.isSecurePermissionStorageDegraded)
	}

	func testCapabilitySummaryReflectsProviderMutations() throws {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service
		)

		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: true,
			codexAvailable: true,
			geminiAvailable: true,
			openCodeAvailable: true,
			cursorAvailable: true,
			zaiConfigured: false
		)

		viewModel.setPermissionLevel(.claude(.fullAccess))

		let summary = try XCTUnwrap(
			viewModel.summaries(availability: availability).first { $0.providerID == .claude }
		)
		XCTAssertTrue(summary.approvalModeDescription.contains("Full Access"))
		XCTAssertFalse(summary.warnings.isEmpty, "Full Access should surface a warning")
	}

	// MARK: - Backend split foundation: focused view models / shared helpers

	func testFocusedProviderViewModelRoutesThroughServiceAndBuildsTopLevelBinding() throws {
		let defaults = makeDefaults()
		let service = makeService(defaults: defaults)
		var callbackProviderID: AgentProviderBindingID?
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			bindingService: service,
			onProviderPreferenceChanged: { callbackProviderID = $0 }
		)

		viewModel.setPermissionLevel(.cursor(.fullAccess))

		XCTAssertEqual(callbackProviderID, .cursor)
		XCTAssertEqual(service.preferences.revision(for: .cursor), 1)
		let binding = try XCTUnwrap(viewModel.controlsBinding(for: .cursor))
		XCTAssertEqual(binding.providerID, .cursor)
		XCTAssertNil(binding.permission.externallyManagedReason)
		XCTAssertTrue(binding.permission.options.allSatisfy(\.isEnabled))
		XCTAssertEqual(binding.permission.options.first { $0.isSelected }?.id, .cursor(.fullAccess))
	}

	func testFocusedProviderViewModelFallbackWritesInjectedSecureStore() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		let viewModel = AgentProviderPermissionsSettingsViewModel(
			defaults: defaults,
			securePermissions: secureStore,
			notificationCenter: notificationCenter
		)

		viewModel.setPermissionLevel(.cursor(.fullAccess))

		XCTAssertEqual(
			CursorAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
			.fullAccess
		)
		XCTAssertEqual(
			CursorAgentToolPreferences.permissionLevel(defaults: defaults),
			.managedDefault,
			"Fallback writes must keep sensitive provider permissions in secure storage and safe-shadow UserDefaults"
		)
	}

	func testFocusedSubagentViewModelOwnsPolicyAndRefreshesFromSecureStoreNotifications() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		let viewModel = AgentSubagentPermissionsSettingsViewModel(
			defaults: defaults,
			securePermissions: secureStore,
			notificationCenter: notificationCenter
		)

		XCTAssertEqual(viewModel.globalPolicy, .safeManaged)

		viewModel.setGlobalPolicy(.custom)
		viewModel.setProviderPermissionLevel(.claude(.autoApproveEdits), for: .claude)

		XCTAssertEqual(viewModel.globalPolicy, .custom)
		XCTAssertEqual(viewModel.providerPermissionLevelsByID[.claude], .claude(.autoApproveEdits))
		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .claude, defaults: defaults, secureStore: secureStore),
			.claude(.autoApproveEdits)
		)

		XCTAssertTrue(
			secureStore.updateSubagentPermissions { document in
				document.globalPolicyRaw = AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue
			}
		)
		let expectation = expectation(description: "Subagent VM receives secure store change notification")
		DispatchQueue.main.async {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)

		XCTAssertEqual(viewModel.globalPolicy, .inheritProviderSettings)
	}

	func testSharedDiagnosticsViewModelSurfacesDegradedStorageState() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		secureStrings.readErrors[AgentPermissionSecureDomain.claude.storageKey] =
			KeychainService.KeychainError.integrityCheckFailed
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		_ = secureStore.claudePermissions()

		let diagnostics = AgentPermissionStorageDiagnosticsViewModel(
			securePermissions: secureStore,
			notificationCenter: notificationCenter
		)

		XCTAssertTrue(diagnostics.isSecurePermissionStorageDegraded)
		XCTAssertTrue(
			diagnostics.storageDiagnostics.contains { $0.domain == .claude && $0.kind == .integrityCheckFailed }
		)
	}

	func testSharedDiagnosticsResetClearsDegradedStorageState() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		secureStrings.readErrors[AgentPermissionSecureDomain.claude.storageKey] =
			KeychainService.KeychainError.integrityCheckFailed
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		_ = secureStore.claudePermissions()
		let diagnostics = AgentPermissionStorageDiagnosticsViewModel(
			securePermissions: secureStore,
			notificationCenter: notificationCenter
		)
		XCTAssertTrue(diagnostics.isSecurePermissionStorageDegraded)

		XCTAssertTrue(diagnostics.resetAgentPermissionsToSafeDefaults())

		XCTAssertFalse(diagnostics.isSecurePermissionStorageDegraded)
		XCTAssertTrue(diagnostics.storageDiagnostics.isEmpty)
		XCTAssertNil(diagnostics.resetFailureMessage)
		XCTAssertEqual(Set(secureStrings.values.keys), Set(AgentPermissionSecureDomain.allCases.map(\.storageKey)))
		XCTAssertEqual(
			ClaudeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
			.requireApproval
		)
		XCTAssertFalse(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: secureStore))
		XCTAssertTrue(ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: secureStore))
		XCTAssertEqual(
			CodexAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
			.defaultPermission
		)
		XCTAssertFalse(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: secureStore))
	}

	func testCapabilitySummaryBuilderUsesInjectedSecureSensitiveValues() {
		let defaults = makeDefaults()
		let notificationCenter = NotificationCenter()
		let secureStrings = InMemorySecureStrings()
		let secureStore = makeSecureStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: secureStore)
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: true,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let summary = AgentPermissionCapabilitySummaryBuilder(
			defaults: defaults,
			securePermissions: secureStore
		).summary(for: .claude, profile: .userConfigured, availability: availability)

		XCTAssertTrue(summary.approvalModeDescription.contains("Full Access"))
		XCTAssertFalse(summary.warnings.isEmpty)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.permissionLevel(defaults: defaults),
			.requireApproval,
			"Summary reads must not depend on permissive plaintext mirrors"
		)
	}
}
