import XCTest
@testable import RepoPrompt

/// Generates all meaningful variants of agent mode prompts for visual inspection.
///
/// Run with: `xcodetester test RepoPromptTests/AgentModePromptVariantsTests`
///
/// Each test prints its prompt variant to stdout (visible in test logs) and also writes
/// all variants to a combined file for easy side-by-side comparison.
final class AgentModePromptVariantsTests: XCTestCase {

	// MARK: - Variant matrix

	/// The interesting combinations of (taskLabelKind, agentKind) to generate.
	/// We skip exhaustive cross-product and focus on the combos that actually differ.
	private struct PromptVariant {
		let label: String
		let taskLabelKind: AgentModelCatalog.TaskLabelKind?
		let agentKind: DiscoverAgentKind?
		let includeWaitTool: Bool
		let includeShareThoughts: Bool
	}

	private static let claudeFamilyAgentKinds: [DiscoverAgentKind] = [
		.claudeCode,
		.claudeCodeGLM,
		.kimiCode,
		.customClaudeCompatible,
	]

	private static let variants: [PromptVariant] = [
		// --- Standard (no role) ---
		PromptVariant(label: "standard_claude", taskLabelKind: nil, agentKind: .claudeCode, includeWaitTool: false, includeShareThoughts: false),
		PromptVariant(label: "standard_codex", taskLabelKind: nil, agentKind: .codexExec, includeWaitTool: false, includeShareThoughts: false),
		PromptVariant(label: "standard_gemini", taskLabelKind: nil, agentKind: .gemini, includeWaitTool: false, includeShareThoughts: false),

		// --- Explore role ---
		PromptVariant(label: "explore_claude", taskLabelKind: .explore, agentKind: .claudeCode, includeWaitTool: false, includeShareThoughts: false),
		PromptVariant(label: "explore_codex", taskLabelKind: .explore, agentKind: .codexExec, includeWaitTool: false, includeShareThoughts: false),
		PromptVariant(label: "explore_gemini", taskLabelKind: .explore, agentKind: .gemini, includeWaitTool: false, includeShareThoughts: false),

		// --- Engineer role ---
		PromptVariant(label: "engineer_claude", taskLabelKind: .engineer, agentKind: .claudeCode, includeWaitTool: false, includeShareThoughts: false),
		PromptVariant(label: "engineer_codex", taskLabelKind: .engineer, agentKind: .codexExec, includeWaitTool: false, includeShareThoughts: false),
		PromptVariant(label: "engineer_gemini", taskLabelKind: .engineer, agentKind: .gemini, includeWaitTool: false, includeShareThoughts: false),

		// --- Pair role (should match standard) ---
		PromptVariant(label: "pair_claude", taskLabelKind: .pair, agentKind: .claudeCode, includeWaitTool: false, includeShareThoughts: false),

		// --- Design role (should match standard) ---
		PromptVariant(label: "design_claude", taskLabelKind: .design, agentKind: .claudeCode, includeWaitTool: false, includeShareThoughts: false),
	]

	// MARK: - Generate all variants

	func testGenerateAllPromptVariants() {
		var allOutput = ""

		for variant in Self.variants {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: variant.agentKind,
				taskLabelKind: variant.taskLabelKind
			)

			let charCount = prompt.count
			let approxTokens = charCount / 4 // rough estimate

			let header = """
			╔══════════════════════════════════════════════════════════════════════════╗
			║  VARIANT: \(variant.label.padding(toLength: 60, withPad: " ", startingAt: 0)) ║
			║  role=\((variant.taskLabelKind?.rawValue ?? "nil").padding(toLength: 12, withPad: " ", startingAt: 0)) agent=\((variant.agentKind?.rawValue ?? "nil").padding(toLength: 16, withPad: " ", startingAt: 0)) waitTool=\(variant.includeWaitTool)  ║
			║  chars=\(String(charCount).padding(toLength: 8, withPad: " ", startingAt: 0)) ~tokens=\(String(approxTokens).padding(toLength: 8, withPad: " ", startingAt: 0))                                    ║
			╚══════════════════════════════════════════════════════════════════════════╝
			"""

			let section = "\(header)\n\n\(prompt)\n\n"
			allOutput += section

			// Print each variant for test log inspection
			print(section)
		}

