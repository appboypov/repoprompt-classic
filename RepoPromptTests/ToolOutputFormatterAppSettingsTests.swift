import Foundation
import MCP
import XCTest
@testable import RepoPrompt

final class ToolOutputFormatterAppSettingsTests: XCTestCase {
	func testListWithoutValuesRendersGroupedCatalogWithoutRawScaffolding() throws {
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"read_only": .bool(false),
			"supports_set": .bool(true),
			"groups": .array([.string("ui"), .string("mcp")]),
			"count": .int(2),
			"settings": .array([
				setting(key: "ui.appearance_mode", group: "ui", type: "string", allowed: ["System", "Light", "Dark"]),
				setting(key: "mcp.show_model_presets", group: "mcp", type: "boolean", description: "Show MCP model preset recommendations.", writable: true)
			])
		])

		let text = render(value)

		XCTAssertTrue(text.contains("## App Settings ✅"))
		XCTAssertTrue(text.contains("### ui"))
		XCTAssertTrue(text.contains("- `ui.appearance_mode` (string, enum) — System, Light, Dark"))
		XCTAssertTrue(text.contains("### mcp"))
		XCTAssertFalse(text.contains("current:"))
		XCTAssertFalse(text.contains("read_only"))
		XCTAssertFalse(text.contains("writable"))
	}

	func testListWithValuesRendersCurrentPreviewAndOmitsFullLongString() throws {
		let fullValue = String(repeating: "section,", count: 40)
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"groups": .array([.string("prompt_packaging")]),
			"count": .int(1),
			"settings": .array([
				.object([
					"key": .string("prompt_packaging.prompt_sections_order"),
					"group": .string("prompt_packaging"),
					"type": .string("string"),
					"description": .string("Prompt section ordering."),
					"value_preview": .string("[\"header\",\"files\",\"prompt\"]"),
					"value_length": .int(fullValue.count),
					"value_format": .string("JSON string array of section identifiers.")
				])
			])
		])

		let text = render(value, args: ["op": .string("list"), "group": .string("prompt_packaging")])

		XCTAssertTrue(text.contains("current: `\"[\\\"header\\\",\\\"files\\\",\\\"prompt\\\"]\"`"))
		XCTAssertTrue(text.contains("(…+"))
		XCTAssertTrue(text.contains("*format: JSON string array of section identifiers.*"))
		XCTAssertFalse(text.contains(fullValue))
	}

	func testListCapsRowsAndRendersUnknownSideEffectToken() throws {
		let settings = (1...45).map { index -> Value in
			var object: [String: Value] = [
				"key": .string(String(format: "ui.setting_%02d", index)),
				"group": .string("ui"),
				"type": .string("boolean"),
				"description": .string("Synthetic setting \(index)."),
				"value": .bool(index.isMultiple(of: 2))
			]
			if index == 1 {
				object["side_effect"] = .string("custom_future_effect")
			}
			return .object(object)
		}
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"groups": .array([.string("ui")]),
			"count": .int(45),
			"settings": .array(settings)
		])

		let text = render(value, args: ["op": .string("list")])

		XCTAssertTrue(text.contains("custom_future_effect"))
		XCTAssertTrue(text.contains("…and 33 more settings"))
		XCTAssertFalse(text.contains("ui.setting_45`"))
	}

	func testGetSingleAndNullValuesRenderMarkdownTable() throws {
		let value: Value = .object([
			"op": .string("get"),
			"status": .string("ok"),
			"count": .int(2),
			"values": .object([
				"models.planning_model": .null,
				"ui.appearance_mode": .string("Dark")
			])
		])

		let text = render(value, args: ["op": .string("get"), "keys": .array([.string("models.planning_model"), .string("ui.appearance_mode")])])

		XCTAssertTrue(text.contains("- **Operation**: `get` • 2 values"))
		XCTAssertTrue(text.contains("| Key | Value |"))
		XCTAssertTrue(text.contains("| `models.planning_model` | *null* |"))
		XCTAssertTrue(text.contains("| `ui.appearance_mode` | `\"Dark\"` |"))
	}

	func testGetLargeResultFallsBackToGroupedBulletsAndCapsRows() throws {
		let values = (1...50).reduce(into: [String: Value]()) { partial, index in
			let prefix = index <= 25 ? "ui" : "models"
			partial[String(format: "\(prefix).setting_%02d", index)] = .int(index)
		}
		let value: Value = .object([
			"op": .string("get"),
			"status": .string("ok"),
			"count": .int(50),
			"values": .object(values)
		])

		let text = render(value, args: ["op": .string("get"), "group": .string("ui")])

		XCTAssertTrue(text.contains("### models"))
		XCTAssertTrue(text.contains("### ui"))
		XCTAssertTrue(text.contains("…and 10 more values"))
		XCTAssertFalse(text.contains("| Key | Value |"))
	}

	func testSetChangedRendersOldToNewAndSideEffect() throws {
		let value: Value = .object([
			"op": .string("set"),
			"status": .string("ok"),
			"key": .string("ui.appearance_mode"),
			"old_value": .string("System"),
			"new_value": .string("Dark"),
			"changed": .bool(true),
			"applied": .bool(true),
			"side_effect": .string("applies_immediately")
		])

		let text = render(value, args: ["op": .string("set"), "key": .string("ui.appearance_mode"), "value": .string("Dark")])

		XCTAssertTrue(text.contains("- **Old → New**: `\"System\"` → `\"Dark\"`"))
		XCTAssertTrue(text.contains("- **Side effect**: applies immediately to all windows"))
	}

	func testSetLongStringsPreviewAndWarnsWhenUnapplied() throws {
		let old = String(repeating: "old ", count: 40)
		let new = String(repeating: "new ", count: 40)
		let value: Value = .object([
			"op": .string("set"),
			"status": .string("ok"),
			"key": .string("models.custom_planning_prompt"),
			"old_value": .string(old),
			"new_value": .string(new),
			"changed": .bool(true),
			"applied": .bool(false)
		])

		let text = render(value, args: ["op": .string("set"), "key": .string("models.custom_planning_prompt"), "value": .string(new)])

		XCTAssertTrue(text.contains("## App Settings ⚠️"))
		XCTAssertTrue(text.contains("old old"))
		XCTAssertTrue(text.contains("new new"))
		XCTAssertTrue(text.contains("(…+"))
		XCTAssertTrue(text.contains("### Warning"))
		XCTAssertTrue(text.contains("change reported as unapplied"))
	}

	func testSetUnchangedOmitsNoopSideEffect() throws {
		let value: Value = .object([
			"op": .string("set"),
			"status": .string("ok"),
			"key": .string("ui.show_tooltips"),
			"old_value": .bool(true),
			"new_value": .bool(true),
			"changed": .bool(false),
			"applied": .bool(false),
			"side_effect": .string("noop")
		])

		let text = render(value, args: ["op": .string("set"), "key": .string("ui.show_tooltips"), "value": .bool(true)])

		XCTAssertTrue(text.contains("- **Changed**: no (value unchanged)"))
		XCTAssertTrue(text.contains("- **Current**: `true`"))
		XCTAssertFalse(text.contains("Side effect"))
	}

	func testPrePolishEnvelopeRendersWithoutWritableField() throws {
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"read_only": .bool(false),
			"supports_set": .bool(true),
			"groups": .array([.string("ui")]),
			"count": .int(1),
			"settings": .array([
				setting(key: "ui.show_tooltips", group: "ui", type: "boolean", description: "Show helpful tooltips.", writable: true)
			])
		])

		let text = render(value, args: ["op": .string("list")])

		XCTAssertTrue(text.contains("`ui.show_tooltips`"))
		XCTAssertFalse(text.contains("writable"))
		XCTAssertFalse(text.contains("Side effect"))
	}

	func testListRendersOptionsAvailableHint() throws {
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"groups": .array([.string("models")]),
			"count": .int(1),
			"settings": .array([
				.object([
					"key": .string("models.planning_model"),
					"group": .string("models"),
					"type": .string("string|null"),
					"description": .string("Preferred planning/Oracle model raw identifier, if set."),
					"options_available": .bool(true)
				])
			])
		])

		let text = render(value, args: ["op": .string("list"), "group": .string("models")])

		XCTAssertTrue(text.contains("`models.planning_model`"))
		XCTAssertTrue(text.contains("op=options"))
		XCTAssertTrue(text.contains("key=models.planning_model"))
	}

	func testListRendersLabelWhenPresent() throws {
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"groups": .array([.string("models")]),
			"count": .int(1),
			"settings": .array([
				.object([
					"key": .string("models.planning_model"),
					"group": .string("models"),
					"label": .string("Oracle Model"),
					"type": .string("string|null"),
					"description": .string("Preferred Oracle model raw identifier, if set.")
				])
			])
		])

		let text = render(value, args: ["op": .string("list"), "group": .string("models")])

		XCTAssertTrue(text.contains("- `models.planning_model` — **Oracle Model** (string|null) — Preferred Oracle model raw identifier, if set."))
	}

	func testListOmitsLabelWhenAbsent() throws {
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"groups": .array([.string("ui")]),
			"count": .int(1),
			"settings": .array([
				setting(key: "ui.show_tooltips", group: "ui", type: "boolean", description: "Whether RepoPrompt shows app tooltips.")
			])
		])

		let text = render(value, args: ["op": .string("list"), "group": .string("ui")])

		XCTAssertTrue(text.contains("- `ui.show_tooltips` (bool) — Whether RepoPrompt shows app tooltips."))
		XCTAssertFalse(text.contains("`ui.show_tooltips` — **"))
	}

	func testListDetailedFalseRendersCompactCatalogWithoutDescriptionsLabelsOrFormatHints() throws {
		let value: Value = .object([
			"op": .string("list"),
			"status": .string("ok"),
			"detailed": .bool(false),
			"groups": .array([.string("file_system"), .string("models")]),
			"count": .int(2),
			"settings": .array([
				.object([
					"key": .string("file_system.respect_gitignore"),
					"group": .string("file_system"),
					"type": .string("boolean"),
					"description": .string("Whether RepoPrompt honors .gitignore files while scanning workspace folders."),
					"value": .bool(true)
				]),
				.object([
					"key": .string("models.planning_model"),
					"group": .string("models"),
					"label": .string("Oracle Model"),
					"type": .string("string|null"),
					"description": .string("Preferred Oracle model raw identifier, if set."),
					"value": .null,
					"value_format": .string("Raw model identifier."),
					"options_available": .bool(true)
				])
			])
		])

		let text = render(value, args: ["op": .string("list"), "detailed": .bool(false)])

		XCTAssertTrue(text.contains("- `file_system.respect_gitignore` (bool) = `true`"))
		XCTAssertTrue(text.contains("- `models.planning_model` (string|null) = *null*"))
		XCTAssertFalse(text.contains("Whether RepoPrompt honors"))
		XCTAssertFalse(text.contains("Preferred Oracle model"))
		XCTAssertFalse(text.contains("**Oracle Model**"))
		XCTAssertFalse(text.contains("current:"))
		XCTAssertFalse(text.contains("format:"))
		XCTAssertFalse(text.contains("Options: call"))
	}

	func testOptionsRendersCandidateTableAndNullableHint() throws {
		let value: Value = .object([
			"op": .string("options"),
			"status": .string("ok"),
			"key": .string("models.planning_model"),
			"type": .string("string|null"),
			"source": .string("ai_model_catalog"),
			"generated_at": .string("2026-04-20T10:55:04Z"),
			"nullable": .bool(true),
			"clear_value": .null,
			"exhaustive": .bool(false),
			"limit": .int(60),
			"count": .int(2),
			"total_count": .int(2),
			"truncated": .bool(false),
			"options": .array([
				.object([
					"value": .string("gpt-5.4-codex-medium"),
					"label": .string("Codex CLI GPT-5.4 Medium"),
					"group": .string("codex"),
					"group_label": .string("Codex CLI"),
					"provider": .string("codex"),
					"provider_name": .string("Codex CLI"),
					"available": .bool(true)
				]),
				.object([
					"value": .string("sonnet-4"),
					"label": .string("Claude Code Sonnet 4"),
					"group": .string("claudeCode"),
					"group_label": .string("Claude Code"),
					"provider": .string("claudeCode"),
					"provider_name": .string("Claude Code"),
					"available": .bool(true)
				])
			]),
			"notes": .array([
				.string("These are current AIModel raw-value candidates; custom raw identifiers may still be accepted by app_settings op='set'."),
				.string("Task labels such as explore/engineer/pair/design and agent compound IDs are not valid values for this setting.")
			])
		])

		let text = render(value, args: ["op": .string("options"), "key": .string("models.planning_model")])

		XCTAssertTrue(text.contains("## App Settings Options ✅"))
		XCTAssertTrue(text.contains("`models.planning_model`"))
		XCTAssertTrue(text.contains("ai_model_catalog"))
		XCTAssertTrue(text.contains("clear with `value=null`"))
		XCTAssertTrue(text.contains("| Value | Label | Group | Default |"))
		XCTAssertTrue(text.contains("gpt-5.4-codex-medium"))
		XCTAssertTrue(text.contains("Codex CLI GPT-5.4 Medium"))
		XCTAssertTrue(text.contains("Codex CLI"))
		XCTAssertTrue(text.contains("Claude Code"))
		XCTAssertTrue(text.contains("Task labels"))
	}

	func testOptionsRendersTruncationHint() throws {
		let value: Value = .object([
			"op": .string("options"),
			"status": .string("ok"),
			"key": .string("models.planning_model"),
			"type": .string("string|null"),
			"source": .string("ai_model_catalog"),
			"generated_at": .string("2026-04-20T10:55:04Z"),
			"nullable": .bool(true),
			"clear_value": .null,
			"exhaustive": .bool(false),
			"limit": .int(2),
			"count": .int(2),
			"total_count": .int(8),
			"truncated": .bool(true),
			"options": .array([
				.object([
					"value": .string("gpt-5.4-codex-medium"),
					"label": .string("Codex CLI GPT-5.4 Medium"),
					"group": .string("codex"),
					"group_label": .string("Codex CLI"),
					"provider": .string("codex"),
					"provider_name": .string("Codex CLI"),
					"available": .bool(true)
				]),
				.object([
					"value": .string("sonnet-4"),
					"label": .string("Claude Code Sonnet 4"),
					"group": .string("claudeCode"),
					"group_label": .string("Claude Code"),
					"provider": .string("claudeCode"),
					"provider_name": .string("Claude Code"),
					"available": .bool(true)
				])
			])
		])

		let text = render(value, args: ["op": .string("options"), "key": .string("models.planning_model"), "limit": .int(2)])

		XCTAssertTrue(text.contains("2 of 8 shown"))
		XCTAssertTrue(text.contains("Result truncated by limit"))
		XCTAssertTrue(text.contains("Increase `limit`"))
		XCTAssertTrue(text.contains("filter by `agent`"))
	}

	func testOptionsDetailedRendersRichCandidateFields() throws {
		let value: Value = .object([
			"op": .string("options"),
			"status": .string("ok"),
			"key": .string("models.planning_model"),
			"type": .string("string|null"),
			"source": .string("ai_model_catalog"),
			"generated_at": .string("2026-04-20T10:55:04Z"),
			"nullable": .bool(true),
			"clear_value": .null,
			"exhaustive": .bool(false),
			"limit": .int(60),
			"count": .int(2),
			"total_count": .int(2),
			"truncated": .bool(false),
			"options": .array([
				.object([
					"value": .string("gpt-5.4-codex-medium"),
					"label": .string("Codex CLI GPT-5.4 Medium"),
					"group": .string("codex"),
					"group_label": .string("Codex CLI"),
					"provider": .string("codex"),
					"provider_name": .string("Codex CLI"),
					"available": .bool(true),
					"description": .string("  Flagship Codex model with medium reasoning depth.  "),
					"reasoning_effort": .string("medium"),
					"context_window_tokens": .int(400000),
					"tags": .array([.string("fast"), .string("inline")])
				]),
				.object([
					"value": .string("sonnet-4"),
					"label": .string("Claude Code Sonnet 4"),
					"group": .string("claudeCode"),
					"group_label": .string("Claude Code"),
					"provider": .string("claudeCode"),
					"provider_name": .string("Claude Code"),
					"available": .bool(true),
					"description": .string("Balanced coder with strong tool use."),
					"reasoning_effort": .string("high"),
					"context_window_tokens": .int(200000),
					"tags": .array([])
				])
			])
		])

		let text = render(value, args: ["op": .string("options"), "key": .string("models.planning_model"), "detailed": .bool(true)])

		// Compact table is still emitted.
		XCTAssertTrue(text.contains("| Value | Label | Group | Default |"))
		XCTAssertTrue(text.contains("gpt-5.4-codex-medium"))

		// New per-candidate detail section surfaces the richer fields.
		XCTAssertTrue(text.contains("### Details"))
		XCTAssertTrue(text.contains("#### Codex CLI GPT-5.4 Medium — `\"gpt-5.4-codex-medium\"`"))
		XCTAssertTrue(text.contains("- **Description**: Flagship Codex model with medium reasoning depth."))
		// Description whitespace is trimmed rather than breaking the bullet.
		XCTAssertFalse(text.contains("  Flagship"))
		XCTAssertTrue(text.contains("- **Reasoning effort**: `medium`"))
		XCTAssertTrue(text.contains("- **Context window**: 400,000 tokens"))
		XCTAssertTrue(text.contains("- **Tags**: fast, inline"))

		XCTAssertTrue(text.contains("#### Claude Code Sonnet 4 — `\"sonnet-4\"`"))
		XCTAssertTrue(text.contains("- **Description**: Balanced coder with strong tool use."))
		XCTAssertTrue(text.contains("- **Reasoning effort**: `high`"))
		XCTAssertTrue(text.contains("- **Context window**: 200,000 tokens"))
		// Empty tags array still renders the row so readers can tell the field was present.
		XCTAssertTrue(text.contains("- **Tags**: —"))
	}

	func testOptionsWithoutDetailedFieldsOmitsDetailsSection() throws {
		let value: Value = .object([
			"op": .string("options"),
			"status": .string("ok"),
			"key": .string("models.planning_model"),
			"type": .string("string|null"),
			"source": .string("ai_model_catalog"),
			"generated_at": .string("2026-04-20T10:55:04Z"),
			"nullable": .bool(true),
			"clear_value": .null,
			"exhaustive": .bool(false),
			"limit": .int(60),
			"count": .int(1),
			"total_count": .int(1),
			"truncated": .bool(false),
			"options": .array([
				.object([
					"value": .string("gpt-5.4-codex-medium"),
					"label": .string("Codex CLI GPT-5.4 Medium"),
					"group": .string("codex"),
					"group_label": .string("Codex CLI"),
					"provider": .string("codex"),
					"provider_name": .string("Codex CLI"),
					"available": .bool(true)
				])
			])
		])

		let text = render(value, args: ["op": .string("options"), "key": .string("models.planning_model")])

		XCTAssertTrue(text.contains("| Value | Label | Group | Default |"))
		XCTAssertFalse(text.contains("### Details"))
		XCTAssertFalse(text.contains("**Reasoning effort**"))
		XCTAssertFalse(text.contains("**Context window**"))
		XCTAssertFalse(text.contains("**Tags**"))
	}

	func testErrorEnvelopeRendersAppSettingsFailureWithSetTroubleshooting() throws {
		let value: Value = .object([
			"op": .string("set"),
			"status": .string("error"),
			"key": .string("ui.appearance_mode"),
			"error": .string("Invalid value for 'ui.appearance_mode'. Allowed values: System, Light, Dark.")
		])

		let text = render(value, args: ["op": .string("set"), "key": .string("ui.appearance_mode"), "value": .string("Blue")])

		XCTAssertTrue(text.contains("## App Settings Failed ❌"))
		XCTAssertTrue(text.contains("Key: `ui.appearance_mode`"))
		XCTAssertTrue(text.contains("Allowed values: System, Light, Dark"))
		XCTAssertTrue(text.contains("1. Re-run with a supported value from the allowlist."))
		XCTAssertTrue(text.contains("2. For JSON payloads"))
	}

	private func render(_ value: Value, args: [String: Value] = ["op": .string("list")]) -> String {
		let blocks = ToolOutputFormatter.buildContentBlocks(
			toolName: "app_settings",
			args: args,
			result: value,
			emitResources: false
		)
		return blocks.compactMap { block -> String? in
			if case .text(let text, _, _) = block { return text }
			return nil
		}.joined(separator: "\n")
	}

	private func setting(
		key: String,
		group: String,
		type: String,
		description: String = "A setting.",
		allowed: [String]? = nil,
		writable: Bool? = nil
	) -> Value {
		var object: [String: Value] = [
			"key": .string(key),
			"group": .string(group),
			"type": .string(type),
			"description": .string(description)
		]
		if let allowed {
			object["allowed_values"] = .array(allowed.map(Value.string))
		}
		if let writable {
			object["writable"] = .bool(writable)
		}
		return .object(object)
	}
}
