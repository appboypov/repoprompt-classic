import XCTest
@testable import RepoPrompt

final class AgentModePermissionPreferencesTests: XCTestCase {
	private final class InMemorySecureStrings: SecureIntegrityStringStoring {
		var values: [String: String] = [:]
		var readErrors: [String: Error] = [:]

		func getPlainValue(for key: String) throws -> String? {
			if let error = readErrors[key] {
				throw error
			}
			return values[key]
		}

		func savePlainValue(_ value: String, for key: String) throws {
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
			values[key] = value
		}

		func deleteIntegrityProtectedValue(for key: String) throws {
			values.removeValue(forKey: key)
		}
	}

	private enum TestError: Error {
		case readFailed
	}

	private func makeDefaults() -> UserDefaults {
		let suiteName = "AgentModePermissionPreferencesTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	private func makeSecureStore(
		secureStrings: InMemorySecureStrings = InMemorySecureStrings(),
		defaults: UserDefaults? = nil
	) -> AgentPermissionSecureStore {
		AgentPermissionSecureStore(
			secureStrings: secureStrings,
			legacyDefaults: defaults ?? makeDefaults(),
			notificationCenter: NotificationCenter()
		)
	}

	func testDefaultForcesSafeSubagentPermissions() {
		let defaults = makeDefaults()

		XCTAssertTrue(AgentModePermissionPreferences.forceSafeSubagentPermissions(defaults: defaults))
	}

	func testForceSafeSubagentPermissionsRoundTrip() {
		let defaults = makeDefaults()

		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false, defaults: defaults)
		XCTAssertFalse(AgentModePermissionPreferences.forceSafeSubagentPermissions(defaults: defaults))

