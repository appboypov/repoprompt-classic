import Foundation
import XCTest
@testable import RepoPrompt

final class WorkspaceDeduplicationCoreTests: XCTestCase {
	func testDuplicateWorkspaceGroupsCollapseEquivalentRootsAndPreferActiveWorkCanonical() {
		let older = Self.workspace(
			id: Self.uuid(1),
			name: "Older",
			repoPaths: ["/tmp/RepoPromptDedup/Repo"],
			lastUsed: Self.date(10),
			dateModified: Self.date(10)
		)
		let active = Self.workspace(
			id: Self.uuid(2),
			name: "Active",
			repoPaths: ["/tmp/repopromptdedup/repo"],
			lastUsed: Self.date(5),
			dateModified: Self.date(5)
		)
		var system = Self.workspace(id: Self.uuid(3), name: "System", repoPaths: older.repoPaths)
		system.isSystemWorkspace = true
		var ephemeral = Self.workspace(id: Self.uuid(4), name: "Ephemeral", repoPaths: older.repoPaths)
		ephemeral.isEphemeral = true
		let empty = Self.workspace(id: Self.uuid(5), name: "Empty", repoPaths: [])

		let groups = WorkspaceManagerViewModel.test_duplicateWorkspaceGroups(
			workspaces: [older, active, system, ephemeral, empty],
			activeWindows: [
				(windowID: 9, workspaceID: active.id, hasActiveWork: true, isFocused: false),
				(windowID: 2, workspaceID: older.id, hasActiveWork: false, isFocused: true)
			]
		)

		XCTAssertEqual(groups.count, 1)
		let group = try! XCTUnwrap(groups.first)
		XCTAssertEqual(group.canonicalWorkspaceID, active.id)
		XCTAssertEqual(group.canonicalWorkspaceName, "Active")
		XCTAssertEqual(Set(group.duplicateWorkspaceIDs), [older.id])
		XCTAssertEqual(group.windowIDsByWorkspaceID[active.id], [9])
		XCTAssertEqual(group.windowIDsByWorkspaceID[older.id], [2])
		XCTAssertEqual(group.normalizedRepoPaths.map { $0.lowercased() }, ["/tmp/repopromptdedup/repo"])
	}

