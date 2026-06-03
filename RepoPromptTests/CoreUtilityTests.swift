//
//  CoreUtilityTests.swift
//  RepoPromptTests
//
//  Created by Eric Provencher on 2025-06-30.
//

import XCTest
import MCP
import Darwin
@testable import RepoPrompt

final class CoreUtilityTests: XCTestCase {
	
	// MARK: – chunked(into:)
	
	func testChunkedEvenSplit() throws {
		let input = [1, 2, 3, 4]
		let chunks = input.chunked(into: 2)
		XCTAssertEqual(chunks, [[1, 2], [3, 4]],
					   "Evenly divisible array should split into equal-sized chunks.")
	}
	
	func testChunkedWithRemainder() throws {
		let input = [1, 2, 3, 4, 5]
		let chunks = input.chunked(into: 2)
		XCTAssertEqual(chunks, [[1, 2], [3, 4], [5]],
					   "Last chunk should contain the remaining element(s).")
	}
	
	func testChunkedEmptyOrZeroSize() throws {
		XCTAssertTrue([Int]().chunked(into: 3).isEmpty,
					  "Empty array should return no chunks.")
		XCTAssertTrue([1, 2].chunked(into: 0).isEmpty,
					  "Chunk size ≤ 0 should yield no chunks.")
	}
	
	// MARK: – removeDuplicatesInPlace()
	
	func testRemoveDuplicatesInPlace() throws {
		var input = [1, 2, 2, 3, 1, 4]
		input.removeDuplicatesInPlace()
		XCTAssertEqual(input, [1, 2, 3, 4],
					   "Duplicate values should be removed while preserving first occurrence.")
	}
}



// MARK: - Merged from RelativePathTests.swift

extension CoreUtilityTests {
	
	func testInsideRoot() {
		let root = "/Users/me/repo"
		let abs = "/Users/me/repo/Sources/File.swift"
		XCTAssertEqual(RelativePath.from(absolutePath: abs, rootPath: root), "Sources/File.swift")
	}
	
	func testEqualRoot() {
		let root = "/Users/me/repo"
		XCTAssertEqual(RelativePath.from(absolutePath: root, rootPath: root), "")
	}
	
	func testSiblingNotMistakenAsChild() {
		let root = "/Users/me/repo"
		let abs = "/Users/me/repository/File.swift"
		XCTAssertEqual(
			RelativePath.from(absolutePath: abs, rootPath: root),
			(abs as NSString).standardizingPath
		)
	}
	
	func testRootSlash() {
		let root = "/"
		let abs = "/a/b"
		XCTAssertEqual(RelativePath.from(absolutePath: abs, rootPath: root), "a/b")
	}
	
	func testStandardizedRelativeTrimsAndCollapses() {
		XCTAssertEqual(StandardizedPath.relative("/Sources//Feature/../File.swift/"), "Sources/File.swift")
		XCTAssertEqual(StandardizedPath.relative("."), "")
		XCTAssertEqual(StandardizedPath.relative("../Outside.swift"), "../Outside.swift")
	}
	
	func testStandardizedJoinAvoidsRestandardizingRoot() {
		XCTAssertEqual(
			StandardizedPath.join(standardizedRoot: "/Users/me/repo", standardizedRelativePath: "Sources/File.swift"),
			"/Users/me/repo/Sources/File.swift"
		)
		XCTAssertEqual(
			StandardizedPath.join(standardizedRoot: "/", standardizedRelativePath: "tmp/file.txt"),
			"/tmp/file.txt"
		)
	}
	
	func testStandardizedDescendantIsBoundarySafe() {
		XCTAssertTrue(StandardizedPath.isDescendant("/Users/me/repo/Sources", of: "/Users/me/repo"))
		XCTAssertTrue(StandardizedPath.isDescendant("/Users/me/repo", of: "/Users/me/repo"))
		XCTAssertFalse(StandardizedPath.isDescendant("/Users/me/repository", of: "/Users/me/repo"))
	}
	
	func testWorkspaceRootRefCachesStandardizedPath() {
		let root = WorkspaceRootRef(id: UUID(), name: "Repo", fullPath: "/Users/me/repo/./Sources/..")
		XCTAssertEqual(root.standardizedFullPath, "/Users/me/repo")
	}
	
