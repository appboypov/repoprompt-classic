import XCTest
@testable import RepoPrompt

final class GitDiffSnapshotStoreRenameArtifactTests: XCTestCase {
	func testWriteSnapshotKeepsNormalizedRenamePathInArtifacts() throws {
		let store = GitDiffSnapshotStore()
		let workspaceDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: workspaceDirectory) }

		let fingerprint = GitDiffFingerprint(
			headSHA: "55b83e3",
			baseRef: "55b83e3~1..55b83e3",
			statusHash: "status-hash",
			generatedAt: Date(timeIntervalSince1970: 1_710_000_000)
		)
		let renamedPath = "build/static/js/514.506331af.chunk.js"
		let sourcePath = "src/docs/changelog/Version20.js"
		let renamePatch = """
		diff --git a/build/static/js/514.07631633.chunk.js b/build/static/js/514.506331af.chunk.js
		similarity index 98%
		rename from build/static/js/514.07631633.chunk.js
		rename to build/static/js/514.506331af.chunk.js
		"""
		let sourcePatch = """
		diff --git a/src/docs/changelog/Version20.js b/src/docs/changelog/Version20.js
		index 1111111..2222222 100644
		--- a/src/docs/changelog/Version20.js
		+++ b/src/docs/changelog/Version20.js
		@@ -84,1 +84,1 @@
		-- GPT-4.5 Pro
		++ GPT-5.4 Pro
		"""
		let combinedDiff = [renamePatch, sourcePatch].joined(separator: "\n")
		let inputs = GitDiffEngine.GitDiffSnapshotBuildResult(
			fingerprint: fingerprint,
			compare: .revspec("55b83e3~1..55b83e3"),
			scope: .all,
			requestedPaths: nil,
			diffText: combinedDiff,
			perFile: GitService.splitUnifiedDiffByFile(combinedDiff),
			changedFiles: [
				VCSUncommittedFile(path: renamedPath, status: "R", additions: 1, deletions: 1),
				VCSUncommittedFile(path: sourcePath, status: "M", additions: 1, deletions: 1)
			],
			summary: (files: 2, insertions: 2, deletions: 2)
		)

		let manifest = try store.writeSnapshot(
			workspaceDirectory: workspaceDirectory,
			repoKey: "repopromptweb-4747bd48",
			snapshotID: "2026-03-14/1455",
			mode: .standard,
			compareRaw: "55b83e3~1..55b83e3",
			compareInput: nil,
			scope: .all,
			requestedPaths: nil,
			fingerprint: fingerprint,
			contextLines: 3,
			detectRenames: false,
			inputs: inputs,
			commitGraph: "* 55b83e3 Update changelog model name",
			repoRoot: "/tmp/RepoPromptWeb"
		)

		let snapshotDir = store.snapshotDir(
			workspaceDirectory: workspaceDirectory,
			repoKey: "repopromptweb-4747bd48",
			snapshotID: "2026-03-14/1455"
		)
		let mapURL = snapshotDir.appendingPathComponent("MAP.txt")
		let mapText = try String(contentsOf: mapURL, encoding: .utf8)
		let patchURL = snapshotDir.appendingPathComponent("diff/per-file/build__static__js__514.506331af.chunk.js.patch")
		let sourcePatchURL = snapshotDir.appendingPathComponent("diff/per-file/src__docs__changelog__Version20.js.patch")
		let expectedTreeLine = "514.506331af.chunk.js  [01] R +1 -1"
		let expectedJumpLine = "[01] R +1 -1  build/static/js/514.506331af.chunk.js -> diff/per-file/build__static__js__514.506331af.chunk.js.patch"
		let expectedSelectionSection = "SECTION: PER_FILE_PATCH_SELECTION_PATHS"
		let expectedSelectionLine = "[01] R +1 -1  build/static/js/514.506331af.chunk.js -> _git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/diff/per-file/build__static__js__514.506331af.chunk.js.patch"

		XCTAssertTrue(mapText.contains(expectedTreeLine))
		XCTAssertTrue(mapText.contains(expectedJumpLine))
		XCTAssertTrue(mapText.contains(expectedSelectionSection))
		XCTAssertTrue(mapText.contains(expectedSelectionLine))
		XCTAssertFalse(mapText.contains("514.506331af.chunk.js}"))
		XCTAssertTrue(FileManager.default.fileExists(atPath: patchURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePatchURL.path))
		XCTAssertEqual(try String(contentsOf: patchURL, encoding: .utf8).components(separatedBy: "diff --git ").count, 2)
		XCTAssertEqual(try String(contentsOf: sourcePatchURL, encoding: .utf8).components(separatedBy: "diff --git ").count, 2)
		XCTAssertEqual(manifest.files.first(where: { $0.gitPath == renamedPath })?.gitPath, renamedPath)
		XCTAssertNotNil(manifest.files.first(where: { $0.gitPath == renamedPath })?.patchPath)
		XCTAssertNotNil(manifest.files.first(where: { $0.gitPath == sourcePath })?.patchPath)
		XCTAssertTrue(mapText.contains("NOTE_PATCH_OMITTED_COUNT: 0"))
	}

	func testWriteSnapshotCreatesPerFileArtifactsForEveryChangedFileBlock() throws {
		let store = GitDiffSnapshotStore()
		let workspaceDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: workspaceDirectory) }

		let fingerprint = GitDiffFingerprint(
			headSHA: "abcdef1",
			baseRef: "abcdef1~1..abcdef1",
			statusHash: "status-hash-2",
			generatedAt: Date(timeIntervalSince1970: 1_710_000_100)
		)
		let inputHandlerPath = "Assets/Content/Scripts/InputHandler.cs"
		let wallManagerPath = "Assets/Content/Scripts/WallManager.cs"
		let readmePath = "README.md"
		let combinedDiff = """
		diff --git a/Assets/Content/Scripts/InputHandler.cs b/Assets/Content/Scripts/InputHandler.cs
		index ccaf7160..354efff4 100644
		--- a/Assets/Content/Scripts/InputHandler.cs
		+++ b/Assets/Content/Scripts/InputHandler.cs
		@@ -1,1 +1,1 @@
		-a
		+b
		diff --git a/Assets/Content/Scripts/WallManager.cs b/Assets/Content/Scripts/WallManager.cs
		index 8215f3fd..68ec21d4 100644
		--- a/Assets/Content/Scripts/WallManager.cs
		+++ b/Assets/Content/Scripts/WallManager.cs
		@@ -1,1 +1,1 @@
		-c
		+d
		diff --git a/README.md b/README.md
		index 60419a29..924d83ba 100644
		--- a/README.md
		+++ b/README.md
		@@ -1 +1,2 @@
		-x
		+y
		+z
		"""
		let inputs = GitDiffEngine.GitDiffSnapshotBuildResult(
			fingerprint: fingerprint,
			compare: .revspec("abcdef1~1..abcdef1"),
			scope: .all,
			requestedPaths: nil,
			diffText: combinedDiff,
			perFile: GitService.splitUnifiedDiffByFile(combinedDiff),
			changedFiles: [
				VCSUncommittedFile(path: inputHandlerPath, status: "M", additions: 1, deletions: 1),
				VCSUncommittedFile(path: wallManagerPath, status: "M", additions: 1, deletions: 1),
				VCSUncommittedFile(path: readmePath, status: "M", additions: 2, deletions: 1)
			],
			summary: (files: 3, insertions: 4, deletions: 3)
		)

		let manifest = try store.writeSnapshot(
			workspaceDirectory: workspaceDirectory,
			repoKey: "bombsquad-130e4dc6",
			snapshotID: "2026-03-16/0912",
			mode: .standard,
			compareRaw: "abcdef1~1..abcdef1",
			compareInput: nil,
			scope: .all,
			requestedPaths: nil,
			fingerprint: fingerprint,
			contextLines: 3,
			detectRenames: false,
			inputs: inputs,
			commitGraph: "* abcdef1 Split per-file patches correctly",
			repoRoot: "/tmp/BombSquad"
		)

		let snapshotDir = store.snapshotDir(
			workspaceDirectory: workspaceDirectory,
			repoKey: "bombsquad-130e4dc6",
			snapshotID: "2026-03-16/0912"
		)
		let inputPatchURL = snapshotDir.appendingPathComponent("diff/per-file/Assets__Content__Scripts__InputHandler.cs.patch")
		let wallPatchURL = snapshotDir.appendingPathComponent("diff/per-file/Assets__Content__Scripts__WallManager.cs.patch")
		let readmePatchURL = snapshotDir.appendingPathComponent("diff/per-file/README.md.patch")
		let mapText = try String(contentsOf: snapshotDir.appendingPathComponent("MAP.txt"), encoding: .utf8)

		for patchURL in [inputPatchURL, wallPatchURL, readmePatchURL] {
			XCTAssertTrue(FileManager.default.fileExists(atPath: patchURL.path))
			XCTAssertEqual(try String(contentsOf: patchURL, encoding: .utf8).components(separatedBy: "diff --git ").count, 2)
		}
		XCTAssertFalse(mapText.contains("(no patch)"))
		XCTAssertEqual(manifest.files.filter { $0.patchPath == nil }.count, 0)
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GitDiffSnapshotStoreRenameArtifactTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}
}
