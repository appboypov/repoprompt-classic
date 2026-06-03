import XCTest
@testable import RepoPrompt

final class WorkspaceRestoreHotPathTests: XCTestCase {
	override func tearDown() {
		WorkspaceFileDecodeCache.shared.removeAllForTesting()
		super.tearDown()
	}

	func testCodeInitializerDoesNotMarkWorkspaceMigrationDirty() {
		let workspace = WorkspaceModel(
			name: "New",
			repoPaths: [],
			currentPromptText: "Prompt",
			workingFilePaths: ["Sources/App.swift"]
		)

		XCTAssertFalse(workspace.composeTabs.isEmpty)
		XCTAssertFalse(workspace.migrationRequiresSave)
	}

	func testMigrationHelpersReturnDirtyAndBecomeIdempotent() {
		var workspace = WorkspaceModel(name: "Legacy", repoPaths: [])
		workspace.composeTabs = []
		workspace.activeComposeTabID = nil
		workspace.workingFilePaths = ["Sources/App.swift"]
		workspace.workingExpandedFolders = ["Sources"]
		workspace.currentPromptText = "Legacy prompt"
		workspace.migrationRequiresSave = false

		XCTAssertTrue(workspace.migrateWorkingStateToTabsIfNeeded())
		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertEqual(workspace.composeTabs.first?.selection.selectedPaths, ["Sources/App.swift"])
		XCTAssertEqual(workspace.composeTabs.first?.promptText, "Legacy prompt")

		workspace.migrationRequiresSave = false
		XCTAssertFalse(workspace.migrateWorkingStateToTabsIfNeeded())
		XCTAssertFalse(workspace.migrationRequiresSave)

		workspace.discoveryInstructions = "Inspect sources"

		XCTAssertTrue(workspace.migrateDiscoverAndCBStateToTabsIfNeeded(
			legacyContextBuilderState: ContextBuilderState(
				useOverridePrompt: true,
				overridePromptText: "Override"
			)
		))
		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertNil(workspace.discoveryInstructions)
		XCTAssertEqual(
			workspace.composeTabs.first?.discover.instructions,
			"Inspect sources\n\nLegacy Context Builder override:\nOverride"
		)
	}

	func testWorkspaceSaveMergePreservesNewerDiskRepoPathsWhenNoLocalRootEdit() {
		let workspaceID = UUID()
		let baseline = ["/tmp/ProjectA", "/tmp/ProjectB"]
		var staleCurrent = WorkspaceModel(id: workspaceID, name: "Roots", repoPaths: baseline)
		staleCurrent.currentPromptText = "local prompt edit"

		var newerDisk = staleCurrent
		newerDisk.repoPaths = ["/tmp/ProjectB", "/tmp/ProjectC"]

		let result = WorkspaceManagerViewModel.workspaceForSavePreservingDiskRepoPaths(
			current: staleCurrent,
			diskWorkspace: newerDisk,
			lastSyncedRepoPaths: baseline,
			modificationDate: Date(timeIntervalSince1970: 123)
		)

		XCTAssertTrue(result.preservedDiskRepoPaths)
		XCTAssertEqual(result.workspace.repoPaths, newerDisk.repoPaths)
		XCTAssertEqual(result.workspace.currentPromptText, "local prompt edit")
	}

	func testWorkspaceSaveMergeKeepsLocalRepoPathsWhenManagerEditedRoots() {
		let baseline = ["/tmp/ProjectA", "/tmp/ProjectB"]
		let localRootEdit = WorkspaceModel(name: "Roots", repoPaths: ["/tmp/ProjectC", "/tmp/ProjectA"])
		var newerDisk = localRootEdit
		newerDisk.repoPaths = ["/tmp/ProjectB", "/tmp/ProjectA"]

		let result = WorkspaceManagerViewModel.workspaceForSavePreservingDiskRepoPaths(
			current: localRootEdit,
			diskWorkspace: newerDisk,
			lastSyncedRepoPaths: baseline,
			modificationDate: Date(timeIntervalSince1970: 123)
		)

		XCTAssertFalse(result.preservedDiskRepoPaths)
		XCTAssertEqual(result.workspace.repoPaths, localRootEdit.repoPaths)
	}