	func testGitServiceMergedProcessEnvironmentPrefersShellValues() {
		let merged = GitService.mergedProcessEnvironment(
			baseEnvironment: [
				"PATH": "/usr/bin:/bin",
				"HOME": "/Users/base",
				"LANG": "en_CA.UTF-8"
			],
			shellEnvironment: [
				"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
				"HOME": "/Users/shell"
			]
		)
		
		XCTAssertEqual(merged["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
		XCTAssertEqual(merged["HOME"], "/Users/shell")
		XCTAssertEqual(merged["LANG"], "en_CA.UTF-8")
	}
	
	func testGitServiceFriendlyErrorDescriptionForMissingGitLFS() {
		let raw = "git diff failed: git-lfs filter-process: git-lfs: command not found\nfatal: the remote end hung up unexpectedly"
		let friendly = GitService.friendlyErrorDescription(for: raw)
		
		XCTAssertTrue(friendly.contains("couldn’t launch git-lfs"))
		XCTAssertTrue(friendly.contains("login shell PATH"))
		XCTAssertTrue(friendly.contains(raw))
	}
}



// MARK: - Merged from SliceRangeMathTests.swift


extension CoreUtilityTests {
	func testNormalizeMergesMatchingDescriptions() {
		let ranges = [
			LineRange(start: 1, end: 3, description: "Alpha"),
			LineRange(start: 4, end: 6, description: "Alpha")
		]

		let normalized = SliceRangeMath.normalize(ranges)

		XCTAssertEqual(normalized, [LineRange(start: 1, end: 6, description: "Alpha")])
	}

	func testNormalizeMergesDifferentDescriptionsWithConcat() {
		let ranges = [
			LineRange(start: 1, end: 2, description: "A"),
			LineRange(start: 3, end: 4, description: "B")
		]

		let normalized = SliceRangeMath.normalize(ranges)

		XCTAssertEqual(normalized, [LineRange(start: 1, end: 4, description: "A; B")])
	}

	func testSubtractPreservesDescriptionForFragments() {
		let base = [LineRange(start: 1, end: 10, description: "Keep")]
		let removing = [LineRange(start: 4, end: 6)]

		let result = SliceRangeMath.subtract(base, removing: removing)

		XCTAssertEqual(result, [
			LineRange(start: 1, end: 3, description: "Keep"),
			LineRange(start: 7, end: 10, description: "Keep")
		])
	}
}



// MARK: - Merged from GitDiffPathResolverTests.swift


extension CoreUtilityTests {
	func testGitDiffCandidatesIncludesSlicedPaths() {
		let selection = StoredSelection(
			selectedPaths: [],
			autoCodemapPaths: [],
			slices: [
				"/tmp/OnlySlice.swift": [LineRange(start: 1, end: 2)]
			],
			codemapAutoEnabled: false
		)

		let candidates = MCPServerViewModel.gitDiffCandidates(from: selection)

		XCTAssertEqual(candidates, ["/tmp/OnlySlice.swift"])
	}

	func testGitDiffCandidatesNormalizesAndDedupesSelectionAndSlicePaths() {
		let selection = StoredSelection(
			selectedPaths: [" /tmp/Project/./File.swift "],
			autoCodemapPaths: [],
			slices: [
				"/tmp/Project/File.swift": [LineRange(start: 1, end: 2)],
				"/tmp/Project//Other.swift": [LineRange(start: 3, end: 4)]
			],
			codemapAutoEnabled: false
		)

		let candidates = MCPServerViewModel.gitDiffCandidates(from: selection)

		XCTAssertEqual(candidates, ["/tmp/Project/File.swift", "/tmp/Project/Other.swift"])
	}

	func testStandardizedStoredSelectionSlicesPrefersCanonicalKeyOverLegacyVariant() {
		let legacy = "/tmp/Project/./File.swift"
		let canonical = "/tmp/Project/File.swift"
		let normalized = StoredSelectionPathNormalization.standardizedSlices([
			legacy: [LineRange(start: 1, end: 2)],
			canonical: [LineRange(start: 5, end: 6)]
		])

		XCTAssertEqual(normalized[canonical], [LineRange(start: 5, end: 6)])
		XCTAssertEqual(normalized.count, 1)
	}

	func testStandardizedStoredSelectionSlicesMergesLegacyVariantsWithoutCanonicalKey() {
		let normalized = StoredSelectionPathNormalization.standardizedSlices([
			"/tmp/Project/./File.swift": [LineRange(start: 1, end: 2, description: "A")],
			" /tmp/Project//File.swift ": [LineRange(start: 3, end: 4, description: "B")]
		])

		XCTAssertEqual(
			normalized,
			[
				"/tmp/Project/File.swift": [
					LineRange(start: 1, end: 4, description: "A; B")
				]
			]
		)
	}

	func testResolveGitDiffPathsUsesResolvedMapFirst() {
		let candidates = ["Source.swift"]
		let resolvedMap = ["Source.swift": "/abs/Source.swift"]

		let resolved = MCPServerViewModel.resolveGitDiffPaths(
			candidates: candidates,
			resolvedMap: resolvedMap,
			normalizeUserInput: { _ in "/abs/Source.swift" },
			fileExists: { _ in true }
		)

		XCTAssertEqual(resolved, ["/abs/Source.swift"])
	}

	func testResolveGitDiffPathsFallsBackToNormalizedAbsolutePaths() {
		let candidates = ["relative/Path.swift"]
		let resolvedMap: [String: String] = [:]

		let resolved = MCPServerViewModel.resolveGitDiffPaths(
			candidates: candidates,
			resolvedMap: resolvedMap,
			normalizeUserInput: { _ in "/abs/Path.swift" },
			fileExists: { path in path == "/abs/Path.swift" }
		)

		XCTAssertEqual(resolved, ["/abs/Path.swift"])
	}

	func testResolveGitDiffPathsDedupesCanonicalizedResolvedMapAndFallbackPaths() {
		let candidates = ["legacy", "canonical"]
		let resolvedMap = ["legacy": "/tmp/Project/./File.swift"]

		let resolved = MCPServerViewModel.resolveGitDiffPaths(
			candidates: candidates,
			resolvedMap: resolvedMap,
			normalizeUserInput: { _ in "/tmp/Project/File.swift" },
			fileExists: { path in path == "/tmp/Project/File.swift" }
		)

		XCTAssertEqual(resolved, ["/tmp/Project/File.swift"])
	}

	func testGitDiffPathNormalizationConvertsAbsolutePathsToRepoRelativePaths() {
		let relative = GitDiffPathNormalization.gitRelativePaths(
			from: ["/tmp/Repo/./Sources/Feature/../File.swift"],
			repoRootPath: "/tmp/Repo"
		)

		XCTAssertEqual(relative, ["Sources/File.swift"])
	}

	func testGitDiffPathNormalizationRejectsSiblingPrefixMatches() {
		let relative = GitDiffPathNormalization.gitRelativePaths(
			from: ["/tmp/repository/File.swift"],
			repoRootPath: "/tmp/repo"
		)

		XCTAssertEqual(relative, [])
	}

	func testGitDiffPathNormalizationSkipsRepoRootItself() {
		let relative = GitDiffPathNormalization.gitRelativePaths(
			from: ["/tmp/Repo"],
			repoRootPath: "/tmp/Repo"
		)

		XCTAssertEqual(relative, [])
	}
}



// MARK: - Merged from WorkspaceSelectionNormalizationTests.swift


extension CoreUtilityTests {
	func testRebasedStoredSelectionSlicesCanonicalizesLegacyKey() {
		let selection = StoredSelection(
			selectedPaths: [],
			autoCodemapPaths: [],
			slices: [
				"/tmp/Project/./File.swift": [LineRange(start: 1, end: 2)]
			],
			codemapAutoEnabled: false
		)

		let rebased = WorkspaceManagerViewModel.rebasedStoredSelectionSlices(
			selection,
			for: "/tmp/Project/File.swift",
			transform: { $0 }
		)

		XCTAssertEqual(
			rebased?.slices,
			[
				"/tmp/Project/File.swift": [LineRange(start: 1, end: 2)]
			]
		)
	}

	func testRebasedStoredSelectionSlicesDropsCanonicalizedEntryWhenTransformEmptiesRanges() {
		let selection = StoredSelection(
			selectedPaths: [],
			autoCodemapPaths: [],
			slices: [
				"/tmp/Project//File.swift": [LineRange(start: 1, end: 2)]
			],
			codemapAutoEnabled: false
		)

		let rebased = WorkspaceManagerViewModel.rebasedStoredSelectionSlices(
			selection,
			for: "/tmp/Project/File.swift",
			transform: { _ in [] }
		)

		XCTAssertEqual(rebased?.slices, [:])
	}

	func testRebasedStoredSelectionSlicesPrefersCanonicalKeyWhenBothVariantsExist() {
		let selection = StoredSelection(
			selectedPaths: [],
			autoCodemapPaths: [],
			slices: [
				"/tmp/Project/./File.swift": [LineRange(start: 1, end: 2)],
				"/tmp/Project/File.swift": [LineRange(start: 5, end: 6)]
			],
			codemapAutoEnabled: false
		)

		let rebased = WorkspaceManagerViewModel.rebasedStoredSelectionSlices(
			selection,
			for: "/tmp/Project/File.swift",
			transform: { ranges in ranges + [LineRange(start: 7, end: 8)] }
		)

		XCTAssertEqual(
			rebased?.slices,
			[
				"/tmp/Project/File.swift": [LineRange(start: 5, end: 8)]
			]
		)
	}

	func testWorkspacePresetDirtyCheckMatchesCanonicalRelativeAndAbsolutePaths() {
		let isDirty = WorkspaceManagerViewModel.isPresetSelectionDirty(
			presetPaths: [" /tmp/Project/./File.swift ", "Sources//Nested/../Other.swift"],
			selectionPaths: [
				(absolute: "/tmp/Project/File.swift", relative: "File.swift"),
				(absolute: "/tmp/Project/Sources/Other.swift", relative: "Sources/Other.swift")
			]
		)

		XCTAssertFalse(isDirty)
	}

	func testWorkspacePresetDirtyCheckDetectsMissingPresetEntry() {
		let isDirty = WorkspaceManagerViewModel.isPresetSelectionDirty(
			presetPaths: ["File.swift", "Sources/Other.swift"],
			selectionPaths: [
				(absolute: "/tmp/Project/File.swift", relative: "File.swift")
			]
		)

		XCTAssertTrue(isDirty)
	}
}



// MARK: - Merged from LocalizedComparisonLintTests.swift

import Foundation

extension CoreUtilityTests {
	func testNoLocalizedComparisonsInAppSources() throws {
		let testFileURL = URL(fileURLWithPath: #file)
		let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
		let appRoot = repoRoot.appendingPathComponent("RepoPrompt")
		
		let forbiddenPatterns = [
			"localizedStandardCompare\\s*\\(",
			"localizedCaseInsensitiveCompare\\s*\\(",
			"localizedCaseInsensitiveContains\\s*\\("
		]
		let regexes = try forbiddenPatterns.map { pattern in
			try NSRegularExpression(pattern: pattern)
		}
		
		var violations: [String] = []
		guard let enumerator = FileManager.default.enumerator(
			at: appRoot,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles, .skipsPackageDescendants]
		) else {
			XCTFail("Unable to enumerate app sources at \(appRoot.path)")
			return
		}
		
		for case let fileURL as URL in enumerator {
			guard fileURL.pathExtension == "swift" else { continue }
			let contents = try String(contentsOf: fileURL)
			let searchRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
			for regex in regexes {
				if regex.firstMatch(in: contents, options: [], range: searchRange) != nil {
					let relativePath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
					violations.append("\(relativePath) matches \(regex.pattern)")
					break
				}
			}
		}
		
		XCTAssertTrue(
			violations.isEmpty,
			"Localized comparisons found in app sources:\n" + violations.joined(separator: "\n")
		)
	}
}



// MARK: - Merged from SyntaxManagerLimitTests.swift


extension CoreUtilityTests {
	func testParseSkipsWhenLineLimitExceeded() throws {
		let limit = SyntaxManager.parseLineLimit
		let content = Array(repeating: "let value = 0\n", count: limit + 1).joined()
		guard let reason = SyntaxManager.shared.parsingOversizeReason(for: content) else {
			return XCTFail("Expected oversize reason for line limit")
		}
		guard case .lineCountExceeded(let actual) = reason else {
			return XCTFail("Expected lineCountExceeded but got \(reason)")
		}
		XCTAssertGreaterThan(actual, limit)
		let summary = try SyntaxManager.shared.parseSummary(content: content, fileExtension: "swift")
		XCTAssertNil(summary)
	}
	
	func testCodeMapSkipsWhenCharacterLimitExceeded() throws {
		let limit = SyntaxManager.parseUTF16Limit
		let content = String(repeating: "a", count: limit + 1)
		guard let reason = SyntaxManager.shared.parsingOversizeReason(for: content) else {
			return XCTFail("Expected oversize reason for utf16 length")
		}
		guard case .utf16LengthExceeded(let actual) = reason else {
			return XCTFail("Expected utf16LengthExceeded but got \(reason)")
		}
		XCTAssertGreaterThan(actual, limit)
		let captures = try SyntaxManager.shared.codeMap(content: content, fileExtension: "swift")
		XCTAssertTrue(captures.isEmpty)
	}
}



// MARK: - Merged from ToolCardRouterCoverageTests.swift


extension CoreUtilityTests {
	func testKnownResultToolsMatchSupportedRepoPromptTools() {
		let expected: Set<String> = [
			"bash",
			"read",
			"read_file",
			"apply_edits",
			"apply_patch",
			"edit",
			"file_search",
			"get_file_tree",
			"get_code_structure",
			"file_actions",
			"manage_selection",
			"workspace_context",
			"prompt",
			"ask_oracle",
			"oracle_utils",
			"oracle_chat_log",
			"bind_context",
			"manage_workspaces",
			"git",
			"context_builder",
			"request_user_input",
			"agent_explore",
			"agent_run",
			"agent_manage",
			"app_settings"
		]
		XCTAssertEqual(ToolCardRouter.knownResultTools, expected)
	}

	func testNormalizedToolNameStripsRepoPromptPrefix() {
		XCTAssertEqual(normalizedToolCardName("mcp__RepoPrompt__git"), "git")
		XCTAssertEqual(normalizedToolCardName("functions.mcp_RepoPrompt__read_file"), "read_file")
		XCTAssertEqual(normalizedToolCardName("read_file"), "read_file")
		XCTAssertEqual(normalizedToolCardName("Edit File"), "edit")
	}

	func testCursorEditParticipatesInAutoExpandableEditPool() {
		let applyEdits = AgentChatItem.toolResult(name: "apply_edits", invocationID: UUID(), resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 0)
		let applyPatch = AgentChatItem.toolResult(name: "apply_patch", invocationID: UUID(), resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 1)
		let cursorEdit = AgentChatItem.toolResult(name: "edit", invocationID: UUID(), resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2)
		let readFile = AgentChatItem.toolResult(name: "read_file", invocationID: UUID(), resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3)
		let editCall = AgentChatItem.toolCall(name: "edit", invocationID: UUID(), argsJSON: nil, sequenceIndex: 4)

		XCTAssertTrue(isAutoExpandableEditToolResult(applyEdits))
		XCTAssertTrue(isAutoExpandableEditToolResult(applyPatch))
		XCTAssertTrue(isAutoExpandableEditToolResult(cursorEdit))
		XCTAssertFalse(isAutoExpandableEditToolResult(readFile))
		XCTAssertFalse(isAutoExpandableEditToolResult(editCall))
		XCTAssertEqual([applyEdits, applyPatch, cursorEdit].last(where: isAutoExpandableEditToolResult)?.id, cursorEdit.id)
	}

	func testCanonicalRepoPromptToolNameRecognizesGeminiWrappedVariants() {
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptToolName("mcp__RepoPrompt__read_file"), "read_file")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptToolName("functions.mcp_RepoPrompt__read_file"), "read_file")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptToolName("functions.mcp_RepoPrompt__set_status"), "set_status")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptToolName("functions.mcp_RepoPrompt__app_settings"), "app_settings")
		XCTAssertNil(MCPIntegrationHelper.canonicalRepoPromptToolName("functions.read_file_native"))
	}

	func testRepoPromptAskUserToolNormalizationRecognizesOnlyRepoPromptAskUserVariants() {
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptAskUserToolName("ask_user"), "ask_user")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptAskUserToolName("ask_user_question"), "ask_user")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptAskUserToolName("mcp__RepoPrompt__ask_user"), "ask_user")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptAskUserToolName("functions.mcp__RepoPrompt__ask_user"), "ask_user")
		XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptAskUserToolName("functions.mcp_RepoPrompt__ask_user_question"), "ask_user")
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptAskUserToolName("mcp__RepoPrompt__ask_user"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptAskUserToolName("functions.mcp_RepoPrompt__ask_user_question"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptAskUserToolName("functions.ask_user"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptAskUserToolName("AskUserQuestion"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptAskUserToolName("request_user_input"))
	}

	func testFileSearchSubtitleIncludesScopedFilterPath() {
		let argsJSON = #"{"pattern":"agentModePrompt","filter":{"paths":["RepoPrompt/Services/AI/Prompts","RepoPrompt/Services/MCP","RepoPrompt/Views"]}}"#
		let subtitle = ToolCardRouter.callSubtitle(for: "file_search", argsJSON: argsJSON)
		XCTAssertEqual(subtitle, #""agentModePrompt" • scope: ...AI/Prompts (+2 more)"#)
	}

	func testFileSearchSubtitleUsesDirectPathAlias() {
		let argsJSON = #"{"pattern":"TODO","path":"RepoPrompt/Services"}"#
		let subtitle = ToolCardRouter.callSubtitle(for: "mcp__RepoPrompt__file_search", argsJSON: argsJSON)
		XCTAssertEqual(subtitle, #""TODO" • scope: RepoPrompt/Services"#)
	}

	func testFileTreeSubtitleDescribesRootsMode() {
		let subtitle = ToolCardRouter.callSubtitle(for: "get_file_tree", argsJSON: #"{"type":"roots"}"#)
		XCTAssertEqual(subtitle, "roots")
	}

	func testFileTreeSubtitleIncludesModePathAndDepth() {
		let argsJSON = #"{"mode":"folders","path":"RepoPrompt/Views/AgentMode/ToolCards","max_depth":2}"#
		let subtitle = ToolCardRouter.callSubtitle(for: "get_file_tree", argsJSON: argsJSON)
		XCTAssertEqual(subtitle, "folders only • ...AgentMode/ToolCards • depth 2")
	}

	func testToolCardAccentResolverUsesClusterFamiliesForAgentTools() {
		XCTAssertEqual(ToolCardAccentResolver.family(for: "get_file_tree"), .navigation)
		XCTAssertEqual(ToolCardAccentResolver.family(for: "apply_edits"), .edit)
		XCTAssertEqual(ToolCardAccentResolver.family(for: "ask_oracle"), .communication)
		XCTAssertEqual(ToolCardAccentResolver.family(for: "bind_context"), .config)
		XCTAssertEqual(ToolCardAccentResolver.family(for: "context_builder"), .config)
		XCTAssertEqual(ToolCardAccentResolver.family(for: "app_settings"), .config)
	}

	func testAppSettingsToolCallSubtitleSummarizesSelectorsAndValues() {
		XCTAssertEqual(
			ToolCardRouter.callSubtitle(for: "app_settings", argsJSON: #"{"op":"list","group":"ui"}"#),
			"list • ui"
		)
		XCTAssertEqual(
			ToolCardRouter.callSubtitle(for: "functions.mcp_RepoPrompt__app_settings", argsJSON: #"{"op":"get","keys":["ui.appearance_mode","mcp.show_model_presets","code_maps.enabled","models.planning_model"]}"#),
			"get • ui.appearance_mode, mcp.show_model_presets, code_maps.enabled (+1 more)"
		)
		XCTAssertEqual(
			ToolCardRouter.callSubtitle(for: "app_settings", argsJSON: #"{"op":"set","key":"ui.show_tooltips","value":false}"#),
			"set • ui.show_tooltips = false"
		)
	}

	func testAppSettingsResultPresentationSummarizesSetResult() {
		let args = #"{"op":"set","key":"ui.show_tooltips","value":false}"#
		let result = #"{"op":"set","status":"ok","key":"ui.show_tooltips","old_value":true,"new_value":false,"changed":true,"applied":true}"#
		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertEqual(presentation.subtitle, "set • ui.show_tooltips • changed")
		XCTAssertEqual(presentation.detailText, "true → false")
		XCTAssertEqual(presentation.status, .success)
	}

	func testAppSettingsResultPresentationUnwrapsContentTextResult() {
		let args = #"{"op":"set","key":"ui.show_tooltips","value":false}"#
		let result = #"{"content":[{"type":"text","text":"{\"op\":\"set\",\"status\":\"ok\",\"key\":\"ui.show_tooltips\",\"old_value\":true,\"new_value\":false,\"changed\":true}"}]}"#
		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertEqual(presentation.subtitle, "set • ui.show_tooltips • changed")
		XCTAssertEqual(presentation.detailText, "true → false")
		XCTAssertEqual(presentation.status, .success)
	}

	func testFileTreeCardPresentationBuildsSubtreeLimitedSummary() {
		let dto = ToolResultDTOs.FileTreeDTO(
			rootsCount: 3,
			usesLegend: false,
			tree: "RepoPrompt\n└── ToolCards",
			note: nil,
			wasTruncated: true
		)
		let args = ToolArgsDTOs.FileTreeArgs(path: "RepoPrompt/Views/AgentMode/ToolCards", type: nil, mode: "folders", maxDepth: 2)

		let presentation = FileTreeCardPresentationBuilder.build(dto: dto, args: args, toolIsError: nil, raw: nil)
		XCTAssertEqual(presentation.subtitle, "Folders • …/AgentMode/ToolCards")
		XCTAssertNil(presentation.detailText)
		XCTAssertEqual(presentation.status, .warning)
	}

	func testFileTreeCardPresentationBuildsRootDetailPreview() {
		let dto = ToolResultDTOs.FileTreeDTO(
			rootsCount: 3,
			usesLegend: false,
			tree: "Workspace/App\nWorkspace/CLI\nWorkspace/Docs",
			note: nil,
			wasTruncated: false
		)

		let args = ToolArgsDTOs.FileTreeArgs(path: nil, type: "roots", mode: nil, maxDepth: nil)
		let presentation = FileTreeCardPresentationBuilder.build(dto: dto, args: args, toolIsError: nil, raw: nil)
		XCTAssertEqual(presentation.subtitle, "3 roots")
		XCTAssertNil(presentation.detailText)
		XCTAssertEqual(presentation.status, .success)
	}

	func testGitCardPresentationBuildsStatusBranchAndCounts() {
		let dto = ToolResultDTOs.GitToolReplyDTO(
			op: "status",
			status: .init(
				branch: "main",
				upstream: "origin/main",
				ahead: 2,
				behind: 1,
				staged: ["A.swift", "B.swift"],
				modified: ["C.swift"],
				untracked: ["D.swift", "E.swift"],
				summary: "main | +2 -1 | 2 staged, 1 modified, 2 untracked"
			)
		)

		let presentation = GitCardPresentationBuilder.build(dto: dto, args: nil, toolIsError: nil)
		XCTAssertEqual(presentation.subtitle, "status • main")
		XCTAssertEqual(presentation.detailText, "+2 -1 • origin/main • 2 staged • 1 modified • 2 untracked")
		XCTAssertEqual(presentation.status, .success)
	}

	func testGitCardPresentationBuildsLimitedDiffSummaryAndContext() {
		let dto = ToolResultDTOs.GitToolReplyDTO(
			op: "diff",
			diff: .init(
				compare: "uncommitted",
				detail: "files",
				files: nil,
				totals: .init(files: 3, insertions: 10, deletions: 2),
				byStatus: nil,
				oneliner: "3 files (+10 -2)",
				truncated: true,
				truncationNote: "Output truncated"
			),
			inputs: .init(
				compare: "uncommitted",
				compareInput: nil,
				scope: "selected",
				requestedPathsCount: 2,
				contextLines: 3,
				detectRenames: false
			)
		)

		let presentation = GitCardPresentationBuilder.build(dto: dto, args: nil, toolIsError: nil)
		XCTAssertEqual(presentation.subtitle, "diff • 3 files (+10 -2)")
		XCTAssertEqual(presentation.detailText, "uncommitted • selected • files")
		XCTAssertEqual(presentation.status, .warning)
	}

	func testStoredToolCardPresentationRendersSummaryOnlyTargetRows() throws {
		let cases: [(toolName: String, title: String, subtitle: String, detailText: String?, status: ToolCardStatus, op: String?)] = [
			(
				"read_file",
				"Read File",
				"BombSquadPointerData.cs • Lines 1-68 of 68",
				nil,
				.success,
				"read_file"
			),
			(
				"file_search",
				"Search",
				#""SpatialPointerKind" • 8 matches in 3 files (limited)"#,
				nil,
				.warning,
				"file_search"
			),
			(
				"manage_selection",
				"Selection",
				"set • 7 files • 1085 tokens",
				"0 full • 2 sliced • 5 codemap",
				.success,
				"set"
			),
			(
				"workspace_context",
				"Context",
				"7 files • 1460 tokens",
				"selection • file blocks • copy preset",
				.success,
				"workspace_context"
			),
			(
				"get_file_tree",
				"File Tree",
				"Selected • 1 root",
				nil,
				.success,
				"get_file_tree"
			),
			(
				"get_code_structure",
				"Code Structure",
				"3 files • 3 omitted • 3 unmapped",
				"…/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)",
				.warning,
				"get_code_structure"
			),
			(
				"git",
				"Git",
				"show • 04ada27a",
				"Merge branch 'masiknight' • 2 files (+3732 -3890)",
				.success,
				"show"
			)
		]

		for testCase in cases {
			let raw = try summaryOnlyRenderSummaryJSON(
				toolName: testCase.toolName,
				title: testCase.title,
				subtitle: testCase.subtitle,
				detailText: testCase.detailText,
				status: testCase.status,
				op: testCase.op,
				legacySummaryText: "\(testCase.toolName) • success"
			)
			let presentation = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: raw), testCase.toolName)

			XCTAssertEqual(presentation.title, testCase.title, testCase.toolName)
			XCTAssertEqual(presentation.subtitle, testCase.subtitle, testCase.toolName)
			XCTAssertEqual(presentation.detailText, testCase.detailText, testCase.toolName)
			XCTAssertEqual(presentation.inlineSubtitle, [testCase.subtitle, testCase.detailText].compactMap { $0 }.joined(separator: " • "), testCase.toolName)
			XCTAssertEqual(presentation.status, testCase.status, testCase.toolName)
		}
	}

	func testToolResultStatusResolverHonorsSummaryOnlyRenderStatusBeforeTopLevelStatus() throws {
		let raw = try summaryOnlyRenderSummaryJSON(
			toolName: "file_search",
			title: "Search",
			subtitle: #""SpatialPointerKind" • 8 matches in 3 files (limited)"#,
			detailText: nil,
			status: .warning,
			op: "file_search",
			topLevelStatus: "success"
		)

		XCTAssertEqual(
			ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral),
			.warning
		)
	}

	func testCodeStructureSummaryOnlyRenderSummaryRestoresCompactFacts() throws {
		let raw = try summaryOnlyRenderSummaryJSON(
			toolName: "get_code_structure",
			title: "Code Structure",
			subtitle: "3 files • 3 omitted • 3 unmapped",
			detailText: "…/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)",
			status: .warning,
			op: "get_code_structure",
			topLevelStatus: "success"
		)

		let presentation = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: raw))

		XCTAssertEqual(presentation.title, "Code Structure")
		XCTAssertEqual(presentation.subtitle, "3 files • 3 omitted • 3 unmapped")
		XCTAssertEqual(presentation.detailText, "…/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)")
		XCTAssertEqual(presentation.inlineSubtitle, "3 files • 3 omitted • 3 unmapped • …/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)")
		XCTAssertEqual(presentation.status, .warning)
		XCTAssertEqual(ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral), .warning)
	}

	func testFileTreeSummaryOnlyRenderSummaryDoesNotFallBackToAuto() throws {
		let raw = try summaryOnlyRenderSummaryJSON(
			toolName: "get_file_tree",
			title: "File Tree",
			subtitle: "Selected • 1 root",
			detailText: nil,
			status: .success,
			op: "get_file_tree"
		)

		let presentation = FileTreeCardPresentationBuilder.build(dto: nil, args: nil, toolIsError: nil, raw: raw)
		let failedPresentation = FileTreeCardPresentationBuilder.build(dto: nil, args: nil, toolIsError: true, raw: raw)

		XCTAssertEqual(presentation.subtitle, "Selected • 1 root")
		XCTAssertNotEqual(presentation.subtitle, "Auto • 1 root")
		XCTAssertNil(presentation.detailText)
		XCTAssertEqual(presentation.status, .success)
		XCTAssertEqual(failedPresentation.subtitle, "Selected • 1 root")
		XCTAssertEqual(failedPresentation.status, .failure)
	}

	func testStoredToolCardPresentationFallsBackToLegacySummaryText() throws {
		let object: [String: Any] = [
			"summary_only": true,
			"status": "success",
			"summary_text": "read_file • success"
		]
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		let raw = try XCTUnwrap(String(data: data, encoding: .utf8))

		let presentation = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: raw))

		XCTAssertNil(presentation.title)
		XCTAssertEqual(presentation.inlineSubtitle, "read_file • success")
		XCTAssertEqual(presentation.status, .success)
	}

	func testStoredToolCardPresentationUsesLegacyTextWhenRenderSummaryHasNoLine() throws {
		let object: [String: Any] = [
			"summary_only": true,
			"status": "success",
			"summary_text": "show • 04ada27a • Merge branch 'masiknight'",
			"render_summary": [
				"schema_version": 1,
				"tool_name": "git",
				"title": "Git",
				"status": "success",
				"op": "show"
			]
		]
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		let raw = try XCTUnwrap(String(data: data, encoding: .utf8))

		let presentation = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: raw))

		XCTAssertEqual(presentation.title, "Git")
		XCTAssertEqual(presentation.inlineSubtitle, "show • 04ada27a • Merge branch 'masiknight'")
		XCTAssertEqual(presentation.status, .success)
	}

	func testAgentManageCleanupPresentationUsesRawOrCompactCounts() throws {
		var item = AgentChatItem.toolResult(
			name: "agent_manage",
			invocationID: UUID(),
			resultJSON: #"{"status":"success","summary_only":true,"summary_text":"cleanup complete"}"#,
			isError: false,
			sequenceIndex: 0
		)
		item.toolArgsJSON = #"{"op":"cleanup_sessions"}"#
		let raw = #"{"status":"success","deleted_count":3,"skipped_count":2}"#
		let source = ToolResultPayloadSource(itemID: item.id, storedPayload: item.toolResultJSON, rawPayload: raw)

		let presentation = AgentManageResultCardPresentation.build(for: item, payloadSource: source)

		XCTAssertEqual(presentation.title, "Cleanup Sessions")
		XCTAssertEqual(presentation.subtitle, "3 deleted, 2 skipped")
		XCTAssertEqual(presentation.status, .success)

		item.toolResultJSON = #"{"status":"success","summary_only":true,"deleted_count":4,"skipped_count":0,"summary_text":"4 deleted, 0 skipped"}"#
		let compactSource = ToolResultPayloadSource(itemID: item.id, storedPayload: item.toolResultJSON, rawPayload: nil)
		let compactPresentation = AgentManageResultCardPresentation.build(for: item, payloadSource: compactSource)
		XCTAssertEqual(compactPresentation.subtitle, "4 deleted, 0 skipped")

		item.toolResultJSON = #"{"status":"success","summary_only":true,"deleted_count":5,"summary_text":"5 deleted"}"#
		let partialSource = ToolResultPayloadSource(itemID: item.id, storedPayload: item.toolResultJSON, rawPayload: nil)
		let partialPresentation = AgentManageResultCardPresentation.build(for: item, payloadSource: partialSource)
		XCTAssertEqual(partialPresentation.subtitle, "5 deleted")
	}

	func testAgentManageCleanupPresentationDoesNotDefaultMissingCountsToZero() throws {
		var item = AgentChatItem.toolResult(
			name: "agent_manage",
			invocationID: UUID(),
			resultJSON: #"{"status":"success","summary_only":true}"#,
			isError: false,
			sequenceIndex: 0
		)
		item.toolArgsJSON = #"{"op":"cleanup_sessions"}"#
		let source = ToolResultPayloadSource(itemID: item.id, storedPayload: item.toolResultJSON, rawPayload: nil)

		let presentation = AgentManageResultCardPresentation.build(for: item, payloadSource: source)

		XCTAssertNotEqual(presentation.subtitle, "0 deleted, 0 skipped")
		XCTAssertEqual(presentation.subtitle, "success")
	}

	func testChatSendPresentationUsesRawAndCompactOracleMetadata() throws {
		let item = AgentChatItem.toolResult(
			name: "oracle_send",
			invocationID: UUID(),
			resultJSON: #"{"status":"success","summary_only":true}"#,
			isError: false,
			sequenceIndex: 0
		)
		let raw = #"{"status":"success","chat_id":"oracle-chat","mode":"review","diffs":[{"path":"A.swift","patch":"diff"}]}"#
		let source = ToolResultPayloadSource(itemID: item.id, storedPayload: item.toolResultJSON, rawPayload: raw)

		let presentation = ChatSendResultCardPresentation.build(for: item, payloadSource: source)

		XCTAssertEqual(presentation.title, "Oracle")
		XCTAssertEqual(presentation.subtitle, "review • 1 diff")
		XCTAssertEqual(presentation.status, .warning)
		XCTAssertEqual(presentation.chatID, "oracle-chat")

		let compact = #"{"status":"success","summary_only":true,"chat_id":"compact-chat","mode":"plan","diff_count":2,"has_response":true,"summary_text":"plan • 2 diffs"}"#
		let compactItem = AgentChatItem.toolResult(
			name: "ask_oracle",
			invocationID: UUID(),
			resultJSON: compact,
			isError: false,
			sequenceIndex: 0
		)
		let compactSource = ToolResultPayloadSource(itemID: compactItem.id, storedPayload: compactItem.toolResultJSON, rawPayload: nil)
		let compactPresentation = ChatSendResultCardPresentation.build(for: compactItem, payloadSource: compactSource)
		XCTAssertEqual(compactPresentation.title, "Oracle")
		XCTAssertEqual(compactPresentation.subtitle, "plan • 2 diffs")
		XCTAssertEqual(compactPresentation.status, .success)

		let failedCompact = #"{"status":"failed","summary_only":true,"diff_count":1}"#
		let failedItem = AgentChatItem.toolResult(
			name: "oracle_send",
			invocationID: UUID(),
			resultJSON: failedCompact,
			isError: false,
			sequenceIndex: 0
		)
		let failedSource = ToolResultPayloadSource(itemID: failedItem.id, storedPayload: failedItem.toolResultJSON, rawPayload: nil)
		let failedPresentation = ChatSendResultCardPresentation.build(for: failedItem, payloadSource: failedSource)
		XCTAssertEqual(failedPresentation.status, .failure)
	}

	func testToolResultStatusResolverKeepsSummaryOnlyErrorAuthoritative() throws {
		let object: [String: Any] = [
			"summary_only": true,
			"is_error": true,
			"status": "success",
			"render_summary": [
				"schema_version": 1,
				"tool_name": "file_search",
				"title": "Search",
				"subtitle": #""SpatialPointerKind" • 8 matches in 3 files"#,
				"status": "success"
			]
		]
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		let raw = try XCTUnwrap(String(data: data, encoding: .utf8))

		XCTAssertEqual(
			ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral),
			.failure
		)
	}

	private func summaryOnlyRenderSummaryJSON(
		toolName: String,
		title: String,
		subtitle: String,
		detailText: String?,
		status: ToolCardStatus,
		op: String?,
		topLevelStatus: String = "success",
		legacySummaryText: String? = nil
	) throws -> String {
		var renderSummary: [String: Any] = [
			"schema_version": 1,
			"tool_name": toolName,
			"title": title,
			"subtitle": subtitle,
			"status": renderSummaryStatusWord(status)
		]
		if let detailText {
			renderSummary["detail_text"] = detailText
		}
		if let op {
			renderSummary["op"] = op
		}
		var object: [String: Any] = [
			"summary_only": true,
			"status": topLevelStatus,
			"render_summary": renderSummary
		]
		if let legacySummaryText {
			object["summary_text"] = legacySummaryText
		}
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		return try XCTUnwrap(String(data: data, encoding: .utf8))
	}

	private func renderSummaryStatusWord(_ status: ToolCardStatus) -> String {
		switch status {
		case .neutral:
			return "neutral"
		case .success:
			return "success"
		case .warning:
			return "warning"
		case .failure:
			return "failure"
		case .running:
			return "running"
		}
	}

	func testToolResultStatusResolverReadsIsErrorFieldFromJSON() {
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"is_error\":false}",
				fallback: .neutral
			),
			.success
		)
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"is_error\":true}",
				fallback: .neutral
			),
			.failure
		)
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"isError\":false}",
				fallback: .neutral
			),
			.success
		)
	}

	func testToolResultStatusResolverReadsNestedStructuredStatusFields() {
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"tool_result\":{\"status\":\"failed\"}}",
				fallback: .neutral
			),
			.failure
		)
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"response\":{\"result\":{\"status\":\"completed\"}}}",
				fallback: .neutral
			),
			.success
		)
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"content\":\"failed to parse doc\"}",
				fallback: .neutral
			),
			.neutral
		)
	}

	func testToolResultStatusResolverMapsCommandTerminalSynonyms() {
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"status\":\"finished\"}",
				fallback: .neutral
			),
			.success
		)
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"status\":\"done\"}",
				fallback: .neutral
			),
			.success
		)
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: nil,
				raw: "{\"status\":\"killed\"}",
				fallback: .neutral
			),
			.failure
		)
	}

	func testToolResultStatusResolverCommandNegativeExitWithDurationShowsFailure() {
		// Completion-hinted payload (durationMs present) should show failure, not neutral.
		let completionHinted = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"123","durationMs":5000}"#
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: true,
				raw: completionHinted,
				fallback: .neutral
			),
			.failure
		)
	}

	func testToolResultStatusResolverCommandNegativeExitWithoutDurationShowsNeutral() {
		// Without a completion timing hint, negative exit stays neutral (wrapper/running heuristic).
		let noTimingHint = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"123"}"#
		XCTAssertEqual(
			ToolResultStatusResolver.resolve(
				toolIsError: true,
				raw: noTimingHint,
				fallback: .neutral
			),
			.neutral
		)
	}

	func testAgentChatItemPersistDerivesStatusFromIsErrorJSONField() {
		let successItem = AgentChatItem.toolResult(
			name: "Read",
			resultJSON: "{\"is_error\":false}",
			isError: nil,
			sequenceIndex: 1
		)
		let failedItem = AgentChatItem.toolResult(
			name: "Read",
			resultJSON: "{\"is_error\":true}",
			isError: nil,
			sequenceIndex: 2
		)

		XCTAssertEqual(AgentChatItemPersist(from: successItem).toolResultStatus, "success")
		XCTAssertEqual(AgentChatItemPersist(from: failedItem).toolResultStatus, "failed")
	}

	func testAgentChatItemPersistDerivesStatusFromNestedStructuredJSON() {
		let nestedFailed = AgentChatItem.toolResult(
			name: "Read",
			resultJSON: "{\"tool_result\":{\"status\":\"failed\"}}",
			isError: nil,
			sequenceIndex: 3
		)
		let plainText = AgentChatItem.toolResult(
			name: "Read",
			resultJSON: "failed to parse doc",
			isError: nil,
			sequenceIndex: 4
		)

		XCTAssertEqual(AgentChatItemPersist(from: nestedFailed).toolResultStatus, "failed")
		XCTAssertEqual(AgentChatItemPersist(from: plainText).toolResultStatus, "unknown")
	}
}