		// Write combined output to temp file for easy inspection
		let outputPath = NSTemporaryDirectory() + "agent_mode_prompt_variants.txt"
		try? allOutput.write(toFile: outputPath, atomically: true, encoding: .utf8)
		print("\n📄 All variants written to: \(outputPath)\n")
	}

	// MARK: - Structural assertions

	/// Verify explore prompts do NOT mention tools that are hidden from explore agents.
	func testExplorePromptsOmitHiddenTools() {
		let forbiddenTerms = [
			"apply_edits",
			"file_actions",
			"agent_explore",
			"agent_run",
			"agent_manage",
			"ask_oracle",
			"oracle_chat_log",
			"context_builder",
			"manage_selection",
			"workspace_context",
		]

		for agentKind in [DiscoverAgentKind.claudeCode, .codexExec, .gemini] {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: agentKind,
				taskLabelKind: .explore
			)

			for term in forbiddenTerms {
				XCTAssertFalse(
					prompt.contains(term),
					"Explore prompt for \(agentKind.rawValue) should not mention '\(term)'"
				)
			}
		}
	}

	/// Verify engineer prompts do NOT mention full delegation but DO mention editing and scoped explore tools.
	func testEngineerPromptsOmitDelegationButKeepEditing() {
		let forbiddenTerms = ["agent_run", "agent_manage"]
		let requiredTerms = ["apply_edits", "file_actions", "ask_oracle", "agent_explore"]

		for agentKind in [DiscoverAgentKind.claudeCode, .codexExec, .gemini] {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: agentKind,
				taskLabelKind: .engineer
			)

			for term in forbiddenTerms {
				XCTAssertFalse(
					prompt.contains(term),
					"Engineer prompt for \(agentKind.rawValue) should not mention '\(term)'"
				)
			}
			for term in requiredTerms {
				XCTAssertTrue(
					prompt.contains(term),
					"Engineer prompt for \(agentKind.rawValue) should mention '\(term)'"
				)
			}
		}
	}

	/// Verify top-level (taskLabelKind == nil) prompts name `agent_run` / `agent_manage`
	/// but never `agent_explore`, which is hidden from top-level sessions by the MCP
	/// advertisement policy.
	func testTopLevelStandardPromptNamesAgentRunOnly() {
		for agentKind in Self.claudeFamilyAgentKinds {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: agentKind,
				taskLabelKind: nil
			)

			for term in ["apply_edits", "file_actions", "ask_oracle", "oracle_chat_log", "agent_run", "agent_manage"] {
				XCTAssertTrue(
					prompt.contains(term),
					"Top-level standard prompt for \(agentKind.rawValue) should mention '\(term)'"
				)
			}

			XCTAssertFalse(
				prompt.contains("agent_explore"),
				"Top-level standard prompt for \(agentKind.rawValue) must not name `agent_explore` — it is hidden from top-level sessions"
			)
		}
	}

	/// Verify non-explore sub-agent prompts (taskLabelKind == .pair / .design) name only
	/// `agent_explore` and do not mention `agent_run` / `agent_manage`, which are hidden
	/// from non-explore sub-agents by the MCP advertisement policy.
	func testSubAgentStandardPromptNamesAgentExploreOnly() {
		for agentKind in Self.claudeFamilyAgentKinds {
			for taskLabel in [AgentModelCatalog.TaskLabelKind.pair, .design] as [AgentModelCatalog.TaskLabelKind] {
				let prompt = SystemPromptService.agentModePrompt(
					agentKind: agentKind,
					taskLabelKind: taskLabel
				)

				for term in ["apply_edits", "file_actions", "ask_oracle", "oracle_chat_log", "agent_explore"] {
					XCTAssertTrue(
						prompt.contains(term),
						"Sub-agent prompt for \(agentKind.rawValue) (role=\(taskLabel.rawValue)) should mention '\(term)'"
					)
				}

				for term in ["agent_run", "agent_manage"] {
					XCTAssertFalse(
						prompt.contains(term),
						"Sub-agent prompt for \(agentKind.rawValue) (role=\(taskLabel.rawValue)) must not name '\(term)' — they are hidden by the advertisement policy"
					)
				}
			}
		}
	}

	/// Verify the export-delegation bullet names exactly one delegation tool per audience.
	/// A caller that sees `agent_run` must not be told about `agent_explore` and vice
	/// versa — the MCP advertisement policy never exposes both simultaneously to a given
	/// caller.
	func testExportDelegationBulletNamesCorrectToolPerAudience() {
		// Top-level agent session — should name agent_run, never agent_explore.
		let topLevelPrompt = SystemPromptService.agentModePrompt(
			agentKind: .claudeCode,
			taskLabelKind: nil
		)
		XCTAssertTrue(
			topLevelPrompt.contains("oracle_export_path"),
			"Top-level prompt should mention oracle_export_path export guidance"
		)
		XCTAssertTrue(
			topLevelPrompt.contains("`agent_run` `start` or `steer`"),
			"Top-level export guidance should name agent_run"
		)

		// Non-explore sub-agents — should name agent_explore, never agent_run.
		for taskLabel in [AgentModelCatalog.TaskLabelKind.pair, .design, .engineer] as [AgentModelCatalog.TaskLabelKind] {
			let prompt: String
			if taskLabel == .engineer {
				prompt = SystemPromptService.agentModePrompt(
					agentKind: .claudeCode,
					taskLabelKind: .engineer
				)
			} else {
				prompt = SystemPromptService.agentModePrompt(
					agentKind: .claudeCode,
					taskLabelKind: taskLabel
				)
			}
			XCTAssertTrue(
				prompt.contains("oracle_export_path"),
				"Sub-agent prompt (role=\(taskLabel.rawValue)) should mention oracle_export_path"
			)
			XCTAssertTrue(
				prompt.contains("`agent_explore` `start`"),
				"Sub-agent prompt (role=\(taskLabel.rawValue)) should name agent_explore in export guidance"
			)
			XCTAssertFalse(
				prompt.contains("`agent_run`"),
				"Sub-agent prompt (role=\(taskLabel.rawValue)) must not name agent_run anywhere"
			)
		}
	}

	/// Verify no LLM-facing prompt variant uses the verb `paste`, which is not an
	/// operation an LLM can perform. All export-sharing copy should use include/insert/
	/// embed/reference/quote instead.
	func testNoLlmFacingPromptUsesPasteVerb() {
		let variants: [(label: String, prompt: String)] = [
			("standard_claude", SystemPromptService.agentModePrompt(agentKind: .claudeCode, taskLabelKind: nil)),
			("explore_claude", SystemPromptService.agentModePrompt(agentKind: .claudeCode, taskLabelKind: .explore)),
			("engineer_claude", SystemPromptService.agentModePrompt(agentKind: .claudeCode, taskLabelKind: .engineer)),
			("pair_claude", SystemPromptService.agentModePrompt(agentKind: .claudeCode, taskLabelKind: .pair)),
			("design_claude", SystemPromptService.agentModePrompt(agentKind: .claudeCode, taskLabelKind: .design)),
		]

		for variant in variants {
			let lowered = variant.prompt.lowercased()
			for verb in [" paste ", " pasted ", " pasting ", "paste the", "paste it", "paste them", "paste this"] {
				XCTAssertFalse(
					lowered.contains(verb),
					"Variant '\(variant.label)' must not use the paste verb ('\(verb)')"
				)
			}
		}
	}

	/// The `Fragments.exportDelegationGuidance(for:)` helper should emit exactly one
	/// delegation tool per audience, matching the `ExportDelegationAudience` enum.
	/// `.none` must return an empty string.
	func testExportDelegationGuidanceFragmentMatchesAudience() {
		let runOnly = AgentModePrompts.Fragments.exportDelegationGuidance(for: .agentRunOnly)
		XCTAssertTrue(runOnly.contains("agent_run"))
		XCTAssertFalse(runOnly.contains("agent_explore"))
		XCTAssertFalse(runOnly.lowercased().contains("paste"))

		let exploreOnly = AgentModePrompts.Fragments.exportDelegationGuidance(for: .agentExploreOnly)
		XCTAssertTrue(exploreOnly.contains("agent_explore"))
		XCTAssertFalse(exploreOnly.contains("agent_run"))
		XCTAssertFalse(exploreOnly.lowercased().contains("paste"))

		let both = AgentModePrompts.Fragments.exportDelegationGuidance(for: .both)
		XCTAssertTrue(both.contains("agent_run"))
		XCTAssertTrue(both.contains("agent_explore"))
		XCTAssertFalse(both.lowercased().contains("paste"))

		XCTAssertEqual(
			AgentModePrompts.Fragments.exportDelegationGuidance(for: .none),
			"",
			".none audience must emit no guidance (explore/discover/delegate-edit surfaces cannot delegate)"
		)
	}

	/// Verify the explore prompt has no export-delegation wording — explore agents
	/// cannot produce or dispatch exports because ask_oracle / oracle_send /
	/// context_builder and agent_run / agent_explore are all hidden from them.
	func testExplorePromptHasNoDelegationWording() {
		for agentKind in [DiscoverAgentKind.claudeCode, .codexExec, .gemini] {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: agentKind,
				taskLabelKind: .explore
			)
			for term in ["oracle_export_path", "oracle_export_instruction", "delegated-agent", "delegated agent"] {
				XCTAssertFalse(
					prompt.contains(term),
					"Explore prompt for \(agentKind.rawValue) must not mention '\(term)'"
				)
			}
		}
	}

	/// Verify explore prompts are significantly shorter than standard prompts.
	func testExplorePromptIsLeaner() {
		let standardPrompt = SystemPromptService.agentModePrompt(
			agentKind: .claudeCode,
			taskLabelKind: nil
		)
		let explorePrompt = SystemPromptService.agentModePrompt(
			agentKind: .claudeCode,
			taskLabelKind: .explore
		)

		// Explore should be meaningfully shorter — at least 40% smaller
		let ratio = Double(explorePrompt.count) / Double(standardPrompt.count)
		XCTAssertLessThan(ratio, 0.6, "Explore prompt should be significantly leaner than standard (ratio: \(String(format: "%.2f", ratio)))")
		print("📏 Explore/Standard ratio: \(String(format: "%.2f", ratio)) (explore=\(explorePrompt.count) chars, standard=\(standardPrompt.count) chars)")
	}

	/// Verify engineer prompts contain the precision-execution framing.
	func testEngineerPromptContainsPrecisionFraming() {
		let prompt = SystemPromptService.agentModePrompt(
			agentKind: .claudeCode,
			taskLabelKind: .engineer
		)

		XCTAssertTrue(prompt.contains("ENGINEER MODE"))
		XCTAssertTrue(prompt.contains("Execute exactly what is asked"))
		XCTAssertTrue(prompt.contains("set_status"))
	}

	/// Verify explore prompt contains the read-only framing and references available tools.
	func testExplorePromptContainsReadOnlyFraming() {
		let prompt = SystemPromptService.agentModePrompt(
			agentKind: .claudeCode,
			taskLabelKind: .explore
		)

		XCTAssertTrue(prompt.contains("read-only explore agent"))
		XCTAssertTrue(prompt.contains("cannot edit files"))
		XCTAssertTrue(prompt.contains("set_status"))
		// Explore prompt should reference tools it CAN use in workflow guidance
		XCTAssertTrue(prompt.contains("file_search"))
		XCTAssertTrue(prompt.contains("read_file"))
		XCTAssertTrue(prompt.contains("get_file_tree"))
		XCTAssertTrue(prompt.contains("get_code_structure"))
		XCTAssertTrue(prompt.contains("Shell use (read-only only)"))
		XCTAssertTrue(prompt.contains("Claude's native `Bash` tool"))
		XCTAssertTrue(prompt.contains("Do not use shell commands that create, modify, delete, move, format, patch, install dependencies, change git state, or start long-running services"))
		// Should have anti-patterns section
		XCTAssertTrue(prompt.contains("Anti-patterns"))
		XCTAssertTrue(prompt.contains("Using shell/Bash commands that mutate files"))
	}

	func testCodexExplorePromptContainsShellReadOnlyGuidance() {
		let prompt = SystemPromptService.agentModePrompt(
			agentKind: .codexExec,
			taskLabelKind: .explore
		)

		XCTAssertTrue(prompt.contains("Shell use (read-only only)"))
		XCTAssertTrue(prompt.contains("native shell/Bash"))
		XCTAssertTrue(prompt.contains("Do not use shell commands that create, modify, delete, move, format, patch, install dependencies, change git state, or start long-running services"))
		XCTAssertTrue(prompt.contains("Using shell/Bash commands that mutate files"))
	}

	func testCodeMapsDisabledPromptVariantsDoNotAdvertiseGetCodeStructure() {
		for variant in Self.variants {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: variant.agentKind,
				taskLabelKind: variant.taskLabelKind,
				codeMapsDisabled: true
			)
			XCTAssertFalse(
				prompt.contains("get_code_structure"),
				"Disabled Code Maps prompt variant \(variant.label) should not advertise get_code_structure"
			)
			XCTAssertTrue(prompt.contains("file_search"))
			XCTAssertTrue(prompt.contains("read_file") || prompt.contains("RepoPrompt__read_file"))
		}
	}

	/// Verify Codex variants name the exact MCP tool for session naming with positive tool-call guidance.
	func testCodexVariantsUseExplicitSetStatusToolName() {
		for taskLabel in AgentModelCatalog.TaskLabelKind.allCases + [nil] as [AgentModelCatalog.TaskLabelKind?] {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: .codexExec,
				taskLabelKind: taskLabel
			)

			XCTAssertTrue(
				prompt.contains("mcp__RepoPrompt__set_status"),
				"Codex variant (role=\(taskLabel?.rawValue ?? "nil")) should name the exact RepoPrompt MCP set_status tool"
			)
			XCTAssertTrue(
				prompt.contains("RepoPrompt MCP tool call"),
				"Codex variant (role=\(taskLabel?.rawValue ?? "nil")) should describe set_status as a RepoPrompt MCP tool call"
			)
			XCTAssertFalse(
				prompt.lowercased().contains("bash/shell"),
				"Codex variant (role=\(taskLabel?.rawValue ?? "nil")) should use positive tool-call guidance instead of shell warnings"
			)
			XCTAssertFalse(
				prompt.lowercased().contains("session-title command"),
				"Codex variant (role=\(taskLabel?.rawValue ?? "nil")) should avoid shell-command-oriented session title wording"
			)
		}
	}

	func testCodexStandardPromptClarifiesNativeSpawnAgentBoundary() {
		let prompt = SystemPromptService.agentModePrompt(
			agentKind: .codexExec,
			taskLabelKind: nil
		)

		XCTAssertTrue(prompt.contains("Codex MultiAgentV2 `spawn_agent` children are Codex-native threads"))
		XCTAssertTrue(prompt.contains("not RepoPrompt-managed `mcp__RepoPrompt__agent_run` sessions"))
		XCTAssertTrue(prompt.contains("do not expect `spawn_agent` children to appear in `mcp__RepoPrompt__agent_manage`"))
		XCTAssertTrue(prompt.contains("unless RepoPrompt adds an explicit bridge"))

		for taskLabel in [AgentModelCatalog.TaskLabelKind.engineer, .pair, .design] {
			let subAgentPrompt = SystemPromptService.agentModePrompt(
				agentKind: .codexExec,
				taskLabelKind: taskLabel
			)
			XCTAssertFalse(
				subAgentPrompt.contains("spawn_agent"),
				"Codex sub-agent prompt for \(taskLabel.rawValue) should not name Codex-native delegation tools it cannot manage through RepoPrompt"
			)
		}
	}

	func testCodexVariantsQualifyCommonRepoPromptToolRecommendations() {
		let standardPrompt = SystemPromptService.agentModePrompt(
			agentKind: .codexExec,
			taskLabelKind: nil
		)
		for toolName in [
			"file_search",
			"read_file",
			"get_code_structure",
			"apply_edits",
			"file_actions",
			"manage_selection",
			"prompt",
			"workspace_context",
			"ask_oracle",
			"oracle_chat_log",
			"agent_run",
			"agent_manage",
			"ask_user",
			"set_status",
		] {
			XCTAssertTrue(
				standardPrompt.contains("mcp__RepoPrompt__\(toolName)"),
				"Codex standard prompt should qualify RepoPrompt MCP tool '\(toolName)'"
			)
			XCTAssertFalse(
				standardPrompt.contains("`\(toolName)`"),
				"Codex standard prompt should not leave bare backticked tool '\(toolName)'"
			)
		}

		let engineerPrompt = SystemPromptService.agentModePrompt(
			agentKind: .codexExec,
			taskLabelKind: .engineer
		)
		XCTAssertTrue(engineerPrompt.contains("mcp__RepoPrompt__agent_explore"))
		XCTAssertFalse(engineerPrompt.contains("`agent_explore`"))
	}

	func testNonCodexVariantsDoNotUseCodexSetStatusToolName() {
		for agentKind in Self.claudeFamilyAgentKinds + [DiscoverAgentKind.gemini] {
			for taskLabel in AgentModelCatalog.TaskLabelKind.allCases + [nil] as [AgentModelCatalog.TaskLabelKind?] {
				let prompt = SystemPromptService.agentModePrompt(
					agentKind: agentKind,
					taskLabelKind: taskLabel
				)

				XCTAssertFalse(
					prompt.contains("mcp__RepoPrompt__set_status"),
					"Non-Codex variant for \(agentKind.rawValue) (role=\(taskLabel?.rawValue ?? "nil")) should keep provider-native set_status wording"
				)
			}
		}
	}

	/// Verify Gemini variants no longer advertise removed tools but still advertise set_status.
	func testGeminiVariantsAdvertiseSetStatusButNotRemovedReasoningTools() {
		for taskLabel in AgentModelCatalog.TaskLabelKind.allCases + [nil] as [AgentModelCatalog.TaskLabelKind?] {
			let prompt = SystemPromptService.agentModePrompt(
				agentKind: .gemini,
				taskLabelKind: taskLabel
			)

			XCTAssertTrue(
				prompt.contains("set_status"),
				"Gemini variant (role=\(taskLabel?.rawValue ?? "nil")) should mention set_status"
			)
			XCTAssertFalse(
				prompt.contains("wait_for_next_user_instruction"),
				"Gemini variant (role=\(taskLabel?.rawValue ?? "nil")) should not mention wait_for_next_user_instruction"
			)
			XCTAssertFalse(
				prompt.contains("share_thoughts"),
				"Gemini variant (role=\(taskLabel?.rawValue ?? "nil")) should not mention share_thoughts"
			)
		}
	}

	func testPromptExportCleanupGuidanceUsesAbsoluteDeletePaths() {
		let prompts = [
			ClaudeCodeCommands.rpOrchestrateCore(variant: .mcp),
			ClaudeCodeCommands.rpOptimizeCore(variant: .mcp),
			ClaudeCodeCommands.rpOptimizeCore(variant: .cli),
		]

		for prompt in prompts {
			XCTAssertTrue(prompt.contains("file_actions.delete` requires a true absolute filesystem path"))
			XCTAssertTrue(prompt.contains("/absolute/path/to/repo/prompt-exports/<stale-export>.md"))
			XCTAssertFalse(prompt.contains("\"path\":\"prompt-exports/<stale-export>.md\""))
		}
	}

	/// Verify Claude read policy appears in Claude variants for all roles.
	func testClaudeFamilyVariantsIncludeReadPolicy() {
		for agentKind in Self.claudeFamilyAgentKinds {
			for taskLabel in AgentModelCatalog.TaskLabelKind.allCases + [nil] as [AgentModelCatalog.TaskLabelKind?] {
				let prompt = SystemPromptService.agentModePrompt(
					agentKind: agentKind,
					taskLabelKind: taskLabel
				)

				XCTAssertTrue(
					prompt.contains("Read policy"),
					"Claude-family variant for \(agentKind.rawValue) (role=\(taskLabel?.rawValue ?? "nil")) should include read policy"
				)
			}
		}
	}
}
