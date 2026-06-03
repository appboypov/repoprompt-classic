import XCTest
@testable import RepoPrompt

final class GitServiceSplitUnifiedDiffByFileTests: XCTestCase {
	func testSplitUnifiedDiffByFileSeparatesSequentialModifiedFiles() {
		let diff = """
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

		let perFile = GitService.splitUnifiedDiffByFile(diff)

		XCTAssertEqual(
			Set(perFile.keys),
			[
				"Assets/Content/Scripts/InputHandler.cs",
				"Assets/Content/Scripts/WallManager.cs",
				"README.md",
			]
		)
		XCTAssertEqual(perFile["Assets/Content/Scripts/InputHandler.cs"]?.components(separatedBy: "diff --git ").count, 2)
		XCTAssertEqual(perFile["Assets/Content/Scripts/WallManager.cs"]?.components(separatedBy: "diff --git ").count, 2)
		XCTAssertEqual(perFile["README.md"]?.components(separatedBy: "diff --git ").count, 2)
		XCTAssertFalse(perFile["Assets/Content/Scripts/InputHandler.cs"]?.contains("WallManager.cs") ?? true)
		XCTAssertFalse(perFile["Assets/Content/Scripts/InputHandler.cs"]?.contains("README.md") ?? true)
		XCTAssertFalse(perFile["Assets/Content/Scripts/WallManager.cs"]?.contains("InputHandler.cs") ?? true)
		XCTAssertFalse(perFile["README.md"]?.contains("WallManager.cs") ?? true)
	}

	func testSplitUnifiedDiffByFileUsesCanonicalPathForRenameAndDeleteBlocks() {
		let diff = #"""
		diff --git "a/Docs/Old Name.md" "b/Docs/New Name.md"
		similarity index 100%
		rename from "Docs/Old Name.md"
		rename to "Docs/New Name.md"
		diff --git a/Docs/Removed.md b/Docs/Removed.md
		deleted file mode 100644
		index 1111111..0000000
		--- a/Docs/Removed.md
		+++ /dev/null
		@@ -1 +0,0 @@
		-deleted
		"""#

		let perFile = GitService.splitUnifiedDiffByFile(diff)

		XCTAssertEqual(Set(perFile.keys), ["Docs/New Name.md", "Docs/Removed.md"])
		XCTAssertTrue(perFile["Docs/New Name.md"]?.contains("rename to \"Docs/New Name.md\"") ?? false)
		XCTAssertTrue(perFile["Docs/Removed.md"]?.contains("+++ /dev/null") ?? false)
	}

	func testSplitUnifiedDiffByFilePreservesMissingTrailingNewlineAndIgnoresPreamble() {
		let diff = """
		warning: ignored preamble
		diff --git a/One.swift b/One.swift
		index 1111111..2222222 100644
		--- a/One.swift
		+++ b/One.swift
		@@ -1 +1 @@
		-old
		+new
		diff --git a/Two.swift b/Two.swift
		index 3333333..4444444 100644
		--- a/Two.swift
		+++ b/Two.swift
		@@ -2 +2 @@
		-two
		+TWO
		""".trimmingCharacters(in: .newlines)

		let perFile = GitService.splitUnifiedDiffByFile(diff)

		XCTAssertEqual(Set(perFile.keys), ["One.swift", "Two.swift"])
		XCTAssertFalse(perFile["One.swift"]?.contains("warning: ignored preamble") ?? true)
		XCTAssertFalse(perFile["One.swift"]?.hasSuffix("\n") ?? true)
		XCTAssertFalse(perFile["Two.swift"]?.hasSuffix("\n") ?? true)
	}
}