// MARK: - Merged from ServerNetworkManagerTests.swift


extension CoreUtilityTests {
	func testCanonicalToolNameTranslatesDiscoverAliases() {
		XCTAssertEqual(ServerNetworkManager.canonicalToolName(for: "discover_manage_selection"), "manage_selection")
		XCTAssertEqual(ServerNetworkManager.canonicalToolName(for: "discover_prompt"), "prompt")
		XCTAssertEqual(ServerNetworkManager.canonicalToolName(for: "discover_workspace_context"), "workspace_context")
	}

	func testCanonicalToolNameReturnsOriginalForUnknownValues() {
		XCTAssertEqual(ServerNetworkManager.canonicalToolName(for: "manage_selection"), "manage_selection")
		XCTAssertEqual(ServerNetworkManager.canonicalToolName(for: "irrelevant_tool"), "irrelevant_tool")
	}

	func testCanonicalToolNameDoesNotAliasDelegateEditFile() {
		XCTAssertEqual(
			ServerNetworkManager.canonicalToolName(for: DelegateEditToolNames.editFile),
			DelegateEditToolNames.editFile
		)
		XCTAssertEqual(
			ServerNetworkManager.canonicalToolName(for: "apply_edits"),
			"apply_edits"
		)
	}

	func testDelegateEditDebugToolListAdvertisesEditFileInsteadOfDisabledLiveApplyEdits() async throws {
		let registeredServices = await MainActor.run { ServiceRegistry.services }
		var hasRegisteredApplyEditsService = false
		for service in registeredServices {
			if await service.tools.contains(where: { $0.name == "apply_edits" }) {
				hasRegisteredApplyEditsService = true
				break
			}
		}
		try XCTSkipIf(!hasRegisteredApplyEditsService, "Registered apply_edits service is unavailable in this test process")

		let applyEditsWasEnabled = await MainActor.run {
			ToolAvailabilityStore.shared.isEnabled("apply_edits")
		}
		addTeardownBlock {
			await ToolAvailabilityStore.shared.toggle(
				"apply_edits",
				enabled: applyEditsWasEnabled
			)
		}
		await ToolAvailabilityStore.shared.toggle("apply_edits", enabled: false)

		let manager = ServerNetworkManager.shared
		let connectionID = UUID()
		await manager.setRunPurpose(.delegateEditRun, for: connectionID)
		await manager.setRestrictedTools(for: connectionID, tools: DelegateEditMCPToolPolicy.restrictedTools)

		let names = try await manager.debugListToolNames(for: connectionID, hydratePersistedPolicy: false)
		XCTAssertTrue(names.contains(DelegateEditToolNames.editFile))
		XCTAssertFalse(names.contains("apply_edits"))
	}

