import XCTest
@testable import RepoPrompt

final class ClaudeAgentToolPreferencesTests: XCTestCase {
	private func makeDefaults() -> (UserDefaults, String) {
		let suiteName = "ClaudeAgentToolPreferencesTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return (defaults, suiteName)
	}

	func testDefaultsEnableBashAndRequireApproval() {
		let suiteName = "ClaudeAgentToolPreferencesTests.defaults.\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			return XCTFail("Expected isolated defaults")
		}
		defer {
			defaults.removePersistentDomain(forName: suiteName)
		}

		XCTAssertTrue(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults))
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .requireApproval)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.permissionMode(defaults: defaults),
			ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
		)
	}

	func testPermissionLevelRoundTripMapsToPermissionModes() {
		let suiteName = "ClaudeAgentToolPreferencesTests.permission.\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			return XCTFail("Expected isolated defaults")
		}
		defer {
			defaults.removePersistentDomain(forName: suiteName)
		}

		ClaudeAgentToolPreferences.setPermissionLevel(.autoApproveEdits, defaults: defaults)
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionMode(defaults: defaults), "acceptEdits")
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .autoApproveEdits)

		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionMode(defaults: defaults), "bypassPermissions")
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .fullAccess)

		ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionMode(defaults: defaults), "auto")
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .auto)
	}

	func testPermissionModeStringMapsToAuto() {
		XCTAssertEqual(ClaudeAgentToolPreferences.PermissionLevel.from(permissionMode: "auto"), .auto)
		XCTAssertEqual(ClaudeAgentToolPreferences.PermissionLevel.from(permissionMode: "AUTO"), .auto)
		XCTAssertEqual(ClaudeAgentToolPreferences.PermissionLevel.from(permissionMode: "  auto  "), .auto)
	}

	func testAutoPermissionModeSupportUsesClaudeFamilyRuntimeWithOpusAliases() {
		XCTAssertTrue(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .claudeCode,
				selectedModelRaw: AgentModel.claudeOpus.rawValue
			)
		)
		XCTAssertTrue(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .claudeCode,
				selectedModelRaw: ClaudeModelSpecifier.encodedRaw(
					baseModelRaw: AgentModel.claudeOpus.rawValue,
					effort: .max
				)
			)
		)
		XCTAssertTrue(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .claudeCode,
				selectedModelRaw: " OPUS "
			)
		)
		XCTAssertTrue(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .claudeCode,
				selectedModelRaw: AgentModel.claudeOpus1m.rawValue
			)
		)
		XCTAssertTrue(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .claudeCode,
				selectedModelRaw: ClaudeModelSpecifier.encodedRaw(
					baseModelRaw: AgentModel.claudeOpus1m.rawValue,
					effort: .max
				)
			)
		)

		let unsupportedModelRaws: [String?] = [
			nil,
			"",
			AgentModel.defaultModel.rawValue,
			AgentModel.claudeSonnet.rawValue,
			AgentModel.claudeHaiku.rawValue,
			AgentModel.claudeOpus47.rawValue,
			"claude-unknown-opus"
		]
		for modelRaw in unsupportedModelRaws {
			XCTAssertFalse(
				ClaudeAgentToolPreferences.supportsAutoPermissionMode(
					agentKind: .claudeCode,
					selectedModelRaw: modelRaw
				),
				"Expected unsupported auto permission model: \(modelRaw ?? "nil")"
			)
		}

		// Compatible backends must NOT gain auto mode — only official Claude Code
		XCTAssertFalse(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .claudeCodeGLM,
				selectedModelRaw: AgentModel.claudeOpus.rawValue
			),
			"GLM backend must not support auto permission mode even with Opus"
		)
		XCTAssertFalse(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .customClaudeCompatible,
				selectedModelRaw: AgentModel.claudeOpus.rawValue
			),
			"Custom Claude-compatible backend must not support auto permission mode even with Opus"
		)
		XCTAssertFalse(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .kimiCode,
				selectedModelRaw: AgentModel.kimiCode.rawValue
			)
		)
		XCTAssertFalse(
			ClaudeAgentToolPreferences.supportsAutoPermissionMode(
				agentKind: .customClaudeCompatible,
				selectedModelRaw: AgentModel.customClaudeCompatible.rawValue
			)
		)
	}

	func testResolvePermissionModeKeepsSupportedAuto() {
		let resolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: "  AUTO  ",
			agentKind: .claudeCode,
			selectedModelRaw: AgentModel.claudeOpus.rawValue,
			unsupportedAutoFallback: .autoApproveEdits
		)

		XCTAssertEqual(resolution.requestedMode, "AUTO")
		XCTAssertEqual(resolution.effectiveMode, ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode)
		XCTAssertFalse(resolution.autoWasReplaced)
		XCTAssertNil(resolution.replacementLevel)
	}

	func testResolvePermissionModeFallsBackForUnsupportedAuto() {
		let interactiveResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode,
			agentKind: .claudeCode,
			selectedModelRaw: AgentModel.claudeSonnet.rawValue,
			unsupportedAutoFallback: .autoApproveEdits
		)
		XCTAssertEqual(
			interactiveResolution.effectiveMode,
			ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
		)
		XCTAssertTrue(interactiveResolution.autoWasReplaced)
		XCTAssertEqual(interactiveResolution.replacementLevel, .autoApproveEdits)

		// GLM with Opus must fall back — auto is official Claude Code only
		let glmOpusResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode,
			agentKind: .claudeCodeGLM,
			selectedModelRaw: AgentModel.claudeOpus.rawValue,
			unsupportedAutoFallback: .autoApproveEdits
		)
		XCTAssertEqual(
			glmOpusResolution.effectiveMode,
			ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
		)
		XCTAssertTrue(glmOpusResolution.autoWasReplaced)
		XCTAssertEqual(glmOpusResolution.replacementLevel, .autoApproveEdits)

		// Custom Claude-compatible with Opus must fall back
		let customOpusResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode,
			agentKind: .customClaudeCompatible,
			selectedModelRaw: AgentModel.claudeOpus.rawValue,
			unsupportedAutoFallback: .autoApproveEdits
		)
		XCTAssertEqual(
			customOpusResolution.effectiveMode,
			ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
		)
		XCTAssertTrue(customOpusResolution.autoWasReplaced)
		XCTAssertEqual(customOpusResolution.replacementLevel, .autoApproveEdits)

		let kimiResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode,
			agentKind: .kimiCode,
			selectedModelRaw: AgentModel.kimiCode.rawValue,
			unsupportedAutoFallback: .autoApproveEdits
		)
		XCTAssertEqual(
			kimiResolution.effectiveMode,
			ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
		)
		XCTAssertTrue(kimiResolution.autoWasReplaced)
		XCTAssertEqual(kimiResolution.replacementLevel, .autoApproveEdits)

		let customDefaultResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode,
			agentKind: .customClaudeCompatible,
			selectedModelRaw: AgentModel.customClaudeCompatible.rawValue,
			unsupportedAutoFallback: .autoApproveEdits
		)
		XCTAssertEqual(
			customDefaultResolution.effectiveMode,
			ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
		)
		XCTAssertTrue(customDefaultResolution.autoWasReplaced)
		XCTAssertEqual(customDefaultResolution.replacementLevel, .autoApproveEdits)

		let subagentResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode,
			agentKind: .claudeCode,
			selectedModelRaw: AgentModel.claudeHaiku.rawValue,
			unsupportedAutoFallback: .fullAccess
		)
		XCTAssertEqual(
			subagentResolution.effectiveMode,
			ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode
		)
		XCTAssertTrue(subagentResolution.autoWasReplaced)
		XCTAssertEqual(subagentResolution.replacementLevel, .fullAccess)
	}

	func testResolvePermissionModePreservesNonAutoModes() {
		let modes = [
			ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode,
			ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode,
			ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode
		]

		let emptyResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
			requestedMode: "  ",
			agentKind: .claudeCode,
			selectedModelRaw: AgentModel.claudeSonnet.rawValue,
			unsupportedAutoFallback: .fullAccess
		)
		XCTAssertEqual(emptyResolution.requestedMode, ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode)
		XCTAssertEqual(emptyResolution.effectiveMode, ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode)
		XCTAssertFalse(emptyResolution.autoWasReplaced)
		XCTAssertNil(emptyResolution.replacementLevel)

		for mode in modes {
			let resolution = ClaudeAgentToolPreferences.resolvePermissionMode(
				requestedMode: "  \(mode)  ",
				agentKind: .claudeCode,
				selectedModelRaw: AgentModel.claudeSonnet.rawValue,
				unsupportedAutoFallback: .fullAccess
			)
			XCTAssertEqual(resolution.requestedMode, mode)
			XCTAssertEqual(resolution.effectiveMode, mode)
			XCTAssertFalse(resolution.autoWasReplaced)
			XCTAssertNil(resolution.replacementLevel)
		}
	}

	func testBashToggleRoundTrip() {
		let suiteName = "ClaudeAgentToolPreferencesTests.bash.\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			return XCTFail("Expected isolated defaults")
		}
		defer {
			defaults.removePersistentDomain(forName: suiteName)
		}

		ClaudeAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
		XCTAssertFalse(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults))

		ClaudeAgentToolPreferences.setBashToolEnabled(true, defaults: defaults)
		XCTAssertTrue(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults))
	}

	func testEffortLevelRoundTripsPerModelAndAgentNamespace() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }

		ClaudeAgentToolPreferences.setEffortLevel(
			.high,
			forModelRaw: AgentModel.claudeSonnet.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)
		ClaudeAgentToolPreferences.setEffortLevel(
			.xhigh,
			forModelRaw: AgentModel.claudeOpus.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)
		ClaudeAgentToolPreferences.setEffortLevel(
			.low,
			forModelRaw: AgentModel.claudeSonnet.rawValue,
			agentKind: .claudeCodeGLM,
			defaults: defaults
		)

		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(forModelRaw: AgentModel.claudeSonnet.rawValue, agentKind: .claudeCode, defaults: defaults),
			.high
		)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(forModelRaw: AgentModel.claudeOpus.rawValue, agentKind: .claudeCode, defaults: defaults),
			.xhigh
		)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(forModelRaw: AgentModel.claudeSonnet.rawValue, agentKind: .claudeCodeGLM, defaults: defaults),
			.low
		)

		let stored = ClaudeAgentToolPreferences.effortLevelsByModelSlug(defaults: defaults)
		XCTAssertEqual(stored["claudeCode|sonnet"], .high)
		XCTAssertEqual(stored["claudeCode|opus"], .xhigh)
		XCTAssertEqual(stored["claudeCodeGLM|sonnet"], .low)
	}

	func testPerModelEffortWriteMirrorsLegacyScalarForRollback() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }

		ClaudeAgentToolPreferences.setEffortLevel(
			.high,
			forModelRaw: AgentModel.claudeSonnet.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)

		XCTAssertEqual(ClaudeAgentToolPreferences.effortLevel(defaults: defaults), .high)
	}

	func testEffectiveEffortDefaultsToHighWithoutSavedPreference() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }

		XCTAssertEqual(ClaudeAgentToolPreferences.effortLevel(defaults: defaults), .high)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(
				forModelRaw: AgentModel.claudeSonnet.rawValue,
				agentKind: .claudeCode,
				defaults: defaults
			),
			.high
		)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(
				forModelRaw: AgentModel.defaultModel.rawValue,
				agentKind: .claudeCode,
				defaults: defaults
			),
			.high
		)
		XCTAssertNil(
			ClaudeAgentToolPreferences.storedEffortLevel(
				forModelRaw: AgentModel.defaultModel.rawValue,
				agentKind: .claudeCode,
				defaults: defaults,
				includeLegacyFallback: false
			)
		)
	}

	func testUnsupportedStoredEffortFallsBackToSupportedDefault() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		defaults.set(["claudeCode|sonnet": "xhigh"], forKey: "claudeCodeEffortLevelsByModelSlug")
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, defaults: defaults)

		XCTAssertNil(
			ClaudeAgentToolPreferences.storedEffortLevel(
				forModelRaw: AgentModel.claudeSonnet.rawValue,
				agentKind: .claudeCode,
				defaults: defaults
			)
		)
		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(
				forModelRaw: AgentModel.claudeSonnet.rawValue,
				agentKind: .claudeCode,
				defaults: defaults
			),
			.high
		)
	}
}
