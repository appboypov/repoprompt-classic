import XCTest
@testable import RepoPrompt

final class BindContextWorkingDirsResolutionTests: XCTestCase {
	func testExactWorkspaceMatchSucceedsForSingleRoot() {
		let workspace = WorkspaceModel(
			name: "FeedingLittlesApp",
			repoPaths: ["/Users/gao/Developer/FeedingLittlesApp"]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/Users/gao/Developer/FeedingLittlesApp"],
			workspaces: [workspace]
		)

		XCTAssertEqual(matches.map(\.id), [workspace.id])
	}

	func testDescendantPathDoesNotMatchWorkspace() {
		let workspace = WorkspaceModel(
			name: "FeedingLittlesApp",
			repoPaths: ["/Users/gao/Developer/FeedingLittlesApp"]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/Users/gao/Developer/FeedingLittlesApp/Sources"],
			workspaces: [workspace]
		)

		XCTAssertTrue(matches.isEmpty)
	}

	func testSubsetDoesNotMatchMultiRootWorkspace() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [workspace]
		)

		XCTAssertTrue(matches.isEmpty)
	}

	func testOrderInsensitiveMultiRootMatchSucceeds() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPromptWeb",
				"/Users/example/Documents/XCode/RepoPrompt"
			]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			],
			workspaces: [workspace]
		)

		XCTAssertEqual(matches.map(\.id), [workspace.id])
	}

	func testDuplicateExactMatchesAreReturnedForLowLevelMatching() {
		let first = WorkspaceModel(
			name: "FeedingLittlesApp",
			repoPaths: ["/Users/gao/Developer/FeedingLittlesApp"]
		)
		let second = WorkspaceModel(
			name: "FeedingLittlesApp Copy",
			repoPaths: ["/Users/gao/Developer/FeedingLittlesApp"]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/Users/gao/Developer/FeedingLittlesApp"],
			workspaces: [first, second]
		)

		XCTAssertEqual(Set(matches.map(\.id)), Set([first.id, second.id]))
	}

	func testWorkspaceRootSetKeyNormalizesOrderDuplicatesAndTilde() {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		let key = WorkspaceRootSetKey(paths: [
			" ~/Project/../Project ",
			"\(home)/Project",
			"/tmp/B",
			"/tmp/a"
		])

		XCTAssertEqual(key.normalizedPaths, ["/tmp/a", "/tmp/B", "\(home)/Project"])
	}

	func testWorkspaceRootSetKeyTreatsCaseOnlyVariantsAsEquivalent() {
		let first = WorkspaceRootSetKey(paths: ["/tmp/Repo", "/tmp/repo"])
		let second = WorkspaceRootSetKey(paths: ["/tmp/repo", "/tmp/Repo"])
		let third = WorkspaceRootSetKey(paths: ["/tmp/repo"])

		XCTAssertEqual(first, second)
		XCTAssertEqual(first, third)
		XCTAssertEqual(Set([first, second, third]).count, 1)
		XCTAssertEqual(first.normalizedPaths, second.normalizedPaths)
	}

	func testDuplicateExactWorkspaceRecordsCollapseForRoutingAndPreferFocusedEquivalentWindow() {
		let staleDiskRecord = WorkspaceModel(
			name: "RepoPrompt Copy",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)
		let activeDuplicate = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)

		let collapsed = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
			workingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			diskWorkspaces: [staleDiskRecord, activeDuplicate],
			activeWindows: [(windowID: 7, workspace: activeDuplicate, isFocused: true)]
		)

		XCTAssertEqual(collapsed.count, 1)
		XCTAssertEqual(collapsed.first?.workspace.id, activeDuplicate.id)
		XCTAssertEqual(collapsed.first?.showingWindowIDs, [7])
		XCTAssertEqual(Set(collapsed.first?.equivalentWorkspaceIDs ?? []), Set([staleDiskRecord.id, activeDuplicate.id]))
		XCTAssertEqual(collapsed.first?.activeWorkspaceIDsByWindowID[7], activeDuplicate.id)

		let selected = WindowRoutingService.test_selectedWorkingDirsWorkspaceMatch(
			windowID: nil,
			exactMatches: collapsed.map { (workspace: $0.workspace, showingWindowIDs: $0.showingWindowIDs) },
			supersetMatches: []
		)
		XCTAssertEqual(selected?.workspace.id, activeDuplicate.id)
		XCTAssertEqual(selected?.matchedBy, "working_dirs")
	}

	func testExactWorkspaceMatchTreatsCaseOnlyPathVariantsAsEquivalent() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/tmp/RepoPrompt"]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/tmp/repoprompt"],
			workspaces: [workspace]
		)

		XCTAssertEqual(matches.map(\.id), [workspace.id])
	}

	func testSystemWorkspaceDoesNotMatchWorkingDirs() {
		var systemWorkspace = WorkspaceModel(
			name: "Default",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)
		systemWorkspace.isSystemWorkspace = true
		let realWorkspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [systemWorkspace, realWorkspace]
		)

		XCTAssertEqual(matches.map(\.id), [realWorkspace.id])
	}

	func testHiddenExactWorkspaceExcludedFromWorkingDirsRoutingCandidates() {
		let hidden = WorkspaceModel(
			name: "Hidden RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"],
			isHiddenInMenus: true
		)

		let collapsed = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
			workingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			diskWorkspaces: [hidden],
			activeWindows: []
		)

		XCTAssertTrue(collapsed.isEmpty)
	}

	func testHiddenSupersetWorkspaceExcludedFromWorkingDirsRoutingCandidates() {
		let hidden = WorkspaceModel(
			name: "Hidden RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			],
			isHiddenInMenus: true
		)

		let collapsed = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
			workingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			diskWorkspaces: [hidden],
			activeWindows: [],
			kind: "superset"
		)

		XCTAssertTrue(collapsed.isEmpty)
	}

	func testHiddenActiveWindowWorkspaceExcludedFromWorkingDirsRoutingCandidates() {
		let hidden = WorkspaceModel(
			name: "Hidden RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"],
			isHiddenInMenus: true
		)

		let collapsed = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
			workingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			diskWorkspaces: [],
			activeWindows: [(windowID: 5, workspace: hidden, isFocused: true)]
		)

		XCTAssertTrue(collapsed.isEmpty)
	}

	func testVisibleDuplicateStillMatchesWhenHiddenDuplicateExists() {
		let visible = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)
		let hidden = WorkspaceModel(
			name: "Hidden RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"],
			isHiddenInMenus: true
		)

		let collapsed = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
			workingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			diskWorkspaces: [hidden, visible],
			activeWindows: []
		)

		XCTAssertEqual(collapsed.map { $0.workspace.id }, [visible.id])
	}

	func testHiddenWorkspaceCanStillBeMatchedWhenExplicitlyIncludedByHelper() {
		let hidden = WorkspaceModel(
			name: "Hidden RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"],
			isHiddenInMenus: true
		)

		let matches = WorkspaceManagerViewModel.test_exactWorkspaceMatches(
			forWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [hidden],
			includeHidden: true
		)

		XCTAssertEqual(matches.map(\.id), [hidden.id])
	}

	func testHiddenActiveWorkspaceExcludedFromDefaultBindingCandidates() {
		let tab = ComposeTabState(name: "Main")
		let hidden = WorkspaceModel(
			name: "Hidden RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"],
			isHiddenInMenus: true,
			composeTabs: [tab],
			activeComposeTabID: tab.id
		)

		let defaultCandidates = WorkspaceManagerViewModel.test_bindingCandidates(
			matchingWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [hidden],
			activeWorkspaceID: hidden.id
		)
		XCTAssertTrue(defaultCandidates.isEmpty)

		let explicitCandidates = WorkspaceManagerViewModel.test_bindingCandidates(
			matchingWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [hidden],
			activeWorkspaceID: hidden.id,
			includeHidden: true
		)
		XCTAssertEqual(explicitCandidates.map(\.workspaceID), [hidden.id])
	}

	func testWindowIDDisambiguatesDuplicateExactMatchesUsingVisibleWorkspace() {
		let first = WorkspaceModel(
			name: "Default",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)
		let second = WorkspaceModel(
			name: "RepoPrompt (1)",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)

		let disambiguated = WindowRoutingService.test_exactWorkspaceMatchForWindowID(
			1,
			matches: [
				(workspace: first, showingWindowIDs: []),
				(workspace: second, showingWindowIDs: [1])
			]
		)

		XCTAssertEqual(disambiguated?.id, second.id)
	}

	func testWindowIDDoesNotDisambiguateWhenRequestedWindowShowsNoExactMatch() {
		let first = WorkspaceModel(
			name: "Default",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)
		let second = WorkspaceModel(
			name: "RepoPrompt (1)",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)

		let disambiguated = WindowRoutingService.test_exactWorkspaceMatchForWindowID(
			3,
			matches: [
				(workspace: first, showingWindowIDs: [1]),
				(workspace: second, showingWindowIDs: [2])
			]
		)

		XCTAssertNil(disambiguated)
	}

	func testDisambiguatedMatchedByIncludesCandidateCount() {
		XCTAssertEqual(
			WindowRoutingService.test_workingDirsMatchedBy(candidateCount: 2, disambiguatedByWindowID: true),
			"working_dirs (disambiguated by window_id from 2 candidates)"
		)
	}

	func testSupersetWorkspaceMatchSucceedsForRequestedRootSubset() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)

		let matches = WorkspaceManagerViewModel.test_supersetWorkspaceMatches(
			forWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [workspace]
		)

		XCTAssertEqual(matches.map(\.id), [workspace.id])
	}

	func testSupersetWorkspaceMatchDoesNotReturnExactMatch() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)

		let matches = WorkspaceManagerViewModel.test_supersetWorkspaceMatches(
			forWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			workspaces: [workspace]
		)

		XCTAssertTrue(matches.isEmpty)
	}

	func testSupersetWorkspaceMatchRequiresRequestedRootMembership() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)

		let matches = WorkspaceManagerViewModel.test_supersetWorkspaceMatches(
			forWorkingDirs: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/MissingRoot"
			],
			workspaces: [workspace]
		)

		XCTAssertTrue(matches.isEmpty)
	}

	func testSupersetWorkspaceMatchDoesNotMatchDescendantPath() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)

		let matches = WorkspaceManagerViewModel.test_supersetWorkspaceMatches(
			forWorkingDirs: ["/Users/example/Documents/XCode/RepoPrompt/RepoPrompt"],
			workspaces: [workspace]
		)

		XCTAssertTrue(matches.isEmpty)
	}

	func testExactCandidateIsPreferredOverSupersetCandidate() {
		let exact = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"]
		)
		let superset = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)

		let selected = WindowRoutingService.test_selectedWorkingDirsWorkspaceMatch(
			windowID: nil,
			exactMatches: [(workspace: exact, showingWindowIDs: [])],
			supersetMatches: [(workspace: superset, showingWindowIDs: [1])]
		)

		XCTAssertEqual(selected?.workspace.id, exact.id)
		XCTAssertEqual(selected?.kind, "exact")
		XCTAssertEqual(selected?.matchedBy, "working_dirs")
	}

	func testWindowIDDisambiguatesDuplicateSupersetMatchesUsingVisibleWorkspace() {
		let first = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)
		let second = WorkspaceModel(
			name: "RepoPrompt + BombSquad",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/Git/BombSquad"
			]
		)

		let selected = WindowRoutingService.test_selectedWorkingDirsWorkspaceMatch(
			windowID: 2,
			exactMatches: [],
			supersetMatches: [
				(workspace: first, showingWindowIDs: [1]),
				(workspace: second, showingWindowIDs: [2])
			]
		)

		XCTAssertEqual(selected?.workspace.id, second.id)
		XCTAssertEqual(selected?.kind, "superset")
		XCTAssertEqual(
			selected?.matchedBy,
			"working_dirs (matched by workspace repo_paths superset; disambiguated by window_id from 2 candidates)"
		)
	}

	func testDuplicateSupersetRecordsCollapseButDistinctSupersetGroupsRemainAmbiguous() {
		let web = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)
		let webDuplicate = WorkspaceModel(
			name: "RepoPrompt + Web Copy",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPromptWeb",
				"/Users/example/Documents/XCode/RepoPrompt"
			]
		)
		let bombSquad = WorkspaceModel(
			name: "RepoPrompt + BombSquad",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/Git/BombSquad"
			]
		)

		let collapsed = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
			workingDirs: ["/Users/example/Documents/XCode/RepoPrompt"],
			diskWorkspaces: [web, webDuplicate, bombSquad],
			activeWindows: [(windowID: 3, workspace: bombSquad, isFocused: false)],
			kind: "superset"
		)

		XCTAssertEqual(collapsed.count, 2)
		let selectedWithoutWindow = WindowRoutingService.test_selectedWorkingDirsWorkspaceMatch(
			windowID: nil,
			exactMatches: [],
			supersetMatches: collapsed.map { (workspace: $0.workspace, showingWindowIDs: $0.showingWindowIDs) }
		)
		XCTAssertNil(selectedWithoutWindow)

		let selectedWithWindow = WindowRoutingService.test_selectedWorkingDirsWorkspaceMatch(
			windowID: 3,
			exactMatches: [],
			supersetMatches: collapsed.map { (workspace: $0.workspace, showingWindowIDs: $0.showingWindowIDs) }
		)
		XCTAssertEqual(selectedWithWindow?.workspace.id, bombSquad.id)
		XCTAssertEqual(selectedWithWindow?.kind, "superset")
	}

	func testAmbiguousSupersetMatchesReturnNoSelectedWorkspaceWithoutWindowID() {
		let first = WorkspaceModel(
			name: "RepoPrompt + Web",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/XCode/RepoPromptWeb"
			]
		)
		let second = WorkspaceModel(
			name: "RepoPrompt + BombSquad",
			repoPaths: [
				"/Users/example/Documents/XCode/RepoPrompt",
				"/Users/example/Documents/Git/BombSquad"
			]
		)

		let selected = WindowRoutingService.test_selectedWorkingDirsWorkspaceMatch(
			windowID: nil,
			exactMatches: [],
			supersetMatches: [
				(workspace: first, showingWindowIDs: [1]),
				(workspace: second, showingWindowIDs: [2])
			]
		)

		XCTAssertNil(selected)
	}

	func testSupersetMatchedByIdentifiesFallback() {
		XCTAssertEqual(
			WindowRoutingService.test_supersetWorkingDirsMatchedBy(candidateCount: 1, disambiguatedByWindowID: false),
			"working_dirs (matched by workspace repo_paths superset)"
		)
	}

	func testDisambiguatedSupersetMatchedByIncludesFallbackAndCandidateCount() {
		XCTAssertEqual(
			WindowRoutingService.test_supersetWorkingDirsMatchedBy(candidateCount: 2, disambiguatedByWindowID: true),
			"working_dirs (matched by workspace repo_paths superset; disambiguated by window_id from 2 candidates)"
		)
	}
}
