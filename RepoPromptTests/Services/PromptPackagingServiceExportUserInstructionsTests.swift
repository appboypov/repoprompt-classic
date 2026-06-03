import XCTest
@testable import RepoPrompt

final class PromptPackagingServiceExportUserInstructionsTests: XCTestCase {
	func testClipboardExportIncludesUserInstructionsBlockWhenEnabled() async {
		let userText = "USER: keep this line"
		let content = await makeClipboardContent(userInstructions: userText)

		XCTAssertTrue(content.contains("<user_instructions>"))
		XCTAssertTrue(content.contains(userText))
		XCTAssertTrue(content.contains("</user_instructions>"))
	}

	func testClipboardExportKeepsMetadataAndUserInstructionsInSameBlock() async {
		let metadata = "<mcp_metadata>tab-1</mcp_metadata>"
		let userText = "USER: do not drop me"
		let content = await makeClipboardContent(userInstructions: userText, mcpMetadata: metadata)

		guard let block = extractBlock(tag: "user_instructions", in: content) else {
			return XCTFail("Expected <user_instructions> block")
		}
		XCTAssertTrue(block.contains(metadata))
		XCTAssertTrue(block.contains(userText))

		guard
			let metadataOffset = offset(of: metadata, in: block),
			let userOffset = offset(of: userText, in: block)
		else {
			return XCTFail("Expected metadata and user text in user_instructions block")
		}
		XCTAssertLessThan(metadataOffset, userOffset)
	}

	func testClipboardExportIncludesFileMapWhenTreeProvided() async {
		let fileTree = "RepoPrompt/\n  App.swift"
		let content = await makeClipboardContent(fileTreeContent: fileTree)

		XCTAssertTrue(content.contains("<file_map>"))
		XCTAssertTrue(content.contains(fileTree))
		XCTAssertTrue(content.contains("</file_map>"))
	}

	func testClipboardExportOmitsFileMapWhenTreeIsNilAndNoFilesAreIncluded() async {
		let content = await makeClipboardContent(fileTreeContent: nil)

		XCTAssertFalse(content.contains("<file_map>"))
		XCTAssertFalse(content.contains("</file_map>"))
	}

	func testClipboardExportOmitsFileMapWhenTreeIsEmptyAndNoFilesAreIncluded() async {
		let content = await makeClipboardContent(fileTreeContent: "")

		XCTAssertFalse(content.contains("<file_map>"))
		XCTAssertFalse(content.contains("</file_map>"))
	}

	func testDiffClipboardExportOmitsFileMapWhenTreeIsNilAndNoFilesAreIncluded() async {
		let content = await PromptPackagingService.generateDiffClipboardContent(
			instructions: "USER: no tree",
			files: [],
			format: .diff,
			includeFiles: false,
			filePathDisplay: .full,
			allowDiffRewrite: true,
			fileTreeContent: nil,
			gitDiff: nil,
			includeDatetimeInUserInstructions: false,
			mcpMetadata: nil,
			promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
			disabledPromptSections: [],
			duplicateUserInstructionsAtTop: false,
			includeMetaPrompts: false,
			metaInstructions: []
		)

		XCTAssertFalse(content.contains("<file_map>"))
		XCTAssertFalse(content.contains("</file_map>"))
	}

	func testClipboardExportIncludesGitDiffWhenProvided() async {
		let diff = "diff --git a/a.swift b/a.swift\n+let x = 1"
		let content = await makeClipboardContent(gitDiff: diff)

		XCTAssertTrue(content.contains("<git_diff>"))
		XCTAssertTrue(content.contains(diff))
		XCTAssertTrue(content.contains("</git_diff>"))
	}

	func testClipboardExportIncludesMetaPromptsWhenEnabled() async {
		let metas = [MetaInstruction(title: "t", content: "c")]
		let content = await makeClipboardContent(metaInstructions: metas, includeSavedPrompts: true)

		XCTAssertTrue(content.contains("<meta prompt 1 = \"t\">"))
		XCTAssertTrue(content.contains("c"))
		XCTAssertTrue(content.contains("</meta prompt 1>"))
	}

