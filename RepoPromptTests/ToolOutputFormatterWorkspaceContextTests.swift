import Foundation
import MCP
import XCTest
@testable import RepoPrompt

/// Regression tests for workspace_context formatting when it returns forwarded
/// prompt-tool envelope results (e.g. list_presets, export, select_preset).
///
/// Bug context: workspace_context op=list_presets returned a PromptToolEnvelope
/// from the prompt handler, but formatPromptState rendered it as a generic
/// "Prompt State" block because it didn't recognize the envelope shape.
final class ToolOutputFormatterWorkspaceContextTests: XCTestCase {

	// MARK: - Bug 2 regression: list_presets via workspace_context

	func testWorkspaceContextPresetsEnvelopeRendersPresetList() throws {
		let presets = [
			ToolResultDTOs.CopyPresetListItemDTO(
				preset: ToolResultDTOs.CopyPresetDescriptorDTO(
					id: UUID().uuidString,
					name: "Standard",
					kind: "standard",
					isBuiltIn: true
				),
				description: "Default copy format",
				icon: "📋",
				includeFiles: true,
				includeUserPrompt: true,
				includeMetaPrompts: nil,
				includeFileTree: nil,
				xmlFormat: nil,
				fileTreeMode: "auto",
				codeMapUsage: "auto",
				gitInclusion: "none",
				systemPromptFlavor: nil,
				includeMCPMetadata: nil
			),
			ToolResultDTOs.CopyPresetListItemDTO(
				preset: ToolResultDTOs.CopyPresetDescriptorDTO(
					id: UUID().uuidString,
					name: "Code Review",
					kind: "codeReview",
					isBuiltIn: true
				),
				description: "Optimized for code reviews",
				icon: "🔍",
				includeFiles: true,
				includeUserPrompt: nil,
				includeMetaPrompts: nil,
				includeFileTree: nil,
				xmlFormat: nil,
				fileTreeMode: nil,
				codeMapUsage: nil,
				gitInclusion: "selected",
				systemPromptFlavor: nil,
				includeMCPMetadata: nil
			)
		]

		let envelope = ToolResultDTOs.PromptToolEnvelope.forPresetsList(presets)
		let value = try encodedValue(envelope)

		// Route through workspace_context path (the bug path)
		let blocks = ToolOutputFormatter.buildContentBlocks(
			toolName: "workspace_context",
			args: ["op": .string("list_presets")],
			result: value,
			emitResources: false
		)

		let text = extractText(blocks)

		// Should render as preset list, not generic prompt state
		XCTAssertTrue(text.contains("## Copy Presets"), "Should render preset list header")
		XCTAssertTrue(text.contains("Standard"), "Should contain preset name")
		XCTAssertTrue(text.contains("Code Review"), "Should contain second preset name")
		XCTAssertTrue(text.contains("2 presets available"), "Should show preset count")

		// Must NOT fall through to generic prompt-state rendering
		XCTAssertFalse(text.contains("## Prompt Context"), "Must not render as prompt context")
		XCTAssertFalse(text.contains("## Prompt State"), "Must not render as legacy prompt state")
	}

	// MARK: - select_preset via workspace_context

	func testWorkspaceContextSelectPresetEnvelopeRendersSelectedPreset() throws {
		let preset = ToolResultDTOs.CopyPresetDescriptorDTO(
			id: UUID().uuidString,
			name: "MCP Builder",
			kind: "mcpBuilder",
			isBuiltIn: true
		)

		let envelope = ToolResultDTOs.PromptToolEnvelope.forSelectPreset(preset)
		let value = try encodedValue(envelope)

		let blocks = ToolOutputFormatter.buildContentBlocks(
			toolName: "workspace_context",
			args: ["op": .string("select_preset")],
			result: value,
			emitResources: false
		)

		let text = extractText(blocks)

		XCTAssertTrue(text.contains("## Copy Preset Selected"), "Should render selected preset header")
		XCTAssertTrue(text.contains("MCP Builder"), "Should contain selected preset name")
		XCTAssertFalse(text.contains("## Prompt Context"), "Must not render as prompt context")
	}

	// MARK: - Normal snapshot still renders as prompt context

	func testWorkspaceContextSnapshotStillFormatsAsPromptContext() throws {
		let ctx = ToolResultDTOs.PromptContextDTO(
			prompt: "Test prompt",
			selection: nil,
			fileBlocks: nil,
			codeStructure: nil,
			fileTree: nil,
			tokenStats: nil,
			userTokenStats: nil,
			tokenStatsNote: nil,
			copyPreset: nil,
			copyPresets: nil
		)

		let value = try encodedValue(ctx)

		let blocks = ToolOutputFormatter.buildContentBlocks(
			toolName: "workspace_context",
			args: [:],
			result: value,
			emitResources: false
		)

		let text = extractText(blocks)

		XCTAssertTrue(text.contains("## Prompt Context"), "Snapshot should still render as Prompt Context")
		XCTAssertTrue(text.contains("Test prompt"), "Should contain prompt text")
	}

	// MARK: - Prompt tool path still works (non-regression)

	func testPromptToolPresetsListStillRendersCorrectly() throws {
		let presets = [
			ToolResultDTOs.CopyPresetListItemDTO(
				preset: ToolResultDTOs.CopyPresetDescriptorDTO(
					id: UUID().uuidString,
					name: "Plan Mode",
					kind: "plan",
					isBuiltIn: true
				),
				description: "Planning format",
				icon: "📝",
				includeFiles: nil,
				includeUserPrompt: nil,
				includeMetaPrompts: nil,
				includeFileTree: nil,
				xmlFormat: nil,
				fileTreeMode: nil,
				codeMapUsage: nil,
				gitInclusion: nil,
				systemPromptFlavor: nil,
				includeMCPMetadata: nil
			)
		]

		let envelope = ToolResultDTOs.PromptToolEnvelope.forPresetsList(presets)
		let value = try encodedValue(envelope)

		// Route through prompt path (should still work)
		let blocks = ToolOutputFormatter.buildContentBlocks(
			toolName: "prompt",
			args: ["op": .string("list_presets")],
			result: value,
			emitResources: false
		)

		let text = extractText(blocks)

		XCTAssertTrue(text.contains("## Copy Presets"), "Prompt tool should render presets correctly")
		XCTAssertTrue(text.contains("Plan Mode"), "Should contain preset name")
	}

	// MARK: - Helpers

	private func encodedValue<T: Encodable>(_ dto: T) throws -> Value {
		let data = try JSONEncoder().encode(dto)
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))
		return try XCTUnwrap(Value.fromJSONString(json))
	}

	private func extractText(_ blocks: [MCP.Tool.Content]) -> String {
		blocks.compactMap { block in
			if case .text(let text, _, _) = block { return text }
			return nil
		}.joined(separator: "\n")
	}
}