		AgentModePermissionPreferences.setForceSafeSubagentPermissions(true, defaults: defaults)
		XCTAssertTrue(AgentModePermissionPreferences.forceSafeSubagentPermissions(defaults: defaults))
	}

	// MARK: - Tri-state policy migration & round-trip

	func testSubagentPermissionPolicyDefaultsToSafeManagedWhenAllKeysAbsent() {
		let defaults = makeDefaults()

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.safeManaged
		)
	}

	func testSubagentPermissionPolicyMigratesFromLegacyBooleanTrue() {
		let defaults = makeDefaults()
		defaults.set(true, forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey)

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.safeManaged
		)
	}

	func testSubagentPermissionPolicyMigratesFromLegacyBooleanFalse() {
		let defaults = makeDefaults()
		defaults.set(false, forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey)

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.inheritProviderSettings
		)
	}

	func testSubagentPermissionPolicyTriStateRoundTripWritesLegacyBooleanForRollback() {
		let defaults = makeDefaults()

		AgentModePermissionPreferences.setSubagentPermissionPolicy(.safeManaged, defaults: defaults)
		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.safeManaged
		)
		XCTAssertTrue(
			defaults.bool(forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey),
			"safeManaged must dual-write the legacy boolean as true for rollback compatibility"
		)

		AgentModePermissionPreferences.setSubagentPermissionPolicy(.inheritProviderSettings, defaults: defaults)
		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.inheritProviderSettings
		)
		XCTAssertFalse(
			defaults.bool(forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey),
			"inheritProviderSettings must dual-write the legacy boolean as false"
		)

		AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.custom
		)
		XCTAssertTrue(
			defaults.bool(forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey),
			"custom must dual-write the legacy boolean as true so rollback stays safe-leaning"
		)
	}

	func testSetForceSafeSubagentPermissionsRoutesThroughPolicySetter() {
		let defaults = makeDefaults()

		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false, defaults: defaults)
		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.inheritProviderSettings
		)

		AgentModePermissionPreferences.setForceSafeSubagentPermissions(true, defaults: defaults)
		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.safeManaged
		)
	}

	func testTriStatePolicyOverridesLegacyBooleanWhenBothSet() {
		let defaults = makeDefaults()
		// Legacy boolean says "inherit", but the new key explicitly says safeManaged.
		defaults.set(false, forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey)
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.safeManaged, defaults: defaults)

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults),
			.safeManaged
		)
	}

	func testProviderSubagentPermissionLevelDefaultsAndRoundTrips() {
		let defaults = makeDefaults()

		for providerID in AgentProviderBindingID.allCases {
			XCTAssertEqual(
				AgentModePermissionPreferences.providerSubagentPermissionLevel(for: providerID, defaults: defaults),
				AgentProviderPermissionLevelID.subagentDefault(for: providerID)
			)
		}

		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
			.claude(.autoApproveEdits),
			for: .claude,
			defaults: defaults
		)
		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .claude, defaults: defaults),
			.claude(.autoApproveEdits)
		)
		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .codex, defaults: defaults),
			.codex(.defaultPermission),
			"Per-provider keys must be scoped to each provider independently"
		)
	}

	func testLegacyProviderSubagentPolicyMigratesFailClosedToConcreteDefault() {
		let defaults = makeDefaults()
		defaults.set(
			ProviderSubagentPermissionPolicy.inheritProviderSettings.rawValue,
			forKey: AgentModePermissionPreferences.providerPolicyKey(for: .claude)
		)

		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .claude, defaults: defaults),
			.claude(.requireApproval)
		)
	}

	// MARK: - Secure production-path storage

	func testSecureSubagentPolicyMigratesLegacyBooleanFalseAndSafeShadowsLegacyKeys() {
		let defaults = makeDefaults()
		let secureStrings = InMemorySecureStrings()
		defaults.set(false, forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey)
		let store = makeSecureStore(secureStrings: secureStrings, defaults: defaults)

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults, secureStore: store),
			.inheritProviderSettings
		)
		XCTAssertNotNil(secureStrings.values[AgentPermissionSecureDomain.subagent.storageKey])
		XCTAssertEqual(
			defaults.string(forKey: AgentModePermissionPreferences.subagentPermissionPolicyKey),
			AgentSubagentPermissionPolicy.safeManaged.rawValue,
			"Legacy rollback mirror must not keep the permissive migrated policy"
		)
		XCTAssertTrue(defaults.bool(forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey))

		let reloaded = makeSecureStore(secureStrings: secureStrings, defaults: defaults)
		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults, secureStore: reloaded),
			.inheritProviderSettings,
			"Secure policy should win over the safe-shadowed UserDefaults mirror"
		)
	}

	func testSecureSubagentPolicyWriteSafeShadowsInsteadOfDualWritingPermissiveValue() {
		let defaults = makeDefaults()
		let store = makeSecureStore(defaults: defaults)

		AgentModePermissionPreferences.setSubagentPermissionPolicy(
			.inheritProviderSettings,
			defaults: defaults,
			secureStore: store
		)

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults, secureStore: store),
			.inheritProviderSettings
		)
		XCTAssertEqual(
			defaults.string(forKey: AgentModePermissionPreferences.subagentPermissionPolicyKey),
			AgentSubagentPermissionPolicy.safeManaged.rawValue
		)
		XCTAssertTrue(defaults.bool(forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey))
	}

	func testSecureProviderSubagentPermissionLevelRoundTripRemovesPlaintextProviderOverride() {
		let defaults = makeDefaults()
		let store = makeSecureStore(defaults: defaults)
		defaults.set(
			ProviderSubagentPermissionPolicy.inheritProviderSettings.rawValue,
			forKey: AgentModePermissionPreferences.providerPolicyKey(for: .claude)
		)
		defaults.set(
			ClaudeAgentToolPreferences.PermissionLevel.fullAccess.rawValue,
			forKey: AgentModePermissionPreferences.providerPermissionLevelKey(for: .claude)
		)

		AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults, secureStore: store)
		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
			.claude(.autoApproveEdits),
			for: .claude,
			defaults: defaults,
			secureStore: store
		)

		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .claude, defaults: defaults, secureStore: store),
			.claude(.autoApproveEdits)
		)
		XCTAssertNil(defaults.object(forKey: AgentModePermissionPreferences.providerPolicyKey(for: .claude)))
		XCTAssertNil(defaults.object(forKey: AgentModePermissionPreferences.providerPermissionLevelKey(for: .claude)))
		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .codex, defaults: defaults, secureStore: store),
			.codex(.defaultPermission)
		)
	}

	func testSecureLegacyProviderSubagentPolicySetterMapsToConcreteDefault() {
		let defaults = makeDefaults()
		let store = makeSecureStore(defaults: defaults)

		AgentModePermissionPreferences.setProviderSubagentPolicy(
			.inheritProviderSettings,
			for: .claude,
			defaults: defaults,
			secureStore: store
		)

		XCTAssertEqual(
			AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .claude, defaults: defaults, secureStore: store),
			.claude(.requireApproval)
		)
	}

	func testSecureSubagentReadFailureFailsClosedAndDoesNotUseLegacyPermissiveValue() {
		let defaults = makeDefaults()
		let secureStrings = InMemorySecureStrings()
		secureStrings.readErrors[AgentPermissionSecureDomain.subagent.storageKey] = TestError.readFailed
		defaults.set(false, forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey)
		let store = makeSecureStore(secureStrings: secureStrings, defaults: defaults)

		XCTAssertEqual(
			AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults, secureStore: store),
			.safeManaged
		)
		XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .keychainReadFailed)
		XCTAssertEqual(
			defaults.string(forKey: AgentModePermissionPreferences.subagentPermissionPolicyKey),
			AgentSubagentPermissionPolicy.safeManaged.rawValue
		)
		XCTAssertTrue(defaults.bool(forKey: AgentModePermissionPreferences.forceSafeSubagentPermissionsKey))
	}

	func testOpenCodePermissionPreferenceDefaultsToManagedDefault() {
		let defaults = makeDefaults()

		XCTAssertEqual(OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertEqual(OpenCodeAgentToolPreferences.sessionModeID(defaults: defaults), OpenCodeAgentConfig.managedSessionModeID)
	}

	func testOpenCodePermissionPreferenceRoundTrip() {
		let defaults = makeDefaults()

		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		XCTAssertEqual(OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults), .fullAccess)
		XCTAssertEqual(OpenCodeAgentToolPreferences.sessionModeID(defaults: defaults), OpenCodeAgentConfig.managedFullAccessSessionModeID)

		OpenCodeAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults)
		XCTAssertEqual(OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertEqual(OpenCodeAgentToolPreferences.sessionModeID(defaults: defaults), OpenCodeAgentConfig.managedSessionModeID)
	}

	func testOpenCodePermissionPreferenceIgnoresInvalidSessionMode() {
		let defaults = makeDefaults()

		OpenCodeAgentToolPreferences.setSessionModeID("custom_unknown_mode", defaults: defaults)

		XCTAssertEqual(OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertEqual(OpenCodeAgentToolPreferences.sessionModeID(defaults: defaults), OpenCodeAgentConfig.managedSessionModeID)
	}

	func testOpenCodeOnlyFullAccessAutoApprovesExistingPendingRequests() {
		XCTAssertFalse(OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.acceptsPendingApprovalWhenActivated)
		XCTAssertTrue(OpenCodeAgentToolPreferences.PermissionLevel.fullAccess.acceptsPendingApprovalWhenActivated)
	}

	func testCursorPermissionPreferenceDefaultsToManagedDefault() {
		let defaults = makeDefaults()

		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
	}

	func testCursorPermissionPreferenceRoundTrip() {
		let defaults = makeDefaults()

		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .fullAccess)
		XCTAssertTrue(CursorAgentToolPreferences.PermissionLevel.fullAccess.autoApprovesACPToolPermissions)

		CursorAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertFalse(CursorAgentToolPreferences.PermissionLevel.managedDefault.autoApprovesACPToolPermissions)
	}

	func testCursorPermissionPreferenceIgnoresInvalidValue() {
		let defaults = makeDefaults()
		defaults.set("custom_unknown_mode", forKey: "cursorACPToolPermissionLevel")

		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
	}

	func testSafeProfileDisplayLevelsMatchEffectiveDefaults() {
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.mcpSafeDefaults.codexPermissionLevel(userConfigured: .fullAccess),
			.defaultPermission
		)
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.mcpSafeDefaults.claudePermissionLevel(userConfigured: .fullAccess),
			.requireApproval
		)
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.mcpSafeDefaults.geminiPermissionLevel(userConfigured: .fullAccess),
			.default
		)
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.mcpSafeDefaults.openCodePermissionLevel(userConfigured: .fullAccess),
			.managedDefault
		)
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.mcpSafeDefaults.cursorPermissionLevel(userConfigured: .fullAccess),
			.managedDefault
		)
	}

	func testUserConfiguredProfileUsesOpenCodePermissionPreference() {
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.userConfigured.openCodePermissionLevel(userConfigured: .fullAccess),
			.fullAccess
		)
	}

	func testUserConfiguredProfileUsesCursorPermissionPreference() {
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.userConfigured.cursorPermissionLevel(userConfigured: .fullAccess),
			.fullAccess
		)
	}

	func testOpenCodeACPSessionModeIDUsesEffectiveProfile() {
		let previous = OpenCodeAgentToolPreferences.sessionModeID()
		defer { OpenCodeAgentToolPreferences.setSessionModeID(previous) }

		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess)

		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.userConfigured.acpSessionModeID(for: .openCode),
			OpenCodeAgentConfig.managedFullAccessSessionModeID
		)
		XCTAssertEqual(
			AgentModeViewModel.AgentPermissionProfile.mcpSafeDefaults.acpSessionModeID(for: .openCode),
			OpenCodeAgentConfig.managedSessionModeID
		)
	}
}
