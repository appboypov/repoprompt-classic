import XCTest
@testable import RepoPrompt

@MainActor
final class MCPAgentRoleDefaultsGlobalTests: XCTestCase {
	private final class FakeRoleDefaultsStore: MCPAgentRoleDefaultsStoring {
		var overrides: [String: String]?
		var committedUpdates: [[String: String]?] = []

		func globalMCPAgentRoleOverrides() -> [String: String]? {
			overrides
		}

		func updateGlobalMCPAgentRoleOverrides(_ overrides: [String: String]?, commit: Bool) {
			self.overrides = overrides
			if commit {
				committedUpdates.append(overrides)
			}
		}
	}

	private let availability = AgentModelCatalog.AvailabilityContext(
		claudeCodeAvailable: true,
		codexAvailable: true,
		geminiAvailable: true,
		zaiConfigured: false
	)

	func testSetSelectionStoresGlobalPairOverrideAndEffectiveSelectionUsesIt() {
		let store = FakeRoleDefaultsStore()
		let override = AgentModelCatalog.NormalizedAgentSelection(
			agent: .claudeCode,
			modelRaw: AgentModel.claudeOpus.rawValue
		)

		MCPAgentRoleDefaultsService.setSelection(
			override,
			for: .pair,
			availability: availability,
			settingsStore: store
		)

		let expectedID = AgentModelSelectionID(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeOpus.rawValue
		).rawValue
		XCTAssertEqual(store.overrides?[AgentModelCatalog.TaskLabelKind.pair.rawValue], expectedID)

		let resolution = MCPAgentRoleDefaultsService.effectiveSelection(
			for: .pair,
			availability: availability,
			settingsStore: store
		)
		XCTAssertEqual(resolution?.effective, override)
		XCTAssertTrue(resolution?.hasCustomOverride == true)
		XCTAssertFalse(resolution?.overrideUnavailable == true)
	}

	func testSetSelectionMatchingRecommendationClearsGlobalOverride() {
		let store = FakeRoleDefaultsStore()
		store.overrides = [
			AgentModelCatalog.TaskLabelKind.pair.rawValue: AgentModelSelectionID(
				agentRaw: DiscoverAgentKind.claudeCode.rawValue,
				modelRaw: AgentModel.claudeOpus.rawValue
			).rawValue
		]
		let recommended = AgentModelCatalog.resolveTaskLabelKind(.pair, availability: availability)!

		MCPAgentRoleDefaultsService.setSelection(
			recommended,
			for: .pair,
			availability: availability,
			settingsStore: store
		)

		XCTAssertNil(store.overrides)
		XCTAssertEqual(store.committedUpdates.count, 1)
		if let lastUpdate = store.committedUpdates.last {
			XCTAssertNil(lastUpdate)
		} else {
			XCTFail("Expected a committed clear update")
		}
	}

	func testResolverUsesGlobalPairOverrideForDefaultTaskLabel() throws {
		let override = AgentModelCatalog.NormalizedAgentSelection(
			agent: .claudeCode,
			modelRaw: AgentModel.claudeOpus.rawValue
		)

		let selection = try AgentMCPSelectionResolver.resolve(
			modelID: nil,
			defaultTaskLabel: .pair,
			availability: availability,
			roleSelectionProvider: { role, _ in role == .pair ? override : nil }
		)

		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.claudeCode.rawValue)
		XCTAssertEqual(selection.modelRaw, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(selection.taskLabelKind, .pair)
	}

	func testResolverUsesGlobalPairOverrideForExplicitTaskLabel() throws {
		let override = AgentModelCatalog.NormalizedAgentSelection(
			agent: .claudeCode,
			modelRaw: AgentModel.claudeOpus.rawValue
		)

		let selection = try AgentMCPSelectionResolver.resolve(
			modelID: "pair",
			availability: availability,
			roleSelectionProvider: { role, _ in role == .pair ? override : nil }
		)

		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.claudeCode.rawValue)
		XCTAssertEqual(selection.modelRaw, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(selection.taskLabelKind, .pair)
	}

	func testResolverLeavesExplicitCompoundModelIDUnchanged() throws {
		let override = AgentModelCatalog.NormalizedAgentSelection(
			agent: .claudeCode,
			modelRaw: AgentModel.claudeOpus.rawValue
		)
		let explicitID = AgentModelSelectionID(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: AgentModel.gpt54High.rawValue
		).rawValue

		let selection = try AgentMCPSelectionResolver.resolve(
			modelID: explicitID,
			defaultTaskLabel: .pair,
			availability: availability,
			roleSelectionProvider: { _, _ in override }
		)

		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(selection.modelRaw, AgentModel.gpt54High.rawValue)
		XCTAssertNil(selection.taskLabelKind)
	}

	func testMigrationPreservesExistingGlobalOverrides() {
		var legacy = ChatGlobalSettings(workspaceID: UUID())
		legacy.mcpAgentRoleOverrides = [
			AgentModelCatalog.TaskLabelKind.pair.rawValue: AgentModelSelectionID(
				agentRaw: DiscoverAgentKind.claudeCode.rawValue,
				modelRaw: AgentModel.claudeOpus.rawValue
			).rawValue
		]
		let existingGlobal = [
			AgentModelCatalog.TaskLabelKind.pair.rawValue: AgentModelSelectionID(
				agentRaw: DiscoverAgentKind.gemini.rawValue,
				modelRaw: AgentModel.geminiPro3p1Preview.rawValue
			).rawValue
		]

		let migrated = GlobalSettingsStore.migratedGlobalMCPAgentRoleOverrides(
			existingGlobal: existingGlobal,
			migrationVersion: nil,
			legacyChatSettings: [legacy.workspaceID: legacy]
		)

		XCTAssertEqual(migrated.overrides, existingGlobal)
		XCTAssertEqual(migrated.migrationVersion, 1)
	}

	func testMigrationChoosesMostCommonLegacyOverridePerRole() {
		let claudeID = AgentModelSelectionID(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeOpus.rawValue
		).rawValue
		let geminiID = AgentModelSelectionID(
			agentRaw: DiscoverAgentKind.gemini.rawValue,
			modelRaw: AgentModel.geminiPro3p1Preview.rawValue
		).rawValue
		var first = ChatGlobalSettings(workspaceID: UUID())
		first.mcpAgentRoleOverrides = [AgentModelCatalog.TaskLabelKind.pair.rawValue: claudeID]
		var second = ChatGlobalSettings(workspaceID: UUID())
		second.mcpAgentRoleOverrides = [AgentModelCatalog.TaskLabelKind.pair.rawValue: claudeID]
		var third = ChatGlobalSettings(workspaceID: UUID())
		third.mcpAgentRoleOverrides = [AgentModelCatalog.TaskLabelKind.pair.rawValue: geminiID]

		let migrated = GlobalSettingsStore.migratedGlobalMCPAgentRoleOverrides(
			existingGlobal: nil,
			migrationVersion: nil,
			legacyChatSettings: [
				first.workspaceID: first,
				second.workspaceID: second,
				third.workspaceID: third,
			]
		)

		XCTAssertEqual(migrated.overrides?[AgentModelCatalog.TaskLabelKind.pair.rawValue], claudeID)
		XCTAssertEqual(migrated.migrationVersion, 1)
	}
}