	func testWorkspaceDecodeCacheInvalidatesWhenFileMetadataChanges() throws {
		let directory = try makeTemporaryDirectory()
		let fileURL = directory.appendingPathComponent("workspace.json")
		try writeModernWorkspace(named: "Cache A", to: fileURL)

		let first = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
		XCTAssertFalse(first.cacheHit)
		XCTAssertEqual(first.workspace.name, "Cache A")

		let second = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
		XCTAssertTrue(second.cacheHit)
		XCTAssertEqual(second.workspace.name, "Cache A")

		try writeModernWorkspace(named: "Cache B With Longer Name", to: fileURL)

		let third = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
		XCTAssertFalse(third.cacheHit)
		XCTAssertEqual(third.workspace.name, "Cache B With Longer Name")
	}

	func testLegacyWorkspaceLoadPersistsMigrationOnce() async throws {
		let directory = try makeTemporaryDirectory()
		let fileURL = directory.appendingPathComponent("workspace.json")
		try legacyWorkspaceJSON(name: "Legacy Save")
			.write(to: fileURL, atomically: true, encoding: .utf8)

		let result = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
		XCTAssertTrue(result.migrationRequiresSave)
		XCTAssertNotNil(result.migrationSaveTask)
		await result.migrationSaveTask?.value

		let savedJSON = try String(contentsOf: fileURL, encoding: .utf8)
		XCTAssertTrue(savedJSON.contains("composeTabs"))
		XCTAssertFalse(savedJSON.contains("discoveryInstructions"))
		XCTAssertFalse(savedJSON.contains("contextBuilderState"))
	}

	func testLegacyRootContextBuilderOverrideMigratesAndSaveOmitsLegacyKeys() async throws {
		let directory = try makeTemporaryDirectory()
		let fileURL = directory.appendingPathComponent("workspace.json")
		try legacyWorkspaceJSON(name: "Legacy Root Override", currentPromptText: "", discoveryInstructions: nil, overrideText: "  Root override  ")
			.write(to: fileURL, atomically: true, encoding: .utf8)

		let result = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(at: fileURL)
		XCTAssertTrue(result.migrationRequiresSave)
		XCTAssertEqual(result.workspace.composeTabs.first?.promptText, "Root override")
		XCTAssertEqual(result.workspace.composeTabs.first?.discover.instructions, "")

		await result.migrationSaveTask?.value
		let savedJSON = try String(contentsOf: fileURL, encoding: .utf8)
		XCTAssertFalse(savedJSON.contains("contextBuilderState"))
		XCTAssertFalse(savedJSON.contains("contextBuilder"))
		XCTAssertFalse(savedJSON.contains("contextOverrides"))
	}

	func testLegacyTabContextOverridesMigratesToPromptTextWhenPromptIsEmpty() throws {
		let workspace = try decodeWorkspace(tabJSON: legacyTabJSON(
			promptText: "",
			discoverInstructions: "",
			legacyContextOverrides: "Tab override",
			legacyContextBuilderOverride: nil
		))

		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertEqual(workspace.composeTabs.first?.promptText, "Tab override")
		XCTAssertEqual(workspace.composeTabs.first?.discover.instructions, "")
	}

	func testLegacyTabContextBuilderMigratesToDiscoverWhenPromptIsOccupied() throws {
		let workspace = try decodeWorkspace(tabJSON: legacyTabJSON(
			promptText: "Existing prompt",
			discoverInstructions: "",
			legacyContextOverrides: nil,
			legacyContextBuilderOverride: "Builder override"
		))

		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertEqual(workspace.composeTabs.first?.promptText, "Existing prompt")
		XCTAssertEqual(workspace.composeTabs.first?.discover.instructions, "Builder override")
	}