	func testDelegateEditToolSurfacesExposeEditFileOnlyForDelegateEdit() {
		let surfaces = DelegateEditToolSurfaces.surfaces(for: .delegateEditRun)
		let advertised = surfaces.first { $0.name == DelegateEditToolNames.editFile }

		XCTAssertEqual(advertised?.name, DelegateEditToolNames.editFile)
		XCTAssertTrue(advertised?.description.contains("Apply edits to the delegated file") == true)
		XCTAssertEqual(advertised?.annotations.readOnlyHint, false)
		XCTAssertEqual(advertised?.annotations.destructiveHint, false)
		XCTAssertTrue(DelegateEditToolSurfaces.surfaces(for: .agentModeRun).isEmpty)
		XCTAssertTrue(DelegateEditToolSurfaces.surfaces(for: .discoverRun).isEmpty)
		XCTAssertTrue(DelegateEditToolSurfaces.surfaces(for: .unknown).isEmpty)
	}

	func testDelegateEditToolNamesDeclareSandboxOwnedTools() {
		XCTAssertEqual(
			DelegateEditToolNames.sandboxToolNames,
			[
				DelegateEditToolNames.editFile,
				DelegateEditToolNames.readFile,
				DelegateEditToolNames.fileSearch
			]
		)
	}

	func testEditFileIsNotAdvertisedOutsideDelegateEditRuns() async throws {
		let manager = ServerNetworkManager()

		for purpose in [MCPRunPurpose.discoverRun, .agentModeRun, .unknown] {
			let connectionID = UUID()
			await manager.setRunPurpose(purpose, for: connectionID)

			let names = try await manager.debugListToolNames(for: connectionID, hydratePersistedPolicy: false)
			XCTAssertFalse(names.contains(DelegateEditToolNames.editFile), "Unexpected edit_file for \(purpose)")
		}
	}

	func testIsRepoPromptToolNameRecognizesOracleChatLogVariants() async {
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("functions.oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("mcp__RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("RepoPrompt_oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("  Functions.Oracle_Chat_Log  "))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolName("oracle_chat_logs"))

		await MainActor.run {
			XCTAssertTrue(AgentModeViewModel.isRepoPromptTool("oracle_chat_log"))
			XCTAssertTrue(AgentModeViewModel.isRepoPromptTool("functions.oracle_chat_log"))
		}
	}

	func testIsRepoPromptToolNameRecognizesAgentControlTools() async {
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("agent_run"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("functions.agent_run"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("agent_explore"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("functions.agent_explore"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("mcp__RepoPrompt__agent_manage"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolName("RepoPrompt__agent_manage"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolName("agent_runs"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolName("agent_manager"))

		await MainActor.run {
			XCTAssertTrue(AgentModeViewModel.isRepoPromptTool("agent_run"))
			XCTAssertTrue(AgentModeViewModel.isRepoPromptTool("functions.agent_explore"))
			XCTAssertTrue(AgentModeViewModel.isRepoPromptTool("functions.agent_manage"))
		}
	}

	func testCodexSpawnAgentIsNotRegisteredAsRepoPromptAgentControlTool() async {
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolName("spawn_agent"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolName("functions.spawn_agent"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolName("mcp__RepoPrompt__spawn_agent"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("mcp__RepoPrompt__spawn_agent"))
		XCTAssertFalse(MCPToolCapabilities.capabilities(for: "spawn_agent").contains(.agentExternalControl))
		XCTAssertFalse(MCPToolCapabilities.capabilities(for: "spawn_agent").contains(.agentExploreControl))
		XCTAssertFalse(ToolCardRouter.knownResultTools.contains("spawn_agent"))

		let registeredServices = await MainActor.run { ServiceRegistry.services }
		for service in registeredServices {
			let tools = await service.tools
			let toolNames = tools.map(\.name)
			XCTAssertFalse(toolNames.contains("spawn_agent"), "RepoPrompt MCP service \(type(of: service)) should not advertise Codex-native spawn_agent")
		}

		await MainActor.run {
			XCTAssertFalse(AgentModeViewModel.isRepoPromptTool("spawn_agent"))
			XCTAssertFalse(AgentModeViewModel.isExplicitRepoPromptTool("mcp__RepoPrompt__spawn_agent"))
		}
	}

	func testIsRepoPromptToolNameWithServerPrefixRequiresExplicitPrefix() async {
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("mcp__RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("functions.mcp__RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("functions.mcp_RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("functions.RepoPrompt__oracle_chat_log"))
		XCTAssertTrue(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("RepoPrompt_oracle_chat_log"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("oracle_chat_log"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("functions.oracle_chat_log"))
		XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix("mcp__other__oracle_chat_log"))

		await MainActor.run {
			XCTAssertTrue(AgentModeViewModel.isExplicitRepoPromptTool("mcp__RepoPrompt__oracle_chat_log"))
			XCTAssertTrue(AgentModeViewModel.isExplicitRepoPromptTool("functions.mcp_RepoPrompt__oracle_chat_log"))
			XCTAssertTrue(AgentModeViewModel.isExplicitRepoPromptTool("RepoPrompt_oracle_chat_log"))
			XCTAssertFalse(AgentModeViewModel.isExplicitRepoPromptTool("oracle_chat_log"))
		}
	}

	func testSanitizedRoutingRestrictedToolsPreservesRoutingAPIs() {
		let input: Set<String> = ["bind_context", "manage_workspaces", "custom_tool"]
		let sanitized = ServerNetworkManager.sanitizedRoutingRestrictedTools(input)
		XCTAssertEqual(sanitized, input)
	}

	func testRecordToolCallSkipsSetStatusHistoryEntry() async {
		let manager = ServerNetworkManager()
		await manager.recordToolCall(for: UUID(), toolName: "set_status")
		await manager.recordToolCall(for: UUID(), toolName: "functions.mcp_RepoPrompt__set_status")

		let history = await manager.getRecentToolCallHistory()
		XCTAssertTrue(history.isEmpty)
	}

	func testRecordToolCallRecordsNormalToolsInHistory() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		await manager.recordToolCall(for: connectionID, toolName: "read_file")

		let history = await manager.getRecentToolCallHistory()
		XCTAssertEqual(history.count, 1)
		XCTAssertEqual(history.first?.toolName, "read_file")
		XCTAssertEqual(history.first?.connectionID, connectionID)
	}

	func testObserverCompletionRunIDReResolvesWhenCallTimeRunIDMissing() async {
		// Trade-off: when call-time runID is unavailable, completion-time re-resolution
		// can recover missed completions but may route to a newly mapped run if the
		// connection was remapped while the tool was in flight. That risk is logged in
		// production diagnostics and kept separate from the differing-runID case below.
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		let runID = UUID()
		let invocationID = UUID()

		let missing = await manager.observerRunIDForCompletionForToolTracking(
			callTimeRunID: nil,
			connectionID: connectionID,
			toolName: "mcp__RepoPrompt__read_file",
			invocationID: invocationID,
			context: "test-missing"
		)
		XCTAssertNil(missing)

		await manager.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			purpose: .agentModeRun,
			windowID: 1
		)

		let resolved = await manager.observerRunIDForCompletionForToolTracking(
			callTimeRunID: nil,
			connectionID: connectionID,
			toolName: "mcp__RepoPrompt__read_file",
			invocationID: invocationID,
			context: "test-reresolve"
		)
		XCTAssertEqual(resolved, runID)
	}

	func testObserverCompletionRunIDKeepsCallTimeRunIDWhenCompletionMappingDiffers() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		let callTimeRunID = UUID()
		let completionTimeRunID = UUID()

		await manager.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: completionTimeRunID,
			purpose: .agentModeRun,
			windowID: 1
		)

		let resolved = await manager.observerRunIDForCompletionForToolTracking(
			callTimeRunID: callTimeRunID,
			connectionID: connectionID,
			toolName: "mcp__RepoPrompt__read_file",
			invocationID: UUID(),
			context: "test-different"
		)
		XCTAssertEqual(resolved, callTimeRunID)
	}

	func testGeminiGrantedToolsKeepSetStatusButDropRemovedReasoningTools() {
		let grantedTools = AgentModeMCPToolPolicy.grantedTools(forAgent: .gemini)
		XCTAssertTrue(grantedTools.contains("set_status"))
		XCTAssertFalse(grantedTools.contains("share_thoughts"))
		XCTAssertFalse(grantedTools.contains("wait_for_next_user_instruction"))
	}

	func testAgentModePendingPoliciesKeepDistinctTabsInSameWindow() async {
		let manager = ServerNetworkManager()
		let clientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"
		let windowID = 1
		let tabA = UUID()
		let tabB = UUID()
		let runA = UUID()
		let runB = UUID()

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: windowID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			ttl: 15,
			tabID: tabA,
			runID: runA,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)
		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: windowID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			ttl: 15,
			tabID: tabB,
			runID: runB,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let snapshot = await manager.debugPendingPolicySnapshot(for: clientName)
		let agentModePolicies = snapshot.filter { $0.windowID == windowID && $0.purpose == .agentModeRun && $0.oneShot }
		XCTAssertEqual(agentModePolicies.count, 2, "Distinct tabs should keep independent pending agent-mode policies")
		XCTAssertTrue(agentModePolicies.contains(where: { $0.tabID == tabA && $0.runID == runA }))
		XCTAssertTrue(agentModePolicies.contains(where: { $0.tabID == tabB && $0.runID == runB }))
	}

	func testAgentModePendingPoliciesCollapseStaleEntryForSameTab() async {
		let manager = ServerNetworkManager()
		let clientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"
		let windowID = 1
		let tabID = UUID()
		let originalRunID = UUID()
		let replacementRunID = UUID()

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: windowID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			ttl: 15,
			tabID: tabID,
			runID: originalRunID,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)
		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: windowID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			ttl: 15,
			tabID: tabID,
			runID: replacementRunID,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let snapshot = await manager.debugPendingPolicySnapshot(for: clientName)
		let agentModePolicies = snapshot.filter { $0.windowID == windowID && $0.purpose == .agentModeRun && $0.oneShot }
		XCTAssertEqual(agentModePolicies.count, 1, "Same-tab installs should collapse to newest pending policy")
		XCTAssertEqual(agentModePolicies.first?.tabID, tabID)
		XCTAssertEqual(agentModePolicies.first?.runID, replacementRunID)
	}

	func testInstallClientConnectionPolicySeedsRunPolicyStateImmediately() async {
		let manager = ServerNetworkManager()
		let clientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"
		let runID = UUID()
		let windowID = 7

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: windowID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			ttl: 30,
			tabID: UUID(),
			runID: runID,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let hasCachedState = await manager.hasCachedRunPolicyState(for: runID)
		XCTAssertTrue(hasCachedState)
		let cachedWindowID = await manager.cachedRunPolicyWindowID(for: runID)
		XCTAssertEqual(cachedWindowID, windowID)
		let cachedState = await manager.debugRunPolicyState(for: runID)
		XCTAssertEqual(cachedState?.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(cachedState?.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
		XCTAssertEqual(cachedState?.purpose, .agentModeRun)
	}

	func testPendingPolicySnapshotMatchesEquivalentClientVariant() async {
		let manager = ServerNetworkManager()
		await manager.installClientConnectionPolicy(
			for: "claude-code",
			windowID: 3,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			additionalTools: AgentModeMCPToolPolicy.claudeNativeGrantedTools,
			purpose: .agentModeRun
		)

		let snapshot = await manager.debugPendingPolicySnapshot(for: "Claude Code 1.2.3")
		XCTAssertEqual(snapshot.count, 1)
		XCTAssertEqual(snapshot.first?.windowID, 3)
		XCTAssertEqual(snapshot.first?.purpose, .agentModeRun)
	}

	func testApplyPendingPolicyMatchesEquivalentClientVariant() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		await manager.installClientConnectionPolicy(
			for: "claude-code",
			windowID: 5,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			additionalTools: AgentModeMCPToolPolicy.claudeNativeGrantedTools,
			purpose: .agentModeRun
		)

		let state = await manager.debugApplyPendingPolicy(
			clientName: "Claude Code",
			connectionID: connectionID
		)

		XCTAssertEqual(state.windowID, 5)
		XCTAssertEqual(state.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(state.additionalTools, AgentModeMCPToolPolicy.claudeNativeGrantedTools)
		XCTAssertEqual(state.purpose, .agentModeRun)
	}

	func testAppliedRunPolicyRestoresRoleAndGatedToolGrant() async throws {
		let manager = ServerNetworkManager()
		let clientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"
		let connectionID = UUID()
		let runID = UUID()
		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 5,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			tabID: UUID(),
			runID: runID,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun,
			taskLabelKind: .pair,
			allowsAgentExternalControlTools: false
		)

		let applied = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: connectionID
		)
		XCTAssertEqual(applied.windowID, 5)
		XCTAssertEqual(applied.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(applied.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
		XCTAssertEqual(applied.purpose, .agentModeRun)

		let effective = await manager.debugEffectivePolicyState(for: connectionID)
		XCTAssertEqual(effective.purpose, .agentModeRun)
		XCTAssertEqual(effective.taskLabelKind, .pair)
		XCTAssertTrue(effective.additionalTools.contains("set_status"))

		XCTAssertTrue(MCPPolicyGatedTools.names.contains("set_status"))
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
			toolName: "agent_explore",
			taskLabelKind: effective.taskLabelKind,
			allowsAgentExternalControlTools: false
		))
		XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
			toolName: "agent_run",
			taskLabelKind: effective.taskLabelKind,
			allowsAgentExternalControlTools: false
		))

		await manager.debugSetAdditionalTools(for: connectionID, additionalTools: nil)
		let withoutAdditional = await manager.debugEffectivePolicyState(for: connectionID)
		XCTAssertEqual(withoutAdditional.taskLabelKind, .pair)
		XCTAssertFalse(withoutAdditional.additionalTools.contains("set_status"), "Policy-gated tools require the per-connection applied additionalTools grant")
	}

	func testPIDGatedPendingPolicyDoesNotRouteMismatchedPeer() async {
		let manager = ServerNetworkManager()
		let clientName = "gemini-cli"
		let runID = UUID()
		let connectionID = UUID()
		let expectedPID = pid_t.max - 1

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 9,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			runID: runID,
			additionalTools: AgentModeMCPToolPolicy.geminiGrantedTools,
			purpose: .agentModeRun,
			requiresExpectedAgentPID: true
		)
		await manager.registerExpectedAgentPID(expectedPID, for: clientName, runID: runID)

		let state = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: connectionID,
			clientPid: Int(getpid()),
			bootstrapClientName: clientName
		)

		XCTAssertNil(state.windowID)
		XCTAssertTrue(state.restrictedTools.isEmpty)
		XCTAssertTrue(state.additionalTools.isEmpty)
		XCTAssertEqual(state.purpose, .unknown)

		let snapshot = await manager.debugPendingPolicySnapshot(for: clientName)
		XCTAssertEqual(snapshot.count, 1, "Mismatched clients must not consume the queued ACP policy")
		XCTAssertEqual(snapshot.first?.runID, runID)
	}

	func testPIDGatedPendingPolicyRoutesMatchingPeer() async {
		let manager = ServerNetworkManager()
		let clientName = "gemini-cli"
		let runID = UUID()
		let connectionID = UUID()
		let peerPID = getpid()

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 9,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			runID: runID,
			additionalTools: AgentModeMCPToolPolicy.geminiGrantedTools,
			purpose: .agentModeRun,
			requiresExpectedAgentPID: true
		)
		await manager.registerExpectedAgentPID(peerPID, for: clientName, runID: runID)

		let state = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: connectionID,
			clientPid: Int(peerPID),
			bootstrapClientName: clientName
		)

		XCTAssertEqual(state.windowID, 9)
		XCTAssertEqual(state.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(state.additionalTools, AgentModeMCPToolPolicy.geminiGrantedTools)
		XCTAssertEqual(state.purpose, .agentModeRun)

		let snapshot = await manager.debugPendingPolicySnapshot(for: clientName)
		XCTAssertTrue(snapshot.isEmpty, "The matching peer should consume the one-shot policy")
	}

	func testPIDGatedPendingPolicyRoutesMatchingRunWhenSameClientHasOlderPolicy() async {
		let manager = ServerNetworkManager()
		let clientName = "gemini-cli"
		let olderRunID = UUID()
		let matchingRunID = UUID()
		let connectionID = UUID()
		let peerPID = getpid()

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 9,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			runID: olderRunID,
			additionalTools: AgentModeMCPToolPolicy.geminiGrantedTools,
			purpose: .agentModeRun,
			requiresExpectedAgentPID: true
		)
		await manager.registerExpectedAgentPID(pid_t.max - 1, for: clientName, runID: olderRunID)
		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 10,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			runID: matchingRunID,
			additionalTools: AgentModeMCPToolPolicy.geminiGrantedTools,
			purpose: .agentModeRun,
			requiresExpectedAgentPID: true
		)
		await manager.registerExpectedAgentPID(peerPID, for: clientName, runID: matchingRunID)

		let state = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: connectionID,
			clientPid: Int(peerPID),
			bootstrapClientName: clientName
		)

