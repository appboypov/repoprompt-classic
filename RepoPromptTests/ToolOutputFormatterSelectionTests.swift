import Foundation
import MCP
import XCTest
@testable import RepoPrompt

final class ToolOutputFormatterSelectionTests: XCTestCase {
	private let repoRoot = "/Users/example/Documents/XCode/RepoPrompt"
	private let selectionPath = "RepoPrompt/ViewModels/RepoFileManagerViewModel.swift"
	private let bombSquadRoot = "/Users/example/Documents/Git/BombSquad"
	private let bombSquadPath = "Assets/Content/Scripts/BombBehavior.cs"
	private var bombSquadFullPath: String { "\(bombSquadRoot)/\(bombSquadPath)" }

	func testFormatSelectionReplyToStringFallsBackToFileSlices() {
		let output = ToolOutputFormatter.formatSelectionReplyToString(makeSelectionReply())

		XCTAssertTrue(output.contains("lines 10-20"))
		XCTAssertFalse(output.contains("(full)"))
	}

	func testFormatManageSelectionFallsBackToFileSlices() throws {
		let reply = makeSelectionReply()
		let data = try JSONEncoder().encode(reply)
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))
		let value = try XCTUnwrap(Value.fromJSONString(json))
		let blocks = ToolOutputFormatter.formatManageSelection(
			args: ["op": .string("get")],
			value: value
		)

		guard let first = blocks.first, case .text(let text, _, _) = first else {
			return XCTFail("Expected text content block")
		}

		XCTAssertTrue(text.contains("lines 10-20"))
		XCTAssertFalse(text.contains("(full)"))
	}

	func testFormatSelectionReplyToStringUsesAbsoluteRootMetadataForRelativeDisplayPath() {
		let output = ToolOutputFormatter.formatSelectionReplyToString(makeSelectionReply())

		XCTAssertTrue(output.contains("\(repoRoot)/\n"))
		XCTAssertTrue(output.contains("└── RepoPrompt/\n    └── ViewModels/\n        └── RepoFileManagerViewModel.swift — 123 tokens (lines 10-20)"))
		XCTAssertFalse(output.contains("RepoPrompt/ViewModels/\n"))
	}

	func testFormatManageSelectionUsesAbsoluteRootMetadataForRelativeDisplayPath() throws {
		let reply = makeSelectionReply()
		let data = try JSONEncoder().encode(reply)
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))
		let value = try XCTUnwrap(Value.fromJSONString(json))
		let blocks = ToolOutputFormatter.formatManageSelection(
			args: ["op": .string("get")],
			value: value
		)

		guard let first = blocks.first, case .text(let text, _, _) = first else {
			return XCTFail("Expected text content block")
		}

		XCTAssertTrue(text.contains("\(repoRoot)/\n"))
		XCTAssertTrue(text.contains("└── RepoPrompt/\n    └── ViewModels/\n        └── RepoFileManagerViewModel.swift — 123 tokens (lines 10-20)"))
	}

	func testFormatSelectionReplyToStringPreservesFullPathRootAndRendersRelativeTreeWithSliceRanges() {
		let output = ToolOutputFormatter.formatSelectionReplyToString(makeSelectionReply(
			path: bombSquadFullPath,
			rootPath: bombSquadRoot,
			pathWithinRoot: bombSquadPath
		))

		XCTAssertTrue(output.contains("\(bombSquadRoot)/\n"))
		XCTAssertTrue(output.contains("└── Assets/\n    └── Content/\n        └── Scripts/\n            └── BombBehavior.cs — 123 tokens (lines 10-20)"))
		XCTAssertFalse(output.contains("\(bombSquadRoot)/Assets/Content/Scripts/"))
		XCTAssertFalse(output.contains("\nUsers/pvncher/Documents/Git/BombSquad"))
	}

	func testFormatManageSelectionPreservesFullPathRootAndRendersRelativeTreeWithSliceRanges() throws {
		let reply = makeSelectionReply(
			path: bombSquadFullPath,
			rootPath: bombSquadRoot,
			pathWithinRoot: bombSquadPath
		)
		let data = try JSONEncoder().encode(reply)
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))
		let value = try XCTUnwrap(Value.fromJSONString(json))
		let blocks = ToolOutputFormatter.formatManageSelection(
			args: ["op": .string("get"), "path_display": .string("full")],
			value: value
		)

		guard let first = blocks.first, case .text(let text, _, _) = first else {
			return XCTFail("Expected text content block")
		}

		XCTAssertTrue(text.contains("\(bombSquadRoot)/\n"))
		XCTAssertTrue(text.contains("└── Assets/\n    └── Content/\n        └── Scripts/\n            └── BombBehavior.cs — 123 tokens (lines 10-20)"))
		XCTAssertFalse(text.contains("\(bombSquadRoot)/Assets/Content/Scripts/"))
		XCTAssertFalse(text.contains("\nUsers/pvncher/Documents/Git/BombSquad"))
	}

	func testFormatSelectionReplyToStringFallsBackToDisplayPathWhenRootMetadataMissing() {
		let output = ToolOutputFormatter.formatSelectionReplyToString(makeSelectionReply(includeRootMetadata: false))

		XCTAssertTrue(output.contains("RepoPrompt/\n└── ViewModels/\n    └── RepoFileManagerViewModel.swift — 123 tokens (lines 10-20)"))
	}

	func testFormatSelectionReplyToStringShowsSliceOnlyReplies() {
		let reply = ToolResultDTOs.SelectionReply(
			files: nil,
			totalTokens: 123,
			status: "ok",
			fileSlices: [
				ToolResultDTOs.FileSliceDTO(
					path: selectionPath,
					ranges: [ToolResultDTOs.LineRangeDTO(startLine: 10, endLine: 20)],
					rootPath: repoRoot,
					pathWithinRoot: selectionPath
				)
			]
		)

		let output = ToolOutputFormatter.formatSelectionReplyToString(reply)

		XCTAssertTrue(output.contains("### Selection Slices"))
		XCTAssertTrue(output.contains("lines 10-20"))
	}

	private func makeSelectionReply(
		path overridePath: String? = nil,
		rootPath: String? = nil,
		pathWithinRoot: String? = nil,
		includeRootMetadata: Bool = true
	) -> ToolResultDTOs.SelectionReply {
		let path = overridePath ?? selectionPath
		let effectiveRootPath = includeRootMetadata ? (rootPath ?? repoRoot) : nil
		let effectivePathWithinRoot = includeRootMetadata ? (pathWithinRoot ?? selectionPath) : nil
		let ranges = [
			ToolResultDTOs.LineRangeDTO(startLine: 10, endLine: 20)
		]
		let file = ToolResultDTOs.SelectedFileInfo(
			path: path,
			tokens: 123,
			renderMode: "full",
			ranges: nil,
			isAuto: false,
			codemapOrigin: nil,
			copyPreset: nil,
			rootPath: effectiveRootPath,
			pathWithinRoot: effectivePathWithinRoot
		)
		let summary = ToolResultDTOs.SelectionSummary(
			fullCount: 0,
			sliceCount: 1,
			codemapCount: 0,
			fullTokens: 0,
			sliceTokens: 123,
			codemapTokens: 0
		)

		return ToolResultDTOs.SelectionReply(
			files: [file],
			totalTokens: 123,
			status: "ok",
			fileSlices: [
				ToolResultDTOs.FileSliceDTO(
					path: path,
					ranges: ranges,
					rootPath: effectiveRootPath,
					pathWithinRoot: effectivePathWithinRoot
				)
			],
			codemapAutoEnabled: true,
			summary: summary,
			codeMapUsage: "auto"
		)
	}
}