	func testLegacyOverrideMigrationAppendsLabeledNoteOnce() throws {
		let workspace = try decodeWorkspace(tabJSON: legacyTabJSON(
			promptText: "Existing prompt",
			discoverInstructions: "Existing discovery",
			legacyContextOverrides: "Append me",
			legacyContextBuilderOverride: nil
		))

		let expected = "Existing discovery\n\nLegacy Context Builder override:\nAppend me"
		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertEqual(workspace.composeTabs.first?.discover.instructions, expected)

		let encoded = try JSONEncoder().encode(workspace)
		let decodedAgain = try JSONDecoder().decode(WorkspaceModel.self, from: encoded)
		XCTAssertFalse(decodedAgain.migrationRequiresSave)
		XCTAssertEqual(decodedAgain.composeTabs.first?.discover.instructions, expected)
	}

	func testRootDiscoveryMigratesBeforeLegacyTabOverride() throws {
		let workspace = try decodeWorkspace(
			tabJSON: legacyTabJSON(
				promptText: "Existing prompt",
				discoverInstructions: "",
				legacyContextOverrides: "Tab override",
				legacyContextBuilderOverride: nil
			),
			rootDiscoveryInstructions: "Root discovery"
		)

		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertNil(workspace.discoveryInstructions)
		XCTAssertEqual(
			workspace.composeTabs.first?.discover.instructions,
			"Root discovery\n\nLegacy Context Builder override:\nTab override"
		)
	}

	func testDuplicateRootAndTabLegacyOverrideMigratesOnlyOnce() throws {
		let workspace = try decodeWorkspace(
			tabJSON: legacyTabJSON(
				promptText: "",
				discoverInstructions: "",
				legacyContextOverrides: "Same override",
				legacyContextBuilderOverride: nil
			),
			rootContextBuilderOverride: "Same override"
		)

		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertEqual(workspace.composeTabs.first?.promptText, "Same override")
		XCTAssertEqual(workspace.composeTabs.first?.discover.instructions, "")
	}

	func testLegacyStashedTabOverrideMarksWorkspaceDirtyAndSaveOmitsLegacyKeys() throws {
		let workspace = try decodeWorkspace(
			tabJSON: legacyTabJSON(
				promptText: "Active prompt",
				discoverInstructions: "",
				legacyContextOverrides: nil,
				legacyContextBuilderOverride: nil
			),
			stashedTabJSON: legacyTabJSON(
				promptText: "Stashed prompt",
				discoverInstructions: "",
				legacyContextOverrides: "Stashed override",
				legacyContextBuilderOverride: nil
			)
		)

		XCTAssertTrue(workspace.migrationRequiresSave)
		XCTAssertEqual(workspace.stashedTabs.first?.tab.discover.instructions, "Stashed override")

		let encoded = try JSONEncoder().encode(workspace)
		let savedJSON = String(data: encoded, encoding: .utf8) ?? ""
		XCTAssertFalse(savedJSON.contains("contextBuilderState"))
		XCTAssertFalse(savedJSON.contains("contextBuilder"))
		XCTAssertFalse(savedJSON.contains("contextOverrides"))
	}


	func testLegacyOverrideMigrationIgnoresDisabledOrWhitespaceOverrideText() throws {
		let disabled = try decodeWorkspace(tabJSON: legacyTabJSON(
			promptText: "Existing prompt",
			discoverInstructions: "Existing discovery",
			legacyContextOverrides: "Ignored",
			legacyContextBuilderOverride: nil,
			useContextOverrides: false
		))
		XCTAssertTrue(disabled.migrationRequiresSave)
		XCTAssertEqual(disabled.composeTabs.first?.promptText, "Existing prompt")
		XCTAssertEqual(disabled.composeTabs.first?.discover.instructions, "Existing discovery")

		let whitespace = try decodeWorkspace(tabJSON: legacyTabJSON(
			promptText: "Existing prompt",
			discoverInstructions: "Existing discovery",
			legacyContextOverrides: "   ",
			legacyContextBuilderOverride: nil
		))
		XCTAssertTrue(whitespace.migrationRequiresSave)
		XCTAssertEqual(whitespace.composeTabs.first?.promptText, "Existing prompt")
		XCTAssertEqual(whitespace.composeTabs.first?.discover.instructions, "Existing discovery")
	}