		XCTAssertEqual(state.windowID, 10)
		XCTAssertEqual(state.purpose, .agentModeRun)

		let snapshot = await manager.debugPendingPolicySnapshot(for: clientName)
		XCTAssertEqual(snapshot.count, 1)
		XCTAssertEqual(snapshot.first?.runID, olderRunID)
	}

	func testGeminiReconnectFromExpectedPIDAdmittedAfterOneShotPolicyConsumed() async {
		let manager = ServerNetworkManager()
		let clientName = "gemini-cli-mcp-client"
		let runID = UUID()
		let firstConnectionID = UUID()
		let reconnectConnectionID = UUID()
		let peerPID = getpid()

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 12,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			runID: runID,
			additionalTools: AgentModeMCPToolPolicy.geminiGrantedTools,
			purpose: .agentModeRun,
			requiresExpectedAgentPID: true
		)
		await manager.registerExpectedAgentPID(peerPID, for: clientName, runID: runID)

		let firstState = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: firstConnectionID,
			clientPid: Int(peerPID),
			bootstrapClientName: clientName
		)
		XCTAssertEqual(firstState.windowID, 12)
		let snapshotAfterFirstConnection = await manager.debugPendingPolicySnapshot(for: clientName)
		XCTAssertTrue(snapshotAfterFirstConnection.isEmpty)

		let admission = await manager.debugAgentPolicyAdmissionStatus(
			clientName: clientName,
			connectionID: reconnectConnectionID,
			sessionKey: "new-gemini-bootstrap-token",
			clientPid: Int(peerPID),
			timeout: 0.01
		)
		XCTAssertEqual(admission, "ready")

		let reconnectState = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: reconnectConnectionID,
			clientPid: Int(peerPID),
			bootstrapClientName: clientName
		)
		XCTAssertEqual(reconnectState.windowID, 12)
		XCTAssertEqual(reconnectState.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(reconnectState.additionalTools, AgentModeMCPToolPolicy.geminiGrantedTools)
		XCTAssertEqual(reconnectState.purpose, .agentModeRun)
	}

	func testGeminiReconnectFromUnexpectedPIDDoesNotInheritConsumedPolicy() async {
		let manager = ServerNetworkManager()
		let clientName = "gemini-cli-mcp-client"
		let runID = UUID()
		let firstConnectionID = UUID()
		let reconnectConnectionID = UUID()
		let peerPID = getpid()

		await manager.installClientConnectionPolicy(
			for: clientName,
			windowID: 12,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			oneShot: true,
			reason: "agent-mode-run",
			runID: runID,
			additionalTools: AgentModeMCPToolPolicy.geminiGrantedTools,
			purpose: .agentModeRun,
			requiresExpectedAgentPID: true
		)
		await manager.registerExpectedAgentPID(peerPID, for: clientName, runID: runID)

		_ = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: firstConnectionID,
			clientPid: Int(peerPID),
			bootstrapClientName: clientName
		)
		let snapshotAfterFirstConnection = await manager.debugPendingPolicySnapshot(for: clientName)
		XCTAssertTrue(snapshotAfterFirstConnection.isEmpty)

		let reconnectState = await manager.debugApplyPendingPolicy(
			clientName: clientName,
			connectionID: reconnectConnectionID,
			clientPid: Int(pid_t.max - 1),
			bootstrapClientName: clientName
		)
		XCTAssertNil(reconnectState.windowID)
		XCTAssertTrue(reconnectState.restrictedTools.isEmpty)
		XCTAssertTrue(reconnectState.additionalTools.isEmpty)
		XCTAssertEqual(reconnectState.purpose, .unknown)
	}

	func testRunPolicySeedingUsesTimestampPrecedence() async {
		let manager = ServerNetworkManager()
		let runID = UUID()
		let older = Date(timeIntervalSince1970: 100)
		let newer = Date(timeIntervalSince1970: 200)
		let newest = Date(timeIntervalSince1970: 300)

		await manager.debugSeedRunPolicyState(
			runID: runID,
			windowID: 11,
			restrictedTools: ["older"],
			additionalTools: ["older-extra"],
			purpose: .discoverRun,
			updatedAt: newer
		)
		await manager.debugSeedRunPolicyState(
			runID: runID,
			windowID: 12,
			restrictedTools: ["stale"],
			additionalTools: ["stale-extra"],
			purpose: .agentModeRun,
			updatedAt: older
		)

		let afterStaleSeed = await manager.debugRunPolicyState(for: runID)
		XCTAssertEqual(afterStaleSeed?.windowID, 11)
		XCTAssertEqual(afterStaleSeed?.restrictedTools, ["older"])
		XCTAssertEqual(afterStaleSeed?.additionalTools, ["older-extra"])
		XCTAssertEqual(afterStaleSeed?.purpose, .discoverRun)

		await manager.debugSeedRunPolicyState(
			runID: runID,
			windowID: 13,
			restrictedTools: ["newer"],
			additionalTools: ["newer-extra"],
			purpose: .agentModeRun,
			updatedAt: newest
		)

		let afterNewSeed = await manager.debugRunPolicyState(for: runID)
		XCTAssertEqual(afterNewSeed?.windowID, 13)
		XCTAssertEqual(afterNewSeed?.restrictedTools, ["newer"])
		XCTAssertEqual(afterNewSeed?.additionalTools, ["newer-extra"])
		XCTAssertEqual(afterNewSeed?.purpose, .agentModeRun)
	}

	func testDelegateEditEditFileUsesConnectionMappedRunIDWhenHiddenRunIDMissing() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		let runID = UUID()
		let filePath = "Test.swift"
		let originalContent = """
		func greet() {
		\tprint("Hello")
		}
		"""

		await manager.installDelegateEditSandbox(
			windowID: 1,
			runID: runID,
			allowedPath: filePath,
			originalContent: originalContent
		)
		await manager.debugSeedRunPolicyState(
			runID: runID,
			windowID: 1,
			restrictedTools: DelegateEditMCPToolPolicy.restrictedTools,
			additionalTools: nil,
			purpose: .delegateEditRun
		)
		await manager.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			purpose: .delegateEditRun,
			windowID: 1
		)

		let result = await manager.debugHandleDelegateSandboxToolCall(
			connectionID: connectionID,
			toolName: DelegateEditToolNames.editFile,
			args: [
				"path": MCPTestValue.s(filePath),
				"search": MCPTestValue.s("Hello"),
				"replace": MCPTestValue.s("Hi")
			]
		)

		XCTAssertNotNil(result)
		XCTAssertFalse(result?.isError ?? true)
		let finalContent = await manager.delegateEditFinalContent(for: runID)
		XCTAssertEqual(finalContent?.contains("Hi"), true)
		XCTAssertEqual(finalContent?.contains("Hello"), false)
	}

	func testDelegateEditEditFileUnwrapsEditFileArgumentWrapper() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		let runID = UUID()
		let filePath = "Test.swift"
		let originalContent = "let value = \"old\"\n"
		await manager.installDelegateEditSandbox(
			windowID: 1,
			runID: runID,
			allowedPath: filePath,
			originalContent: originalContent
		)
		await manager.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			purpose: .delegateEditRun,
			windowID: 1
		)

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: [
				DelegateEditToolNames.editFile: .object([
					"path": MCPTestValue.s(filePath),
					"search": MCPTestValue.s("old"),
					"replace": MCPTestValue.s("new")
				])
			],
			originalToolName: DelegateEditToolNames.editFile,
			canonicalToolName: DelegateEditToolNames.editFile
		)
		let result = await manager.debugHandleDelegateSandboxToolCall(
			connectionID: connectionID,
			toolName: DelegateEditToolNames.editFile,
			args: normalized.payload
		)

		XCTAssertNotNil(result)
		XCTAssertFalse(result?.isError ?? true)
		let finalContent = await manager.delegateEditFinalContent(for: runID)
		XCTAssertEqual(finalContent, "let value = \"new\"\n")
	}

	func testDelegateEditEditFileUsesSurfaceNameInApplyErrors() async {
		let sandbox = DelegateEditSandbox(allowedPath: "Test.swift", original: "original")
		let result = await sandbox.callApplyEdits(
			args: ["path": MCPTestValue.s("Test.swift")],
			surfaceToolName: DelegateEditToolNames.editFile
		)

		XCTAssertTrue(result.isError ?? false)
		let text = CallToolResultJSON.textBody(result) ?? ""
		XCTAssertTrue(text.hasPrefix("\(DelegateEditToolNames.editFile):"), text)
		XCTAssertFalse(text.hasPrefix("apply_edits:"), text)
	}

	func testDelegateEditEditFileRejectsWhenRoutingCannotResolveSandboxOutsideDelegateContext() async {
		let manager = ServerNetworkManager()
		let result = await manager.debugHandleDelegateSandboxToolCall(
			connectionID: UUID(),
			toolName: DelegateEditToolNames.editFile,
			args: [
				"path": MCPTestValue.s("Test.swift"),
				"rewrite": MCPTestValue.s("updated")
			]
		)

		XCTAssertNotNil(result)
		XCTAssertTrue(result?.isError ?? false)
		XCTAssertEqual(
			CallToolResultJSON.textBody(result!),
			"Delegate edit tool '\(DelegateEditToolNames.editFile)' could not resolve sandbox routing for this connection."
		)
	}

	func testDelegateSandboxRoutingIgnoresNormalReadAndSearchOutsideDelegateContext() async {
		let manager = ServerNetworkManager()
		for (toolName, args) in [
			(DelegateEditToolNames.readFile, ["start_line": MCPTestValue.i(1)]),
			(DelegateEditToolNames.fileSearch, ["pattern": MCPTestValue.s("needle")])
		] {
			let result = await manager.debugHandleDelegateSandboxToolCall(
				connectionID: UUID(),
				toolName: toolName,
				args: args
			)
			XCTAssertNil(result, "Normal \(toolName) should continue through the live MCP path outside delegate edit context")
		}
	}

	func testDelegateSandboxRoutingIgnoresReadAndSearchForStaleNonDelegateSandboxMapping() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		let runID = UUID()
		await manager.installDelegateEditSandbox(
			windowID: 1,
			runID: runID,
			allowedPath: "Test.swift",
			originalContent: "needle\n"
		)
		await manager.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			purpose: .unknown,
			windowID: 1
		)

		for (toolName, args) in [
			(DelegateEditToolNames.readFile, ["start_line": MCPTestValue.i(1)]),
			(DelegateEditToolNames.fileSearch, ["pattern": MCPTestValue.s("needle")])
		] {
			let result = await manager.debugHandleDelegateSandboxToolCall(
				connectionID: connectionID,
				toolName: toolName,
				args: args
			)
			XCTAssertNil(result, "Stale non-delegate sandbox routing must not capture normal \(toolName)")
		}
	}


	func testLiveRunAffinityRestoreBlockedWhenNoCachedPolicy_agentModePurpose() async {
		let manager = ServerNetworkManager()
		let shouldRestore = await manager.debugCanRestoreLiveRunAffinity(hasCachedPolicy: false)
		XCTAssertFalse(shouldRestore)
	}

	func testLiveRunAffinityRestoreBlockedWhenNoCachedPolicy_discoverPurpose() async {
		let manager = ServerNetworkManager()
		let shouldRestore = await manager.debugCanRestoreLiveRunAffinity(hasCachedPolicy: false)
		XCTAssertFalse(shouldRestore)
	}

	func testLiveRunAffinityRestoreBlockedWhenNoCachedPolicy_unknownPurpose() async {
		let manager = ServerNetworkManager()
		let shouldRestore = await manager.debugCanRestoreLiveRunAffinity(hasCachedPolicy: false)
		XCTAssertFalse(shouldRestore)
	}

	func testLiveRunAffinityRestoreAllowedWhenCachedPolicyExists() async {
		let manager = ServerNetworkManager()
		let shouldRestore = await manager.debugCanRestoreLiveRunAffinity(hasCachedPolicy: true)
		XCTAssertTrue(shouldRestore)
	}

	func testValidatedLiveRunIDRejectsReverseOnlyMapping() {
		let connectionID = UUID()
		let runID = UUID()

		let resolved = ServerNetworkManager.test_validatedLiveRunID(
			candidateRunID: runID,
			connectionID: connectionID,
			connectionIDByRunID: [:],
			connectionIDToRunID: [connectionID: runID]
		)

		XCTAssertNil(resolved)
	}

	func testValidatedLiveRunIDAcceptsBidirectionalLiveMapping() {
		let connectionID = UUID()
		let runID = UUID()

		let resolved = ServerNetworkManager.test_validatedLiveRunID(
			candidateRunID: runID,
			connectionID: connectionID,
			connectionIDByRunID: [runID: connectionID],
			connectionIDToRunID: [connectionID: runID]
		)

		XCTAssertEqual(resolved, runID)
	}

	func testPersistedAgentModePolicyRestoreDoesNotHydrateWithoutCachedRunPolicy() async {
		let manager = ServerNetworkManager()
		let restored = await manager.debugRestorePersistedAgentModePolicy(
			clientName: DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client",
			connectionID: UUID(),
			windowID: 1,
			runID: UUID(),
			runPurpose: .agentModeRun
		)

		XCTAssertFalse(restored.didRestore)
		XCTAssertTrue(restored.restrictedTools.isEmpty)
		XCTAssertTrue(restored.additionalTools.isEmpty)
		XCTAssertEqual(restored.purpose, .unknown)
	}

	func testPersistedAgentModePolicyRestoreHydratesFromCachedRunPolicyWhenPurposeUnknown() async {
		let manager = ServerNetworkManager()
		let clientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"
		let connectionID = UUID()
		let runID = UUID()
		await manager.debugSeedRunPolicyState(
			runID: runID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let restored = await manager.debugRestorePersistedAgentModePolicy(
			clientName: clientName,
			connectionID: connectionID,
			windowID: 1,
			runID: runID,
			runPurpose: .unknown
		)

		XCTAssertTrue(restored.didRestore)
		XCTAssertEqual(restored.purpose, .agentModeRun)
		XCTAssertEqual(restored.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(restored.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
		XCTAssertEqual(restored.cachedPolicyPurpose, .agentModeRun)
	}

	func testPersistedAgentModePolicyRestoreBlockedForUnknownClientWhenCachedPurposeIsAgentMode() async {
		let manager = ServerNetworkManager()
		let runID = UUID()
		await manager.debugSeedRunPolicyState(
			runID: runID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let restored = await manager.debugRestorePersistedAgentModePolicy(
			clientName: "unknown-mcp-client",
			connectionID: UUID(),
			windowID: 1,
			runID: runID,
			runPurpose: .unknown
		)

		XCTAssertFalse(restored.didRestore)
		XCTAssertTrue(restored.restrictedTools.isEmpty)
		XCTAssertTrue(restored.additionalTools.isEmpty)
		XCTAssertEqual(restored.purpose, .unknown)
	}

	func testEffectivePolicyStateDoesNotInferAgentModeToolsFromPurposeOnly() async {
		let manager = ServerNetworkManager()
		let connectionID = UUID()
		await manager.setRunPurpose(.agentModeRun, for: connectionID)

		let effective = await manager.debugEffectivePolicyState(for: connectionID)
		XCTAssertEqual(effective.purpose, .agentModeRun)
		XCTAssertTrue(effective.restrictedTools.isEmpty)
		XCTAssertTrue(effective.additionalTools.isEmpty)
	}

	func testLiveRunAffinityRestoreHelperDependsOnlyOnCachedPolicyState() async {
		let manager = ServerNetworkManager()
		let blocked = await manager.debugCanRestoreLiveRunAffinity(hasCachedPolicy: false)
		let allowed = await manager.debugCanRestoreLiveRunAffinity(hasCachedPolicy: true)
		XCTAssertFalse(blocked)
		XCTAssertTrue(allowed)
	}

	func testDelegateEditPolicyRestrictsLiveApplyEditsButNotEditFileAlias() {
		XCTAssertTrue(DelegateEditMCPToolPolicy.restrictedTools.contains("apply_edits"))
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: "apply_edits").contains(.fileContentEdit))
		XCTAssertFalse(DelegateEditMCPToolPolicy.restrictedTools.contains(DelegateEditToolNames.editFile))
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: DelegateEditToolNames.editFile).isEmpty)
	}

	func testDelegateEditPromptRequiresEditFileWithoutMentioningLiveApplyEdits() {
		let prompt = SystemPromptService.mcpDelegateEditPrompt(filePath: "Test.swift", changes: [])

		XCTAssertTrue(prompt.contains(DelegateEditToolNames.editFile))
		XCTAssertTrue(prompt.contains("Use \(DelegateEditToolNames.editFile) for every edit"))
		XCTAssertFalse(prompt.contains("apply_edits"))
	}

	func testDelegateEditMCPInstructionsAdvertiseEditFileWithoutMentioningLiveApplyEdits() {
		let instructions = RepoPromptMCPInstructions.text(for: .delegateEditRun)

		XCTAssertTrue(instructions.contains(DelegateEditToolNames.editFile))
		XCTAssertFalse(instructions.contains("apply_edits"))
	}

	func testCodeMapsDisabledMCPInstructionsOmitGetCodeStructure() {
		for purpose in [MCPRunPurpose.agentModeRun, .discoverRun, .unknown] {
			let enabled = RepoPromptMCPInstructions.text(for: purpose, codeMapsDisabled: false)
			let disabled = RepoPromptMCPInstructions.text(for: purpose, codeMapsDisabled: true)

			XCTAssertTrue(enabled.contains("get_code_structure"), "Enabled instructions for \(purpose) should advertise get_code_structure")
			XCTAssertFalse(disabled.contains("get_code_structure"), "Disabled instructions for \(purpose) should omit get_code_structure")
			XCTAssertTrue(disabled.contains("Code Maps are globally disabled"))
		}
	}

	@MainActor
	func testToolAvailabilityGlobalSuppressionNames() {
		XCTAssertEqual(ToolAvailabilityStore.suppressedToolNames(codeMapsGloballyDisabled: false), Set<String>())
		XCTAssertEqual(ToolAvailabilityStore.suppressedToolNames(codeMapsGloballyDisabled: true), ["get_code_structure"])
	}

	func testCapabilityBasedPolicyMappingIncludesSetStatusControls() {
		XCTAssertEqual(MCPToolCapabilities.toolNames(for: [.agentSessionControl]), ["set_status"])
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: "set_status").contains(.agentSessionControl))
		XCTAssertTrue(MCPPolicyGatedTools.names.contains("set_status"))
		XCTAssertTrue(AgentModeMCPToolPolicy.grantedTools.contains("set_status"))
		XCTAssertTrue(AgentModeMCPToolPolicy.codexNativeGrantedTools.contains("set_status"))
		XCTAssertTrue(AgentModeMCPToolPolicy.claudeNativeGrantedTools.contains("set_status"))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("set_status"))
		XCTAssertTrue(DelegateEditMCPToolPolicy.restrictedTools.contains("set_status"))
	}

	/// The agent-mode init text is shared across top-level sessions (which see
	/// `agent_run` / `agent_manage`) and non-explore sub-agents (which see
	/// `agent_explore` instead). Naming either delegation tool would violate the
	/// invariant for the other audience, so the shared text must be tool-agnostic and
	/// defer to the system prompt. Discover / delegate-edit surfaces have no
	/// delegation at all.
	func testAgentModeMCPInstructionsDoNotNameSpecificDelegationTool() {
		let agentMode = RepoPromptMCPInstructions.text(for: .agentModeRun)
		let discover = RepoPromptMCPInstructions.text(for: .discoverRun)
		let delegateEdit = RepoPromptMCPInstructions.text(for: .delegateEditRun)

		XCTAssertTrue(agentMode.contains("system prompt lists the delegation tool"))
		XCTAssertFalse(
			agentMode.contains("agent_run"),
			"Shared .agentModeRun init text must not name agent_run — non-explore sub-agents do not see it"
		)
		XCTAssertFalse(
			agentMode.contains("agent_manage"),
			"Shared .agentModeRun init text must not name agent_manage — non-explore sub-agents do not see it"
		)
		XCTAssertFalse(
			agentMode.contains("agent_explore"),
			"Shared .agentModeRun init text must not name agent_explore — top-level sessions do not see it"
		)
		// Discover / delegate-edit surfaces have no delegation or export handoff.
		XCTAssertFalse(discover.contains("agent_explore"))
		XCTAssertFalse(discover.contains("oracle_export_path"))
		XCTAssertFalse(delegateEdit.contains("agent_explore"))
		XCTAssertFalse(delegateEdit.contains("oracle_export_path"))
	}

	/// Agent-mode instructions must describe the export handoff shape
	/// (`oracle_export_path` + `oracle_export_instruction`) without naming a specific
	/// delegation tool, since the same text is shared by top-level sessions and
	/// non-explore sub-agents. The external MCP text always has `agent_run` and may
	/// name it.
	func testAgentModeMCPInstructionsDescribeExportHandoffToolAgnostically() {
		let agentMode = RepoPromptMCPInstructions.text(for: .agentModeRun)
		let externalMCP = RepoPromptMCPInstructions.text(for: .unknown)

		for text in [agentMode, externalMCP] {
			XCTAssertTrue(text.contains("oracle_export_path"))
			XCTAssertTrue(text.contains("oracle_export_instruction"))
			XCTAssertTrue(text.contains("`read_file`"))
		}
		// External MCP clients always see `agent_run`; the external init text may
		// name it directly.
		XCTAssertTrue(externalMCP.contains("agent_run"))
		// The shared agent-mode init text defers tool naming to the system prompt.
		XCTAssertTrue(agentMode.contains("your next delegation call"))
	}

	func testAgentExploreToolCardDisplayAndCategory() {
		XCTAssertTrue(ToolCardRouter.knownResultTools.contains("agent_explore"))
		XCTAssertEqual(toolIcon(for: "agent_explore"), "magnifyingglass.circle")
		XCTAssertEqual(toolDisplayName(for: "agent_explore"), "Agent Explore")
		XCTAssertEqual(
			ClusterToolCategory.classification(forNormalizedToolName: "agent_explore").family,
			.agentControl
		)
		XCTAssertEqual(
			ClusterToolCategory.classification(forNormalizedToolName: "agent_run").family,
			.agentControl
		)
		XCTAssertEqual(
			ClusterToolCategory.classification(forNormalizedToolName: "agent_manage").family,
			.agentControl
		)
		XCTAssertEqual(
			ToolCardRouter.callSubtitle(
				for: "agent_explore",
				argsJSON: #"{"op":"wait","session_id":"abc","timeout":30}"#
			),
			"wait • abc • wait ≤30s"
		)
		XCTAssertEqual(
			ToolCardRouter.callSubtitle(
				for: "agent_explore",
				argsJSON: #"{"op":"cancel","session_ids":["abc","def"]}"#
			),
			"cancel"
		)
		XCTAssertEqual(
			ToolCardRouter.callSubtitle(
				for: "agent_explore",
				argsJSON: #"{"op":"start","messages":["map services","inspect tests"],"detach":true}"#
			),
			"start • 2 probes • detach"
		)
	}

	func testCapabilityBasedPolicyMappingIncludesAgentExternalControlTools() {
		XCTAssertEqual(MCPToolCapabilities.toolNames(for: [.agentExternalControl]), ["agent_manage", "agent_run"])
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: "agent_run").contains(.agentExternalControl))
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: "agent_manage").contains(.agentExternalControl))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("agent_run"))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("agent_manage"))
		XCTAssertTrue(DelegateEditMCPToolPolicy.restrictedTools.contains("agent_run"))
		XCTAssertTrue(DelegateEditMCPToolPolicy.restrictedTools.contains("agent_manage"))
		XCTAssertFalse(MCPPolicyGatedTools.names.contains("agent_run"))
		XCTAssertFalse(MCPPolicyGatedTools.names.contains("agent_manage"))
		XCTAssertFalse(AgentModeMCPToolPolicy.grantedTools.contains("agent_run"))
		XCTAssertFalse(AgentModeMCPToolPolicy.grantedTools.contains("agent_manage"))
		XCTAssertFalse(AgentModeMCPToolPolicy.codexNativeGrantedTools.contains("agent_run"))
		XCTAssertFalse(AgentModeMCPToolPolicy.codexNativeGrantedTools.contains("agent_manage"))
		XCTAssertFalse(AgentModeMCPToolPolicy.claudeNativeGrantedTools.contains("agent_run"))
		XCTAssertFalse(AgentModeMCPToolPolicy.claudeNativeGrantedTools.contains("agent_manage"))
	}

	func testCapabilityBasedPolicyMappingIncludesAgentExploreControlTool() {
		XCTAssertEqual(MCPToolCapabilities.toolNames(for: [.agentExploreControl]), ["agent_explore"])
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: "agent_explore").contains(.agentExploreControl))
		XCTAssertFalse(MCPToolCapabilities.capabilities(for: "agent_explore").contains(.agentExternalControl))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("agent_explore"))
		XCTAssertTrue(DelegateEditMCPToolPolicy.restrictedTools.contains("agent_explore"))
		XCTAssertFalse(AgentModeMCPToolPolicy.restrictedTools.contains("agent_explore"))
		XCTAssertFalse(AgentModeMCPToolPolicy.grantedTools.contains("agent_explore"))
		XCTAssertFalse(MCPPolicyGatedTools.names.contains("agent_explore"))
	}

	func testAgentModeMCPToolAdvertisementAllowsTopLevelNonExploreAgentControlToolsOnly() {
		XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
			toolName: "agent_run",
			taskLabelKind: .pair
		))
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
			toolName: "agent_run",
			taskLabelKind: .pair,
			allowsAgentExternalControlTools: true
		))
		XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
			toolName: "agent_run",
			taskLabelKind: .explore,
			allowsAgentExternalControlTools: true
		))
	}

	func testAgentModeMCPToolAdvertisementShowsAgentExploreOnlyToNonExploreRoles() {
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.hiddenToolNames(for: nil).contains("agent_explore"))
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.hiddenToolNames(for: .explore).contains("agent_explore"))
		XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.hiddenToolNames(for: .engineer).contains("agent_explore"))
		XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "agent_explore", taskLabelKind: nil))
		XCTAssertFalse(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
			toolName: "agent_explore",
			taskLabelKind: .explore,
			allowsAgentExternalControlTools: true
		))
		for kind in [AgentModelCatalog.TaskLabelKind.engineer, .pair, .design] {
			XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "agent_explore", taskLabelKind: kind))
			XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
				toolName: "agent_explore",
				taskLabelKind: kind,
				allowsAgentExternalControlTools: false
			))
		}
	}

	func testAgentModePromptIncludesSetStatusSessionStartGuidance() {
		let prompt = SystemPromptService.agentModePrompt()
		XCTAssertTrue(prompt.contains("`set_status`"))
		XCTAssertTrue(prompt.contains("At session start"))
		XCTAssertTrue(prompt.contains("session_name"))
		XCTAssertFalse(prompt.contains("running_text"))
	}

	func testClaudeAgentModePromptIncludesSetStatusGuidanceWhenWaitAndShareToolsDisabled() {
		let prompt = SystemPromptService.agentModePrompt(agentKind: .claudeCode)
		XCTAssertTrue(prompt.contains("`set_status`"))
		XCTAssertTrue(prompt.contains("At session start"))
		XCTAssertTrue(prompt.contains("session_name"))
		XCTAssertFalse(prompt.contains("running_text"))
	}

	func testAgentModeToolPoliciesKeepAgentOracleLogSeparateFromLiveOracleUtils() {
		XCTAssertTrue(MCPPolicyGatedTools.names.contains("oracle_chat_log"))
		XCTAssertTrue(AgentModeMCPToolPolicy.grantedTools.contains("oracle_chat_log"))
		XCTAssertTrue(AgentModeMCPToolPolicy.restrictedTools.contains("oracle_utils"))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("oracle_utils"))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("ask_oracle"))
	}

	func testAppSettingsVisibleForAgentModeButStillRestrictedForDiscoveryRuns() {
		XCTAssertTrue(MCPToolCapabilities.capabilities(for: "app_settings").contains(.appSettings))
		XCTAssertFalse(AgentModeMCPToolPolicy.restrictedTools.contains("app_settings"))
		XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("app_settings"))
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "app_settings", taskLabelKind: nil))
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "app_settings", taskLabelKind: .explore))
		XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "app_settings", taskLabelKind: .engineer))
	}

	func testAgentModePromptIncludesOracleChatLogCompactionGuidance() {
		let prompt = SystemPromptService.agentModePrompt()
		XCTAssertTrue(prompt.contains("`oracle_chat_log`"))
		XCTAssertTrue(prompt.contains("After compaction"))
		XCTAssertFalse(prompt.contains("`oracle_utils` - Oracle helpers"))
	}

	func testAgentModePromptIncludesClaudeReadPolicyGuidance() {
		let prompt = SystemPromptService.agentModePrompt(agentKind: .claudeCode)
		XCTAssertTrue(prompt.contains("Read policy (important)"))
		XCTAssertTrue(prompt.contains("native `Read` tool"))
		XCTAssertTrue(prompt.contains("@path/to/file.png"))
		XCTAssertTrue(prompt.contains("ALWAYS open those paths with the native `Read` tool"))
		XCTAssertTrue(prompt.contains("For text-based reads"))
		XCTAssertTrue(prompt.contains("MCP `RepoPrompt__read_file`"))
	}

	func testAgentModePromptIncludesReadPolicyGuidanceForGemini() {
		let prompt = SystemPromptService.agentModePrompt(agentKind: .gemini)
		XCTAssertTrue(prompt.contains("Read policy (important)"))
		XCTAssertTrue(prompt.contains("Gemini's native `read_file` tool"))
		XCTAssertTrue(prompt.contains("MCP `RepoPrompt__read_file`"))
		XCTAssertFalse(prompt.contains("read_file / RepoPrompt__read_file"))
	}

	func testAgentModePromptOmitsReadPolicyForNonClaudeOrGeminiAgents() {
		let prompt = SystemPromptService.agentModePrompt(agentKind: .codexExec)
		XCTAssertFalse(prompt.contains("Read policy (important)"))
		XCTAssertFalse(prompt.contains("native `Read` tool"))
		XCTAssertFalse(prompt.contains("Gemini's native `read_file` tool"))
	}

	func testCodexAgentModePromptTreatsExpandedSkillContentAsAlreadyProvidedContext() {
		let prompt = SystemPromptService.agentModePrompt(agentKind: .codexExec)
		XCTAssertTrue(prompt.contains("embedded skill content as already-provided context"))
		XCTAssertFalse(prompt.contains("such as reading a global skill file"))
	}

	func testOracleChatLogFormatterRendersMetadataAndMessages() {
		let args: [String: Value] = ["include_user": .bool(true)]
		let value: Value = .object([
			"chat_id": .string("chat-123"),
			"messages": .array([
				.object(["role": .string("assistant"), "text": .string("Plan drafted")]),
				.object(["role": .string("user"), "text": .string("Looks good")])
			])
		])

		let blocks = ToolOutputFormatter.formatOracleChatLog(args: args, value: value, emitResources: false)
		guard let first = blocks.first, case .text(let text, _, _) = first else {
			return XCTFail("Expected text content block")
		}

		XCTAssertTrue(text.contains("Oracle Chat Log"))
		XCTAssertTrue(text.contains("`chat-123`"))
		XCTAssertTrue(text.contains("Messages**: 2"))
		XCTAssertTrue(text.contains("Includes user messages**: yes"))
		XCTAssertTrue(text.contains("Message #1 — assistant"))
		XCTAssertTrue(text.contains("Message #2 — user"))
	}

	func testContextBuilderDTODecodesLegacyMinimalPayload() throws {
		let data = try XCTUnwrap("""
		{
		  "status": "completed",
		  "message": "ok",
		  "summary": "done"
		}
		""".data(using: .utf8))
		let decoder = JSONDecoder()
		let dto = try decoder.decode(ToolResultDTOs.ContextBuilderDTO.self, from: data)

		XCTAssertEqual(dto.status, "completed")
		XCTAssertEqual(dto.message, "ok")
		XCTAssertEqual(dto.summary, "done")
		XCTAssertNil(dto.tabID)
		XCTAssertNil(dto.prompt)
		XCTAssertNil(dto.selection)
		XCTAssertNil(dto.responseType)
	}

	func testContextBuilderFollowUpChatIDUsesResponseTypeWhenBothBranchesExist() throws {
		let reviewPayload = try XCTUnwrap(#"""
		{
		"status": "completed",
		"response_type": "review",
		"plan": { "chat_id": "plan-chat", "mode": "plan" },
		"review": { "chat_id": "review-chat", "mode": "review" }
		}
		"""#.data(using: .utf8))
		let planPayload = try XCTUnwrap(#"""
		{
		"status": "completed",
		"response_type": "plan",
		"plan": { "chat_id": "plan-chat", "mode": "plan" },
		"review": { "chat_id": "review-chat", "mode": "review" }
		}
		"""#.data(using: .utf8))

		let decoder = JSONDecoder()
		let reviewDTO = try decoder.decode(ToolResultDTOs.ContextBuilderDTO.self, from: reviewPayload)
		let planDTO = try decoder.decode(ToolResultDTOs.ContextBuilderDTO.self, from: planPayload)

		XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "review-chat")
		XCTAssertEqual(contextBuilderFollowUpChatID(for: planDTO), "plan-chat")
	}

	func testContextBuilderFollowUpChatIDPreservesLegacyPlanFirstFallback() throws {
		let payload = try XCTUnwrap(#"""
		{
		"status": "completed",
		"plan": { "chat_id": "plan-chat", "mode": "plan" },
		"review": { "chat_id": "review-chat", "mode": "review" }
		}
		"""#.data(using: .utf8))
		let dto = try JSONDecoder().decode(ToolResultDTOs.ContextBuilderDTO.self, from: payload)

		XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "plan-chat")
	}

	func testContextBuilderOraclePopoverUserInfoIncludesFollowUpChatID() {
		let tabID = UUID()
		let openContext = AgentOracleOpenContext(windowID: 42, tabID: tabID, chatID: "fallback-chat")

		let userInfo = contextBuilderOraclePopoverUserInfo(
			openContext: openContext,
			chatID: "current-follow-up-chat"
		)

		XCTAssertEqual(userInfo["windowID"] as? Int, 42)
		XCTAssertEqual(userInfo["tabID"] as? UUID, tabID)
		XCTAssertEqual(userInfo["chatID"] as? String, "current-follow-up-chat")
	}

	func testContextBuilderOraclePopoverUserInfoFallsBackToOpenContextChatID() {
		let openContext = AgentOracleOpenContext(windowID: 42, tabID: nil, chatID: "fallback-chat")

		let userInfo = contextBuilderOraclePopoverUserInfo(
			openContext: openContext,
			chatID: nil
		)

		XCTAssertEqual(userInfo["windowID"] as? Int, 42)
		XCTAssertNil(userInfo["tabID"])
		XCTAssertEqual(userInfo["chatID"] as? String, "fallback-chat")
	}

	func testToolJSONDecodeResultUnwrapsStructuredContentEnvelopeForAutoExpandedCards() {
		let wrappedApplyEdits = #"{"structured_content":{"status":"success","edits_requested":1,"edits_applied":1,"card_unified_diff":"@@ -1 +1 @@\n-old\n+new"}}"#
		let wrappedApplyPatch = #"{"structuredContent":{"status":"success","changes":[{"path":"File.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}}"#
		let wrappedPrompt = #"{"structured_content":{"op":"export","export":{"path":"context.txt","tokens":128,"bytes":256,"files":[]}}}"#
		let wrappedContextBuilder = #"{"structuredContent":{"status":"completed","response_type":"review","prompt":"review prompt","review":{"chat_id":"chat-123","mode":"review","response":"Looks good","errors":[]}}}"#

		let editSummary = ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: wrappedApplyEdits)
		let patchSummary = ToolJSON.decode(ToolResultDTOs.ApplyPatchSummary.self, from: wrappedApplyPatch)
		let promptEnvelope = ToolJSON.decode(ToolResultDTOs.PromptToolEnvelope.self, from: wrappedPrompt)
		let contextBuilder = ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: wrappedContextBuilder)

		XCTAssertEqual(editSummary?.editsRequested, 1)
		XCTAssertEqual(editSummary?.editsApplied, 1)
		XCTAssertEqual(patchSummary?.changeCount, 1)
		XCTAssertEqual(patchSummary?.changes.first?.path, "File.swift")
		XCTAssertEqual(promptEnvelope?.op, "export")
		XCTAssertEqual(promptEnvelope?.export?.path, "context.txt")
		XCTAssertEqual(contextBuilder?.status, "completed")
		XCTAssertEqual(contextBuilder?.review?.chatID, "chat-123")
	}

	func testToolResultPayloadSourcePrefersDecodableRawPayload() {
		let item = AgentChatItem.toolResult(
			name: "apply_patch",
			invocationID: UUID(),
			resultJSON: #"{"status":"success","summary_only":true,"changes":[{"path":"File.swift","kind":"update","diff":""}],"change_count":1}"#,
			isError: false,
			sequenceIndex: 0
		)
		let raw = #"{"structuredContent":{"status":"success","changes":[{"path":"File.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}}"#

		let source = ToolJSON.resultPayloadSource(for: item, rawPayload: raw)
		let decoded = ToolJSON.decodeResult(ToolResultDTOs.ApplyPatchSummary.self, from: source)

		XCTAssertTrue(source.hasRawPayload)
		XCTAssertEqual(decoded?.changes.first?.diff, "@@ -1 +1 @@\n-old\n+new")
	}

	func testToolResultPayloadSourceFallsBackToStoredPayloadWhenRawMalformed() {
		let item = AgentChatItem.toolResult(
			name: "prompt",
			invocationID: UUID(),
			resultJSON: #"{"op":"select_preset","selected_preset":{"id":"preset-1","name":"Architect","kind":"architect","is_built_in":true}}"#,
			isError: false,
			sequenceIndex: 0
		)

		let source = ToolJSON.resultPayloadSource(for: item, rawPayload: "{not valid json")
		let decoded = ToolJSON.decodeResult(ToolResultDTOs.PromptToolEnvelope.self, from: source)

		XCTAssertEqual(decoded?.op, "select_preset")
		XCTAssertEqual(decoded?.selectedPreset?.name, "Architect")
	}

	func testPromptResultPayloadExpandableKeepsExportCopyUIAvailableForCompactPayload() {
		let compactExport = #"{"op":"export","summary_only":true,"export":{"path":"context.txt","tokens":128,"bytes":256,"files":[]}}"#
		let compactNonExport = #"{"op":"get","summary_only":true,"prompt":{"lines":2}}"#

		XCTAssertTrue(promptResultPayloadIsExpandable(isExportResult: true, payload: compactExport))
		XCTAssertFalse(promptResultPayloadIsExpandable(isExportResult: false, payload: compactNonExport))
	}

	func testPreferredStructuredResultJSONUnwrapsNestedToolPayloadForMarkdownRendering() {
		let wrappedSearch = #"{"structured_content":{"total_matches":2,"total_files":1,"content_matches":2,"path_matches":0,"limit_hit":false,"per_file_counts":[{"path":"README.md","count":2}],"path_match_lines":[],"content_match_groups":[]}}"#

		let preferredJSON = ToolJSON.preferredStructuredResultJSON(from: wrappedSearch)
		let dto = ToolJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: preferredJSON)

		XCTAssertNotNil(preferredJSON)
		XCTAssertFalse(preferredJSON?.contains("structured_content") == true)
		XCTAssertEqual(dto?.totalMatches, 2)
		XCTAssertEqual(dto?.totalFiles, 1)
	}

	func testPreferredStructuredResultJSONUnwrapsMCPTransportEnvelopeToMarkdownText() {
		let wrappedMarkdown = #"""
		{"Ok":{"content":[{"type":"text","text":"## Search Results ✅\n- **Total matches**: 1"}],"isError":false}}
		"""#

		let preferred = ToolJSON.preferredStructuredResultJSON(from: wrappedMarkdown)

		XCTAssertEqual(preferred, "## Search Results ✅\n- **Total matches**: 1")
	}

	func testPreferredStructuredResultJSONDoesNotStripTopLevelResponseMetadata() {
		let payload = #"{"status":"completed","response":"plan text","chat_id":"chat-123"}"#

		let preferred = ToolJSON.preferredStructuredResultJSON(from: payload)
		let object = preferred.flatMap(Value.objectFromJSONString)

		XCTAssertEqual(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: preferred)?.status, "completed")
		XCTAssertEqual(object?["response"]?.stringValue, "plan text")
		XCTAssertEqual(object?["chat_id"]?.stringValue, "chat-123")
	}
}



// MARK: - Merged from WorkspaceManagerLoadPolicyTests.swift


extension CoreUtilityTests {
	func testLoadableRepoPathsReturnsEmptyForSystemWorkspace() {
		let workspace = WorkspaceModel(
			name: "No Workspace",
			repoPaths: ["/Users/example/Documents/XCode/RepoPrompt"],
			isSystemWorkspace: true
		)

		let loadablePaths = WorkspaceManagerViewModel.loadableRepoPaths(for: workspace)
		XCTAssertTrue(loadablePaths.isEmpty)
	}

	func testLoadableRepoPathsReturnsRepoPathsForRegularWorkspace() {
		let expected = [
			"/Users/example/Documents/XCode/RepoPrompt",
			"/Users/example/Documents/XCode/RepoPrompt/repoprompt-mcp"
		]
		let workspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: expected,
			isSystemWorkspace: false
		)

		let loadablePaths = WorkspaceManagerViewModel.loadableRepoPaths(for: workspace)
		XCTAssertEqual(loadablePaths, expected)
	}

	func testGeminiRuntimeKindDefaultsToHeadless() {
		UserDefaults.standard.removeObject(forKey: "agentMode.geminiACPEnabled")

		XCTAssertEqual(DiscoverAgentKind.gemini.runtimeKind, "headless")
		XCTAssertEqual(DiscoverAgentKind.gemini.acpProviderID, .gemini)
	}

	func testGeminiRuntimeKindStaysHeadlessWhenACPFlagEnabled() {
		UserDefaults.standard.set(true, forKey: "agentMode.geminiACPEnabled")
		defer { UserDefaults.standard.removeObject(forKey: "agentMode.geminiACPEnabled") }

		XCTAssertEqual(DiscoverAgentKind.gemini.runtimeKind, "headless")
		XCTAssertEqual(DiscoverAgentKind.gemini.acpProviderID, .gemini)
	}

	func testGeminiDiscoveryProviderStaysHeadlessWhenACPFlagEnabled() {
		UserDefaults.standard.set(true, forKey: "agentMode.geminiACPEnabled")
		defer { UserDefaults.standard.removeObject(forKey: "agentMode.geminiACPEnabled") }

		let provider = DiscoverAgentService.shared.makeProvider(for: .gemini)
		XCTAssertTrue(provider is GeminiAgentProvider)
	}

	func testCursorDiscoveryProviderUsesACPHeadlessWithRepoPromptMCP() throws {
		let provider = DiscoverAgentService.shared.makeProvider(
			for: .cursor,
			modelString: AgentModel.cursorAuto.rawValue,
			workspacePath: "/tmp/repoprompt-cursor-headless-test"
		)
		let cursorProvider = try XCTUnwrap(provider as? CursorACPHeadlessAgentProvider)

		XCTAssertEqual(cursorProvider.test_config.modelString, AgentModel.cursorAuto.rawValue)
		XCTAssertTrue(cursorProvider.test_config.includeRepoPromptMCPServer)
		XCTAssertTrue(cursorProvider.test_config.cleanupProjectMCPConfig)
		XCTAssertNil(cursorProvider.test_config.sessionModeID)
	}

	func testManageSelectionSliceSetPreservesFullFiles() {
		let fullPath = "/tmp/project/Full.swift"
		let slicePath = "/tmp/project/Slice.swift"
		let base = StoredSelection(
			selectedPaths: [fullPath, slicePath],
			autoCodemapPaths: [],
			slices: [slicePath: [LineRange(start: 1, end: 5)]],
			codemapAutoEnabled: false
		)

		let result = MCPServerViewModel.selectionByApplyingResolvedSliceMutation(
			base: base,
			resolvedSlices: [slicePath: [LineRange(start: 10, end: 20)]],
			mode: .setPaths
		).selection

		XCTAssertEqual(result.selectedPaths, [fullPath, slicePath])
		XCTAssertEqual(result.slices[slicePath], [LineRange(start: 10, end: 20)])
	}

	func testManageSelectionFileScopedSliceReplacementPreservesOtherSlices() {
		let editedPath = "/tmp/project/Edited.swift"
		let otherPath = "/tmp/project/Other.swift"
		let base = StoredSelection(
			selectedPaths: [editedPath, otherPath],
			autoCodemapPaths: [],
			slices: [
				editedPath: [LineRange(start: 1, end: 3)],
				otherPath: [LineRange(start: 40, end: 50)]
			],
			codemapAutoEnabled: false
		)

		let result = MCPServerViewModel.selectionByApplyingResolvedSliceMutation(
			base: base,
			resolvedSlices: [editedPath: [LineRange(start: 5, end: 8)]],
			mode: .setPaths
		).selection

		XCTAssertEqual(result.slices[editedPath], [LineRange(start: 5, end: 8)])
		XCTAssertEqual(result.slices[otherPath], [LineRange(start: 40, end: 50)])
	}

	func testManageSelectionMixedAddPreservesExistingSelection() {
		let fullPath = "/tmp/project/Full.swift"
		let existingSlicePath = "/tmp/project/ExistingSlice.swift"
		let addedSlicePath = "/tmp/project/AddedSlice.swift"
		let base = StoredSelection(
			selectedPaths: [fullPath, existingSlicePath],
			autoCodemapPaths: [],
			slices: [existingSlicePath: [LineRange(start: 1, end: 2)]],
			codemapAutoEnabled: false
		)

		let result = MCPServerViewModel.selectionByApplyingResolvedSliceMutation(
			base: base,
			resolvedSlices: [addedSlicePath: [LineRange(start: 10, end: 12)]],
			mode: .add
		).selection

		XCTAssertEqual(result.selectedPaths, [fullPath, existingSlicePath, addedSlicePath])
		XCTAssertEqual(result.slices[existingSlicePath], [LineRange(start: 1, end: 2)])
		XCTAssertEqual(result.slices[addedSlicePath], [LineRange(start: 10, end: 12)])
	}

	func testManageSelectionModeSlicesRejectsBarePaths() {
		let error = MCPServerViewModel.modeSlicesValidationError(
			selectionPaths: ["/tmp/project/Bare.swift"],
			sliceInputs: [],
			sliceParseErrors: []
		)

		XCTAssertEqual(
			error,
			"mode 'slices' cannot be used with bare paths; add #L line ranges to paths or use the slices array."
		)
	}

	func testManageSelectionModeSlicesSurfacesParseErrorsForEmptyInvalidInput() {
		let error = MCPServerViewModel.modeSlicesValidationError(
			selectionPaths: [],
			sliceInputs: [],
			sliceParseErrors: ["Invalid slice 'abc' for path 'File.swift'"]
		)

		XCTAssertEqual(error, "Invalid slice 'abc' for path 'File.swift'")
	}

	func testManageSelectionModeSlicesRequiresSlicesWhenInputEmpty() {
		let error = MCPServerViewModel.modeSlicesValidationError(
			selectionPaths: [],
			sliceInputs: [],
			sliceParseErrors: []
		)

		XCTAssertEqual(
			error,
			"mode 'slices' requires a non-empty slices array or #L line ranges on paths."
		)
	}

	func testManageSelectionModeSlicesAllowsHashLineParsedPaths() {
		let error = MCPServerViewModel.modeSlicesValidationError(
			selectionPaths: ["/tmp/project/Slice.swift"],
			sliceInputs: [
				.init(path: "/tmp/project/Slice.swift", ranges: [LineRange(start: 3, end: 8)])
			],
			sliceParseErrors: []
		)

		XCTAssertNil(error)
	}

	func testManageSelectionDestructiveFullSetPlanRemainsDestructive() {
		let sliceOnlyPlan = MCPServerViewModel.manageSelectionSetMutationPlan(
			mode: "slices",
			pathCount: 0,
			sliceCount: 1
		)
		let mixedFullSetPlan = MCPServerViewModel.manageSelectionSetMutationPlan(
			mode: "full",
			pathCount: 1,
			sliceCount: 1
		)

		XCTAssertTrue(sliceOnlyPlan.startsFromCurrentSelection)
		XCTAssertTrue(sliceOnlyPlan.usesFileScopedSliceReplacement)
		XCTAssertFalse(sliceOnlyPlan.isDestructivePathSet)
		XCTAssertFalse(mixedFullSetPlan.startsFromCurrentSelection)
		XCTAssertFalse(mixedFullSetPlan.usesFileScopedSliceReplacement)
		XCTAssertTrue(mixedFullSetPlan.isDestructivePathSet)
	}

	func testRepoPromptMCPServerConfigurationSerializesForSettingsAndACP() {
		let config = RepoPromptMCPServerConfiguration(
			name: "RepoPrompt",
			command: "/usr/local/bin/rp",
			args: ["serve", "--stdio"],
			env: [
				.init(name: "FOO", value: "bar")
			]
		)

		let wrappedSettings = config.wrappedSettingsJSONObject
		let settingsServers = wrappedSettings["mcpServers"] as? [String: Any]
		let repoPromptSettings = settingsServers?["RepoPrompt"] as? [String: Any]
		let settingsEnv = repoPromptSettings?["env"] as? [String: String]

		XCTAssertEqual(repoPromptSettings?["command"] as? String, "/usr/local/bin/rp")
		XCTAssertEqual(repoPromptSettings?["args"] as? [String], ["serve", "--stdio"])
		XCTAssertEqual(settingsEnv, ["FOO": "bar"])

		let acpObject = config.acpJSONObject
		let acpEnv = acpObject["env"] as? [[String: String]]

		XCTAssertEqual(acpObject["name"] as? String, "RepoPrompt")
		XCTAssertEqual(acpObject["command"] as? String, "/usr/local/bin/rp")
		XCTAssertEqual(acpObject["args"] as? [String], ["serve", "--stdio"])
		XCTAssertEqual(acpEnv, [["name": "FOO", "value": "bar"]])
	}
}
