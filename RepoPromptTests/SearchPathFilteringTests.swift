import XCTest
@testable import RepoPrompt

final class SearchPathFilteringTests: XCTestCase {
	private func makeSnapshot(
		rel: String,
		full: String,
		root: String,
		display: String? = nil
	) -> FileSearchPathSnapshot {
		FileSearchPathSnapshot(
			standardizedFullPath: full,
			standardizedRelativePath: rel,
			standardizedRootPath: root,
			clientDisplayPath: display ?? rel
		)
	}
	
	private func makeSpec(
		caseInsensitive: Bool = false,
		clauses: [SearchPathClause]
	) -> SearchPathFilterSpec {
		SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: clauses)
	}
	
	func testExactFileMatchRelative() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repo/src/App.swift", root: "/repo"),
			makeSnapshot(rel: "src/Other.swift", full: "/repo/src/Other.swift", root: "/repo")
		]
		let spec = makeSpec(clauses: [.exactFile(absPath: "/repo/src/App.swift", relPath: "src/App.swift", restrictedRootPath: "/repo")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/repo/src/App.swift"])
	}
	
	func testFolderConstraintMatchesDescendants() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repo/src/App.swift", root: "/repo"),
			makeSnapshot(rel: "src/utils/Helper.swift", full: "/repo/src/utils/Helper.swift", root: "/repo"),
			makeSnapshot(rel: "docs/Readme.md", full: "/repo/docs/Readme.md", root: "/repo")
		]
		let spec = makeSpec(clauses: [.exactFolder(absLower: "/repo/src", relLower: "src", restrictedRootPath: "/repo")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, [
			"/repo/src/App.swift",
			"/repo/src/utils/Helper.swift"
		])
	}
	
	func testAliasRestrictedGlobMatchesOnlyThatRoot() {
		let snapshots = [
			makeSnapshot(rel: "Sources/App.swift", full: "/a/Sources/App.swift", root: "/a", display: "RepoA/Sources/App.swift"),
			makeSnapshot(rel: "Sources/App.swift", full: "/b/Sources/App.swift", root: "/b", display: "RepoB/Sources/App.swift")
		]
		let spec = makeSpec(clauses: [.glob(pattern: "**/*.swift", restrictedRootPath: "/a")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/a/Sources/App.swift"])
	}
	
	func testExactFileRestrictionDoesNotLeakAcrossRoots() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repoA/src/App.swift", root: "/repoA", display: "RepoA/src/App.swift"),
			makeSnapshot(rel: "src/App.swift", full: "/repoB/src/App.swift", root: "/repoB", display: "RepoB/src/App.swift")
		]
		let spec = makeSpec(clauses: [.exactFile(absPath: "/repoA/src/App.swift", relPath: "src/App.swift", restrictedRootPath: "/repoA")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/repoA/src/App.swift"])
	}
	
	func testExactFolderRestrictionDoesNotLeakAcrossRoots() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repoA/src/App.swift", root: "/repoA", display: "RepoA/src/App.swift"),
			makeSnapshot(rel: "src/App.swift", full: "/repoB/src/App.swift", root: "/repoB", display: "RepoB/src/App.swift")
		]
		let spec = makeSpec(clauses: [.exactFolder(absLower: "/repoA/src", relLower: "src", restrictedRootPath: "/repoA")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/repoA/src/App.swift"])
	}
	
	func testLegacyPrefixMatchesAliasPrefixed() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repo/src/App.swift", root: "/repo", display: "RepoA/src/App.swift"),
			makeSnapshot(rel: "src/App.swift", full: "/other/src/App.swift", root: "/other", display: "RepoB/src/App.swift")
		]
		let spec = makeSpec(clauses: [.legacyPrefix(candidateLower: "repoa/src")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/repo/src/App.swift"])
	}
	
	func testLegacyPrefixTrailingSlashDoesNotMatchBareFolderName() {
		let snapshots = [
			makeSnapshot(rel: "src", full: "/repo/src", root: "/repo", display: "RepoA/src"),
			makeSnapshot(rel: "src/file.txt", full: "/repo/src/file.txt", root: "/repo", display: "RepoA/src/file.txt")
		]
		let spec = makeSpec(clauses: [.legacyPrefix(candidateLower: "src/")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/repo/src/file.txt"])
	}
	
	func testResolveFoldersBySuffixFragmentSingleComponentMatchesNestedFolder() {
		let folders: [String: FrozenFolderRecord] = [
			"/root/RepoPrompt/Views/AgentMode": FrozenFolderRecord(
				name: "AgentMode",
				relativePath: "RepoPrompt/Views/AgentMode",
				fullPath: "/root/RepoPrompt/Views/AgentMode",
				rootPath: "/root"
			),
			"/root/RepoPrompt/Views/ToolCards": FrozenFolderRecord(
				name: "ToolCards",
				relativePath: "RepoPrompt/Views/ToolCards",
				fullPath: "/root/RepoPrompt/Views/ToolCards",
				rootPath: "/root"
			)
		]
		
		let matches = resolveFoldersBySuffixFragment(
			"AgentMode/",
			in: folders,
			relativePath: { $0.relativePath }
		)
		
		XCTAssertEqual(Set(matches.map(\.relativePath)), Set(["RepoPrompt/Views/AgentMode"]))
	}
	
	func testBuildFolderSuffixIndexNormalizesAndBucketsByLastComponent() {
		let folders: [String: FrozenFolderRecord] = [
			"/root/RepoPrompt/Views/AgentMode": FrozenFolderRecord(
				name: "AgentMode",
				relativePath: "./RepoPrompt/Views/AgentMode/",
				fullPath: "/root/RepoPrompt/Views/AgentMode",
				rootPath: "/root"
			),
			"/root/RepoPrompt/AgentMode": FrozenFolderRecord(
				name: "AgentMode",
				relativePath: "RepoPrompt/AgentMode",
				fullPath: "/root/RepoPrompt/AgentMode",
				rootPath: "/root"
			),
			"/root/RepoPrompt/Views/ToolCards": FrozenFolderRecord(
				name: "ToolCards",
				relativePath: "RepoPrompt/Views/ToolCards",
				fullPath: "/root/RepoPrompt/Views/ToolCards",
				rootPath: "/root"
			)
		]
		
		let index = buildFolderSuffixIndex(in: folders, relativePath: { $0.relativePath })
		let bucket = index["agentmode"] ?? []
		XCTAssertEqual(bucket.count, 2)
		XCTAssertTrue(bucket.allSatisfy { $0.normalizedRelativePath.hasSuffix("agentmode") })
		XCTAssertEqual(index["toolcards"]?.count, 1)
	}
	
	func testNormalizedFolderSuffixFragmentHandlesSlashesAndEmpty() {
		XCTAssertEqual(normalizedFolderSuffixFragment("Views/AgentMode/", caseInsensitive: true), "views/agentmode")
		XCTAssertNil(normalizedFolderSuffixFragment("/", caseInsensitive: true))
	}
	
	func testResolveFoldersBySuffixFragmentMultiComponentMatchesNestedFolder() {
		let folders: [String: FrozenFolderRecord] = [
			"/root/RepoPrompt/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "RepoPrompt/Views/AgentMode", fullPath: "/root/RepoPrompt/Views/AgentMode", rootPath: "/root"),
			"/root/RepoPrompt/Views/Other": FrozenFolderRecord(name: "Other", relativePath: "RepoPrompt/Views/Other", fullPath: "/root/RepoPrompt/Views/Other", rootPath: "/root")
		]
		let matches = resolveFoldersBySuffixFragment("Views/AgentMode/", in: folders, relativePath: { $0.relativePath })
		XCTAssertEqual(Set(matches.map(\.relativePath)), Set(["RepoPrompt/Views/AgentMode"]))
	}
	
	func testResolveFoldersBySuffixFragmentUsingIndexMatchesNestedFolder() {
		let folders: [String: FrozenFolderRecord] = [
			"/root/RepoPrompt/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "RepoPrompt/Views/AgentMode", fullPath: "/root/RepoPrompt/Views/AgentMode", rootPath: "/root"),
			"/root/RepoPrompt/Views/Other": FrozenFolderRecord(name: "Other", relativePath: "RepoPrompt/Views/Other", fullPath: "/root/RepoPrompt/Views/Other", rootPath: "/root")
		]
		let index = buildFolderSuffixIndex(in: folders, relativePath: { $0.relativePath })
		let matches = resolveFoldersBySuffixFragment("Views/AgentMode", using: index)
		XCTAssertEqual(Set(matches.map(\.relativePath)), Set(["RepoPrompt/Views/AgentMode"]))
	}
	
	func testResolveFoldersBySuffixFragmentReturnsAllMatchesAcrossRoots() {
		let folders: [String: FrozenFolderRecord] = [
			"/rootA/RepoPrompt/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "RepoPrompt/Views/AgentMode", fullPath: "/rootA/RepoPrompt/Views/AgentMode", rootPath: "/rootA"),
			"/rootB/OtherApp/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "OtherApp/Views/AgentMode", fullPath: "/rootB/OtherApp/Views/AgentMode", rootPath: "/rootB")
		]
		let matches = resolveFoldersBySuffixFragment("AgentMode", in: folders, relativePath: { $0.relativePath })
		XCTAssertEqual(Set(matches.map(\.fullPath)), Set([
			"/rootA/RepoPrompt/Views/AgentMode",
			"/rootB/OtherApp/Views/AgentMode"
		]))
	}
	
	func testResolveFoldersBySuffixFragmentUsingIndexMatchesCompatibilityWrapper() {
		let folders: [String: FrozenFolderRecord] = [
			"/rootA/RepoPrompt/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "RepoPrompt/Views/AgentMode", fullPath: "/rootA/RepoPrompt/Views/AgentMode", rootPath: "/rootA"),
			"/rootB/OtherApp/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "OtherApp/Views/AgentMode", fullPath: "/rootB/OtherApp/Views/AgentMode", rootPath: "/rootB"),
			"/rootB/OtherApp/Views/Other": FrozenFolderRecord(name: "Other", relativePath: "OtherApp/Views/Other", fullPath: "/rootB/OtherApp/Views/Other", rootPath: "/rootB")
		]
		let indexed = resolveFoldersBySuffixFragment("AgentMode/", using: buildFolderSuffixIndex(in: folders, relativePath: { $0.relativePath }))
		let wrapped = resolveFoldersBySuffixFragment("AgentMode/", in: folders, relativePath: { $0.relativePath })
		XCTAssertEqual(Set(indexed.map(\.fullPath)), Set(wrapped.map(\.fullPath)))
	}
	
	func testFilterPathsWithFolderFragmentResolutionIncludesDescendants() {
		let snapshots = [
			makeSnapshot(rel: "RepoPrompt/Views/AgentMode/A.swift", full: "/root/RepoPrompt/Views/AgentMode/A.swift", root: "/root"),
			makeSnapshot(rel: "RepoPrompt/Views/Other/B.swift", full: "/root/RepoPrompt/Views/Other/B.swift", root: "/root")
		]
		let spec = makeSpec(clauses: [.exactFolder(absLower: "/root/RepoPrompt/Views/AgentMode", relLower: "repoprompt/views/agentmode", restrictedRootPath: "/root")])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, ["/root/RepoPrompt/Views/AgentMode/A.swift"])
	}
	
	func testResolveFoldersBySuffixFragmentDoesNotMatchPartialName() {
		let folders: [String: FrozenFolderRecord] = [
			"/root/RepoPrompt/Views/AgentMode": FrozenFolderRecord(name: "AgentMode", relativePath: "RepoPrompt/Views/AgentMode", fullPath: "/root/RepoPrompt/Views/AgentMode", rootPath: "/root"),
			"/root/RepoPrompt/Views/EditMode": FrozenFolderRecord(name: "EditMode", relativePath: "RepoPrompt/Views/EditMode", fullPath: "/root/RepoPrompt/Views/EditMode", rootPath: "/root")
		]
		let matches = resolveFoldersBySuffixFragment("Mode", in: folders, relativePath: { $0.relativePath })
		XCTAssertTrue(matches.isEmpty, "Partial name 'Mode' should not match 'AgentMode' or 'EditMode'")
	}
	
	func testFilterPathsMixedFolderFragmentAndResolvedFileUnionsResults() {
		let snapshots = [
			makeSnapshot(rel: "RepoPrompt/Views/AgentMode/A.swift", full: "/root/RepoPrompt/Views/AgentMode/A.swift", root: "/root"),
			makeSnapshot(rel: "RepoPrompt/Views/Other/Special.swift", full: "/root/RepoPrompt/Views/Other/Special.swift", root: "/root"),
			makeSnapshot(rel: "RepoPrompt/Views/Other/B.swift", full: "/root/RepoPrompt/Views/Other/B.swift", root: "/root")
		]
		let spec = makeSpec(clauses: [
			.exactFile(absPath: "/root/RepoPrompt/Views/Other/Special.swift", relPath: "RepoPrompt/Views/Other/Special.swift", restrictedRootPath: "/root"),
			.exactFolder(absLower: "/root/RepoPrompt/Views/AgentMode", relLower: "repoprompt/views/agentmode", restrictedRootPath: "/root")
		])
		let results = filterPaths(snapshots: snapshots, spec: spec)
		XCTAssertEqual(results, [
			"/root/RepoPrompt/Views/AgentMode/A.swift",
			"/root/RepoPrompt/Views/Other/Special.swift"
		])
	}
	
	// MARK: - filterPathIndicesResult (iter-002 index-returning filter)
	
	func testFilterPathIndicesResultMatchesPathResultOrderAndMetadata() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repo/src/App.swift", root: "/repo"),
			makeSnapshot(rel: "src/utils/Helper.swift", full: "/repo/src/utils/Helper.swift", root: "/repo"),
			makeSnapshot(rel: "docs/Readme.md", full: "/repo/docs/Readme.md", root: "/repo")
		]
		let spec = makeSpec(clauses: [.exactFolder(absLower: "/repo/src", relLower: "src", restrictedRootPath: "/repo")])
		let indexResult = filterPathIndicesResult(snapshots: snapshots, spec: spec)
		let pathResult = filterPathsResult(snapshots: snapshots, spec: spec)
		XCTAssertEqual(indexResult.matchedSnapshotIndices, [0, 1])
		XCTAssertEqual(indexResult.matchedSnapshotIndices.map { snapshots[$0].standardizedFullPath }, pathResult.matchedFullPaths)
		XCTAssertEqual(indexResult.visitedSnapshotCount, pathResult.visitedSnapshotCount)
		XCTAssertEqual(indexResult.cancelled, pathResult.cancelled)
	}
	
	func testFilterPathIndicesResultPreservesSnapshotOrderWhenClauseOrderDiffers() {
		let snapshots = [
			makeSnapshot(rel: "a/First.swift", full: "/repo/a/First.swift", root: "/repo"),
			makeSnapshot(rel: "b/Second.swift", full: "/repo/b/Second.swift", root: "/repo"),
			makeSnapshot(rel: "c/Third.swift", full: "/repo/c/Third.swift", root: "/repo")
		]
		// Clauses listed in reverse of snapshot order; output must follow snapshot order.
		let spec = makeSpec(clauses: [
			.exactFile(absPath: "/repo/c/Third.swift", relPath: "c/Third.swift", restrictedRootPath: "/repo"),
			.exactFile(absPath: "/repo/a/First.swift", relPath: "a/First.swift", restrictedRootPath: "/repo")
		])
		let indexResult = filterPathIndicesResult(snapshots: snapshots, spec: spec)
		XCTAssertEqual(indexResult.matchedSnapshotIndices, [0, 2])
	}
	
	func testFilterPathIndicesResultDoesNotDuplicateWhenMultipleClausesMatchSameSnapshot() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repo/src/App.swift", root: "/repo")
		]
		let spec = makeSpec(clauses: [
			.exactFile(absPath: "/repo/src/App.swift", relPath: "src/App.swift", restrictedRootPath: "/repo"),
			.exactFolder(absLower: "/repo/src", relLower: "src", restrictedRootPath: "/repo")
		])
		let indexResult = filterPathIndicesResult(snapshots: snapshots, spec: spec)
		XCTAssertEqual(indexResult.matchedSnapshotIndices, [0])
		XCTAssertEqual(filterPaths(snapshots: snapshots, spec: spec), ["/repo/src/App.swift"])
	}
	
	func testFilterPathIndicesResultCancellationMetadataMatchesPathResult() async {
		let snapshots = (0..<64).map { i in
			makeSnapshot(rel: "src/F\(i).swift", full: "/repo/src/F\(i).swift", root: "/repo")
		}
		let spec = makeSpec(clauses: [.exactFolder(absLower: "/repo/src", relLower: "src", restrictedRootPath: "/repo")])
		let task = Task { () -> (FileSearchPathIndexFilterResult, FileSearchPathFilterResult) in
			(
				filterPathIndicesResult(snapshots: snapshots, spec: spec),
				filterPathsResult(snapshots: snapshots, spec: spec)
			)
		}
		task.cancel()
		let (indexResult, pathResult) = await task.value
		XCTAssertEqual(indexResult.cancelled, pathResult.cancelled)
		XCTAssertEqual(indexResult.visitedSnapshotCount, pathResult.visitedSnapshotCount)
		XCTAssertEqual(indexResult.matchedSnapshotIndices.map { snapshots[$0].standardizedFullPath }, pathResult.matchedFullPaths)
	}
	
	func testFilterPathIndicesResultExactFileRemainsCaseSensitiveUnderCaseInsensitiveSpec() {
		let snapshots = [
			makeSnapshot(rel: "src/App.swift", full: "/repo/src/App.swift", root: "/repo")
		]
		// caseInsensitive must not relax exact-file matching: a lowercased clause path
		// should not match a mixed-case snapshot path.
		let spec = makeSpec(
			caseInsensitive: true,
			clauses: [.exactFile(absPath: "/repo/src/app.swift", relPath: "src/app.swift", restrictedRootPath: "/repo")]
		)
		XCTAssertTrue(filterPathIndicesResult(snapshots: snapshots, spec: spec).matchedSnapshotIndices.isEmpty)
	}
	
	func testFilterPathIndicesResultGlobHonorsCaseInsensitiveMatching() {
		let snapshots = [
			makeSnapshot(rel: "Sources/App.SWIFT", full: "/a/Sources/App.SWIFT", root: "/a")
		]
		let ciSpec = makeSpec(caseInsensitive: true, clauses: [.glob(pattern: "**/*.swift", restrictedRootPath: nil)])
		XCTAssertEqual(filterPathIndicesResult(snapshots: snapshots, spec: ciSpec).matchedSnapshotIndices, [0])
		let csSpec = makeSpec(caseInsensitive: false, clauses: [.glob(pattern: "**/*.swift", restrictedRootPath: nil)])
		XCTAssertTrue(filterPathIndicesResult(snapshots: snapshots, spec: csSpec).matchedSnapshotIndices.isEmpty)
	}
}