	func testRestoreSaveStateSkipsOnlySyntheticFallback() {
		var fallback = WorkspaceModel(name: "Default", repoPaths: [])
		fallback.isSystemWorkspace = true
		let realWorkspace = WorkspaceModel(name: "Real", repoPaths: ["/tmp/repo"])

		XCTAssertFalse(WorkspaceManagerViewModel.effectiveRestoreSaveState(
			requestedSaveState: true,
			reason: "restore",
			previousWorkspace: fallback
		))
		XCTAssertTrue(WorkspaceManagerViewModel.effectiveRestoreSaveState(
			requestedSaveState: true,
			reason: "restore",
			previousWorkspace: realWorkspace
		))
		XCTAssertTrue(WorkspaceManagerViewModel.effectiveRestoreSaveState(
			requestedSaveState: true,
			reason: "userOrInternal",
			previousWorkspace: fallback
		))
	}

	func testAgentSidebarRefreshSkipsSystemWorkspaceOnlyWhenInitialRefreshIsDeferred() {
		var fallback = WorkspaceModel(name: "Default", repoPaths: [])
		fallback.isSystemWorkspace = true
		fallback.composeTabs = [ComposeTabState(name: "Legacy Agent Tab")]

		let realWorkspace = WorkspaceModel(name: "Real", repoPaths: ["/tmp/repo"])
		let emptyUserWorkspace = WorkspaceModel(name: "Empty Project", repoPaths: [])

		XCTAssertTrue(AgentModeViewModel.shouldSkipSessionListCacheRefresh(
			for: fallback,
			isInitialSystemWorkspaceRefreshDeferred: true
		))
		XCTAssertFalse(AgentModeViewModel.shouldSkipSessionListCacheRefresh(
			for: fallback,
			isInitialSystemWorkspaceRefreshDeferred: false
		))
		XCTAssertFalse(AgentModeViewModel.shouldSkipSessionListCacheRefresh(
			for: realWorkspace,
			isInitialSystemWorkspaceRefreshDeferred: true
		))
		XCTAssertFalse(AgentModeViewModel.shouldSkipSessionListCacheRefresh(
			for: emptyUserWorkspace,
			isInitialSystemWorkspaceRefreshDeferred: true
		))
	}