	func testDiffClipboardExportIncludesUserInstructionsAndImportantWarning() async {
		let userText = "USER: keep this line"
		let content = await PromptPackagingService.generateDiffClipboardContent(
			instructions: userText,
			files: [],
			format: .diff,
			includeFiles: false,
			filePathDisplay: .full,
			allowDiffRewrite: true,
			fileTreeContent: nil,
			gitDiff: nil,
			includeDatetimeInUserInstructions: false,
			mcpMetadata: nil,
			promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
			disabledPromptSections: [],
			duplicateUserInstructionsAtTop: false,
			includeMetaPrompts: false,
			metaInstructions: []
		)

		XCTAssertTrue(content.contains("<user_instructions>"))
		XCTAssertTrue(content.contains(userText))
		XCTAssertTrue(content.contains("**IMPORTANT** IF MAKING FILE CHANGES"))
	}

	func testClipboardExportNeverDropsUserInstructionsAcrossRepeatedGenerations() async {
		let userText = "USER: stable across runs"

		for _ in 0..<100 {
			let content = await makeClipboardContent(userInstructions: userText)
			XCTAssertTrue(content.contains("<user_instructions>"))
			XCTAssertTrue(content.contains(userText))
		}
	}

	func testPresetLikeToggleCanExcludeAndReIncludeUserPrompt() async {
		let userText = "USER: preset toggle check"

		let hidden = await makeClipboardContent(
			userInstructions: userText,
			includeUserPrompt: false
		)
		XCTAssertFalse(hidden.contains("<user_instructions>"))
		XCTAssertFalse(hidden.contains(userText))

		let restored = await makeClipboardContent(
			userInstructions: userText,
			includeUserPrompt: true
		)
		XCTAssertTrue(restored.contains("<user_instructions>"))
		XCTAssertTrue(restored.contains(userText))
	}

	func testBackgroundTabPromptRemainsStableWhenActivePromptChanges() async {
		let backgroundPrompt = "USER: background tab prompt"
		let activePrompt = "USER: active tab prompt"

		let backgroundExport = await makeClipboardContent(userInstructions: backgroundPrompt)
		let activeExport = await makeClipboardContent(userInstructions: activePrompt)

		XCTAssertTrue(backgroundExport.contains(backgroundPrompt))
		XCTAssertFalse(backgroundExport.contains(activePrompt))
		XCTAssertTrue(activeExport.contains(activePrompt))
		XCTAssertFalse(activeExport.contains(backgroundPrompt))
	}

	private func makeClipboardContent(
		metaInstructions: [MetaInstruction] = [],
		userInstructions: String = "USER: default",
		fileTreeContent: String? = nil,
		gitDiff: String? = nil,
		includeSavedPrompts: Bool = false,
		includeUserPrompt: Bool = true,
		mcpMetadata: String? = nil
	) async -> String {
		await PromptPackagingService.generateClipboardContent(
			metaInstructions: metaInstructions,
			userInstructions: userInstructions,
			files: [],
			fileTreeContent: fileTreeContent,
			gitDiff: gitDiff,
			includeDiffFormatting: false,
			includeSavedPrompts: includeSavedPrompts,
			includeFiles: false,
			includeUserPrompt: includeUserPrompt,
			filePathDisplay: .full,
			selectedXMLFormat: .whole,
			includeDatetimeInUserInstructions: false,
			mcpMetadata: mcpMetadata,
			promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
			disabledPromptSections: [],
			duplicateUserInstructionsAtTop: false
		)
	}

	private func extractBlock(tag: String, in text: String) -> String? {
		let openTag = "<\(tag)>"
		let closeTag = "</\(tag)>"
		guard
			let openRange = text.range(of: openTag),
			let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
		else {
			return nil
		}
		return String(text[openRange.lowerBound..<closeRange.upperBound])
	}

	private func offset(of needle: String, in haystack: String) -> Int? {
		guard let range = haystack.range(of: needle) else { return nil }
		return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
	}
}
