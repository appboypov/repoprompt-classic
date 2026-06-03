import XCTest
@testable import RepoPrompt

final class CopyFileTreeResolutionTests: XCTestCase {
	func testModeNoneDoesNotRenderTreeEvenWhenIncludeFlagIsTrue() {
		let resolved = makeResolved(includeFileTree: true, fileTreeMode: .none)

		XCTAssertFalse(resolved.rendersFileTree)
		XCTAssertEqual(resolved.effectiveFileTreeMode, .none)
	}

	func testIncludeFlagFalseDoesNotRenderTreeEvenWhenModeWouldRender() {
		let resolved = makeResolved(includeFileTree: false, fileTreeMode: .auto)

		XCTAssertFalse(resolved.rendersFileTree)
		XCTAssertEqual(resolved.effectiveFileTreeMode, .none)
	}

	func testRenderableModeWithIncludeFlagRendersTree() {
		let resolved = makeResolved(includeFileTree: true, fileTreeMode: .selected)

		XCTAssertTrue(resolved.rendersFileTree)
		XCTAssertEqual(resolved.effectiveFileTreeMode, .selected)
	}

	private func makeResolved(
		includeFileTree: Bool,
		fileTreeMode: FileTreeOption
	) -> PromptContextResolved {
		PromptContextResolved(
			includeFiles: true,
			includeUserPrompt: true,
			includeMetaPrompts: true,
			includeFileTree: includeFileTree,
			xmlFormat: nil,
			fileTreeMode: fileTreeMode,
			codeMapUsage: .none,
			gitInclusion: .none,
			systemPromptFlavor: nil,
			storedPromptIds: nil,
			includeMCPMetadata: false
		)
	}
}