	func testInitialAgentSystemRefreshDeferralAttributionRequiresMatchingWaiterAndToken() {
		let waiterID = UUID()
		let deferralID = UUID()

		XCTAssertTrue(WindowStatesManager.initialAgentSystemWorkspaceRefreshDeferralClaimMatches(
			waiterID: waiterID,
			expectedDeferralID: nil,
			claimedWaiterID: nil,
			claimedDeferralID: nil
		))
		XCTAssertTrue(WindowStatesManager.initialAgentSystemWorkspaceRefreshDeferralClaimMatches(
			waiterID: waiterID,
			expectedDeferralID: deferralID,
			claimedWaiterID: waiterID,
			claimedDeferralID: deferralID
		))
		XCTAssertFalse(WindowStatesManager.initialAgentSystemWorkspaceRefreshDeferralClaimMatches(
			waiterID: waiterID,
			expectedDeferralID: deferralID,
			claimedWaiterID: UUID(),
			claimedDeferralID: deferralID
		))
		XCTAssertFalse(WindowStatesManager.initialAgentSystemWorkspaceRefreshDeferralClaimMatches(
			waiterID: waiterID,
			expectedDeferralID: deferralID,
			claimedWaiterID: waiterID,
			claimedDeferralID: UUID()
		))
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-WorkspaceRestoreHotPathTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: directory)
		}
		return directory
	}

	private func writeModernWorkspace(named name: String, to fileURL: URL) throws {
		let workspace = WorkspaceModel(name: name, repoPaths: ["/tmp/repo"])
		let data = try JSONEncoder().encode(workspace)
		try data.write(to: fileURL, options: .atomic)
	}

	private func decodeWorkspace(
		tabJSON: String,
		rootDiscoveryInstructions: String? = nil,
		rootContextBuilderOverride: String? = nil,
		stashedTabJSON: String? = nil
	) throws -> WorkspaceModel {
		let tab = jsonObject(from: tabJSON)
		var workspace: [String: Any] = [
			"id": UUID().uuidString,
			"schemaVersion": 1,
			"name": "Legacy Tab Workspace",
			"repoPaths": [],
			"isSystemWorkspace": false,
			"isHiddenInMenus": false,
			"composeTabs": [tab]
		]
		if let rootDiscoveryInstructions {
			workspace["discoveryInstructions"] = rootDiscoveryInstructions
		}
		if let rootContextBuilderOverride {
			workspace["contextBuilderState"] = [
				"useOverridePrompt": true,
				"overridePromptText": rootContextBuilderOverride
			]
		}
		if let stashedTabJSON {
			workspace["stashedTabs"] = [[
				"id": UUID().uuidString,
				"tab": jsonObject(from: stashedTabJSON),
				"stashedAt": 0
			]]
		}
		let json = jsonString(from: workspace)
		return try JSONDecoder().decode(WorkspaceModel.self, from: Data(json.utf8))
	}

	private func legacyTabJSON(
		promptText: String,
		discoverInstructions: String,
		legacyContextOverrides: String?,
		legacyContextBuilderOverride: String?,
		useContextOverrides: Bool = true,
		useContextBuilder: Bool = true
	) -> String {
		var tab: [String: Any] = [
			"id": UUID().uuidString,
			"name": "Legacy Tab",
			"selection": [
				"selectedPaths": [],
				"autoCodemapPaths": [],
				"slices": [:],
				"codemapAutoEnabled": true
			],
			"expandedFolders": [],
			"promptText": promptText,
			"selectedMetaPromptIDs": [],
			"discover": [
				"instructions": discoverInstructions
			]
		]
		if let legacyContextOverrides {
			tab["contextOverrides"] = [
				"useOverridePrompt": useContextOverrides,
				"overridePromptText": legacyContextOverrides
			]
		}
		if let legacyContextBuilderOverride {
			tab["contextBuilder"] = [
				"useOverridePrompt": useContextBuilder,
				"overridePromptText": legacyContextBuilderOverride
			]
		}
		return jsonString(from: tab)
	}

	private func legacyWorkspaceJSON(
		name: String,
		currentPromptText: String = "Legacy prompt",
		discoveryInstructions: String? = "Inspect legacy sources",
		overrideText: String = "Override"
	) -> String {
		var workspace: [String: Any] = [
			"id": UUID().uuidString,
			"schemaVersion": 1,
			"name": name,
			"repoPaths": [],
			"workingFilePaths": ["Sources/App.swift"],
			"workingExpandedFolders": ["Sources"],
			"currentPromptText": currentPromptText,
			"selectedMetaPromptIDs": [],
			"isSystemWorkspace": false,
			"isHiddenInMenus": false,
			"contextBuilderState": [
				"recommendedHighPaths": ["Sources/App.swift"],
				"recommendedMediumPaths": [],
				"recommendedLowPaths": [],
				"recommendationsTitle": "Legacy",
				"includeFileTree": true,
				"includeCodeMap": true,
				"maxTokensPerQuery": 16,
				"disableSizeLimits": true,
				"enableFinalRefinement": true,
				"includeHighPriority": true,
				"includeMediumPriority": true,
				"includeLowPriority": true,
				"useOverridePrompt": true,
				"overridePromptText": overrideText,
				"useOnlySelectedFiles": false,
				"parallelPartitions": 4
			]
		]
		if let discoveryInstructions {
			workspace["discoveryInstructions"] = discoveryInstructions
		}
		return jsonString(from: workspace)
	}

	private func jsonObject(from json: String) -> Any {
		try! JSONSerialization.jsonObject(with: Data(json.utf8))
	}

	private func jsonString(from object: Any) -> String {
		let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
		return String(data: data, encoding: .utf8)!
	}

}