	func testMergedCanonicalWorkspaceKeepsCanonicalIdentityAndSafelyUnionsState() {
		let canonicalPresetID = Self.uuid(10)
		let duplicatePresetID = Self.uuid(11)
		let duplicateActivePresetID = duplicatePresetID
		let canonicalTabID = Self.uuid(20)
		let duplicateTabID = Self.uuid(21)
		let keptStashedID = Self.uuid(30)
		let removedStashedID = Self.uuid(31)
		let keptStashedTabID = Self.uuid(32)
		let promptA = Self.uuid(40)
		let promptB = Self.uuid(41)
		let copyPresetID = Self.uuid(50)
		let chatPresetID = Self.uuid(51)
		let now = Self.date(99)

		let canonicalTab = ComposeTabState(id: canonicalTabID, name: "Canonical Tab")
		let duplicateTab = ComposeTabState(id: duplicateTabID, name: "Duplicate Tab")
		let duplicateCopyCustomizations = CopyCustomizations(includeFiles: true)

		let canonical = Self.workspace(
			id: Self.uuid(1),
			name: "Canonical",
			repoPaths: ["/tmp/repo"],
			presets: [WorkspacePreset(id: canonicalPresetID, name: "Canonical Preset")],
			activePresetID: nil,
			lastUsed: Self.date(1),
			dateModified: Self.date(1),
			selectedMetaPromptIDs: [promptB],
			isHiddenInMenus: true,
			composeTabs: [canonicalTab],
			activeComposeTabID: nil,
			stashedTabs: []
		)
		let duplicate = Self.workspace(
			id: Self.uuid(2),
			name: "Duplicate",
			repoPaths: ["/tmp/repo"],
			presets: [
				WorkspacePreset(id: canonicalPresetID, name: "Duplicate Copy Of Existing Preset"),
				WorkspacePreset(id: duplicatePresetID, name: "Duplicate Preset")
			],
			activePresetID: duplicateActivePresetID,
			lastUsed: Self.date(7),
			dateModified: Self.date(7),
			selectedMetaPromptIDs: [promptA, promptB],
			isHiddenInMenus: false,
			copyPresetId: copyPresetID,
			copyCustomizations: duplicateCopyCustomizations,
			chatPresetId: chatPresetID,
			composeTabs: [canonicalTab, duplicateTab],
			activeComposeTabID: duplicateTabID,
			stashedTabs: [
				StashedTab(id: removedStashedID, tab: ComposeTabState(id: canonicalTabID, name: "Already Active")),
				StashedTab(id: keptStashedID, tab: ComposeTabState(id: keptStashedTabID, name: "Keep Me"))
			]
		)

		let merged = WorkspaceManagerViewModel.mergedCanonicalWorkspace(
			canonical: canonical,
			duplicates: [duplicate],
			now: now
		)

		XCTAssertEqual(merged.id, canonical.id)
		XCTAssertEqual(merged.name, canonical.name)
		XCTAssertEqual(merged.repoPaths, canonical.repoPaths)
		XCTAssertFalse(merged.isSystemWorkspace)
		XCTAssertFalse(merged.isHiddenInMenus)
		XCTAssertEqual(merged.lastUsed, duplicate.lastUsed)
		XCTAssertEqual(merged.dateModified, now)
		XCTAssertEqual(merged.presets.map(\.id), [canonicalPresetID, duplicatePresetID])
		XCTAssertEqual(merged.activePresetID, duplicateActivePresetID)
		XCTAssertEqual(merged.composeTabs.map(\.id), [canonicalTabID, duplicateTabID])
		XCTAssertEqual(merged.activeComposeTabID, duplicateTabID)
		XCTAssertEqual(merged.stashedTabs.map(\.id), [keptStashedID])
		XCTAssertEqual(merged.selectedMetaPromptIDs, [promptA, promptB].sorted { $0.uuidString < $1.uuidString })
		XCTAssertEqual(merged.copyPresetId, copyPresetID)
		XCTAssertEqual(merged.copyCustomizations, duplicateCopyCustomizations)
		XCTAssertEqual(merged.chatPresetId, chatPresetID)
	}

	func testDuplicateDeletionDecisionSkipsProtectedAndStillActiveDuplicates() {
		let deletable = Self.uuid(1)
		let protected = Self.uuid(2)
		let stillActive = Self.uuid(3)

		let decision = WorkspaceManagerViewModel.test_duplicateDeletionDecision(
			duplicateWorkspaceIDs: [deletable, protected, stillActive],
			protectedWorkspaceIDs: [protected],
			activeWorkspaceIDs: [stillActive]
		)

		XCTAssertEqual(decision.deletableWorkspaceIDs, [deletable])
		XCTAssertEqual(decision.skippedWorkspaceIDs, [protected, stillActive])
	}

	private static func workspace(
		id: UUID,
		name: String,
		repoPaths: [String],
		presets: [WorkspacePreset] = [],
		activePresetID: UUID? = nil,
		lastUsed: Date = Date(timeIntervalSince1970: 0),
		dateModified: Date = Date(timeIntervalSince1970: 0),
		selectedMetaPromptIDs: [UUID] = [],
		isHiddenInMenus: Bool = false,
		copyPresetId: UUID? = nil,
		copyCustomizations: CopyCustomizations? = nil,
		chatPresetId: UUID? = nil,
		composeTabs: [ComposeTabState] = [ComposeTabState()],
		activeComposeTabID: UUID? = nil,
		stashedTabs: [StashedTab] = []
	) -> WorkspaceModel {
		WorkspaceModel(
			id: id,
			dateModified: dateModified,
			name: name,
			repoPaths: repoPaths,
			presets: presets,
			activePresetID: activePresetID,
			lastUsed: lastUsed,
			selectedMetaPromptIDs: selectedMetaPromptIDs,
			isHiddenInMenus: isHiddenInMenus,
			copyPresetId: copyPresetId,
			copyCustomizations: copyCustomizations,
			chatPresetId: chatPresetId,
			composeTabs: composeTabs,
			activeComposeTabID: activeComposeTabID,
			stashedTabs: stashedTabs
		)
	}

	private static func uuid(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
	}

	private static func date(_ value: TimeInterval) -> Date {
		Date(timeIntervalSince1970: value)
	}
}
