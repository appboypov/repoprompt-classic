//
//  MCPPromptRegistry.swift
//  RepoPrompt
//
//  Registry of MCP prompt templates exposed via prompts/list and prompts/get.
//  These are workflow prompts that coding agents can invoke to get structured
//  guidance for common tasks like building features or investigating systems.
//

import Foundation
import MCP

/// Registry for MCP prompt templates.
/// Exposes RepoPrompt's built-in workflow prompts (rp-build, rp-investigate)
/// via the MCP prompts/list and prompts/get protocol methods.
enum MCPPromptRegistry {

	// MARK: - Prompt Definitions

	/// A prompt definition with metadata and template content.
	struct Definition: Sendable {
		let name: String
		let description: String
		let arguments: [Prompt.Argument]
		/// Template content with $ARGUMENTS placeholder for substitution
		let template: String
	}

	/// All available prompt definitions.
	/// These correspond to the slash commands in .claude/commands/
	static let definitions: [Definition] = [
		Definition(
			name: "rp-build",
			description: "Build with RepoPrompt MCP context_builder plan → implement. A structured workflow for implementing features using deep codebase context.",
			arguments: [
				Prompt.Argument(
					name: "task",
					description: "Description of the task or feature to implement",
					required: true
				)
			],
			template: ClaudeCodeCommands.rpBuild
		),
		Definition(
			name: "rp-investigate",
			description: "Deep investigation with RepoPrompt MCP tools. The agent gathers concrete evidence with tools, while chat/oracle synthesizes the selected context into hypotheses and architectural insight.",
			arguments: [
				Prompt.Argument(
					name: "issue",
					description: "Description of the topic or issue to investigate",
					required: true
				)
			],
			template: ClaudeCodeCommands.rpInvestigate
		),
		Definition(
			name: "rp-deep-plan",
			description: "Deep planning workflow that ends at a polished `docs/plans/<topic>-<YYYY-MM-DD>.md` document (no implementation). First action asks the user how involved they want to be (up front / mid-flow / hands-off). Then explore agents map seams + optional external research; context_builder produces architectural bones in plan mode with export_response; the orchestrator merges bones into the plan; a design agent does a bounded one-page critique; the orchestrator polishes into a tighter, executable document.",
			arguments: [
				Prompt.Argument(
					name: "topic",
					description: "Description of what to plan (feature, refactor, migration, redesign, etc.)",
					required: true
				)
			],
			template: ClaudeCodeCommands.rpDeepPlan
		),
		Definition(
			name: "rp-reminder",
			description: "Token-efficient reminder to use RepoPrompt MCP tools (file_search, read_file, apply_edits, file_actions) instead of built-in alternatives.",
			arguments: [],
			template: ClaudeCodeCommands.rpReminder
		),
		Definition(
			name: "rp-oracle-export",
			description: "Export a ChatGPT-ready prompt file. Determines whether the task is a Question, Plan, or Review (confirming only when needed), uses a fast path for simple tasks, reviews the selection/prompt, and writes a unique export file.",
			arguments: [
				Prompt.Argument(
					name: "problem",
					description: "Description of the problem or question to include in the exported ChatGPT prompt",
					required: true
				)
			],
			template: ClaudeCodeCommands.rpOracleExport
		),
		Definition(
			name: "rp-review",
			description: "Code review workflow using the git tool and context_builder. Assesses change scope, gathers context, and provides structured review feedback for PRs, commits, or uncommitted changes.",
			arguments: [
				Prompt.Argument(
					name: "scope",
					description: "What to review: 'uncommitted', 'staged', 'back:N' for last N commits, or a branch/commit range like 'main...HEAD'",
					required: false
				)
			],
			template: ClaudeCodeCommands.rpReview
		),
		Definition(
			name: "rp-refactor",
			description: "Refactoring assistant that analyzes code structure to identify duplication, complexity, and consolidation opportunities. Proposes safe, incremental improvements without changing core logic.",
			arguments: [
				Prompt.Argument(
					name: "target",
					description: "Files, directory, or system to analyze for refactoring (e.g., 'src/auth/', 'the payment module', or specific file paths)",
					required: false
				)
			],
			template: ClaudeCodeCommands.rpRefactor
		),
		Definition(
			name: "rp-orchestrate",
			description: "Plan, decompose, and delegate complex tasks across multiple agents. Coordinates planning, work breakdown, dispatch, monitoring, and final rollup.",
			arguments: [
				Prompt.Argument(
					name: "task",
					description: "Description of the complex task to plan, decompose, and delegate across agents",
					required: true
				)
			],
			template: ClaudeCodeCommands.rpOrchestrate
		),
		Definition(
			name: "rp-optimize",
			description: "Iterative performance optimization loop run as a delegation-first orchestration. Phase 1 fans out parallel explore agents to scout bottleneck candidates around the named target (callers, inputs, adjacent operations, shared infrastructure) plus surface mapping (target & call graph, prior perf work, conventions, scope). Phase 2 routes setup design (metric, instrumentation, first-pass candidates grounded in the bottleneck scouting) through context_builder in plan mode. Phase 3 dispatches a pair to land instrumentation and capture a multi-sample baseline. Phase 4 loops plan → dispatch pair for one optimize+harden cycle → re-measure → ask oracle for next plan until the oracle signals satisfaction, the target metric is met, or the iteration cap is reached.",
			arguments: [
				Prompt.Argument(
					name: "target",
					description: "Description of what to optimize (metric, scope, stop criterion if known) — e.g. 'reduce p95 latency of PathMatcher.match under PathMatchingTests'",
					required: true
				)
			],
			template: ClaudeCodeCommands.rpOptimize
		)
	]

	// MARK: - Public API

	/// Returns the list of available prompts for prompts/list.
	static func listPrompts() -> [Prompt] {
		definitions.map { def in
			Prompt(
				name: def.name,
				description: def.description,
				arguments: def.arguments
			)
		}
	}

	/// Gets a specific prompt with argument substitution for prompts/get.
	/// - Parameters:
	///   - name: The prompt name to retrieve
	///   - arguments: Optional arguments to substitute into the template
	/// - Returns: The prompt result with rendered messages
	/// - Throws: MCPError if the prompt is not found
	static func getPrompt(named name: String, arguments: [String: Value]?) throws -> GetPrompt.Result {
		guard let definition = definitions.first(where: { $0.name == name }) else {
			throw MCPError.invalidParams("Unknown prompt: \(name)")
		}

		let resolvedArgs = resolveArgumentsText(from: arguments, definition: definition)
		let renderedContent = definition.template.replacingOccurrences(of: "$ARGUMENTS", with: resolvedArgs)

		// Strip YAML frontmatter if present (between --- markers at the start)
		let cleanedContent = stripYAMLFrontmatter(from: renderedContent)

		return GetPrompt.Result(
			description: definition.description,
			messages: [
				.user(.text(text: cleanedContent))
			]
		)
	}

	// MARK: - Private Helpers

	/// Resolves arguments to a text string for $ARGUMENTS substitution.
	/// Looks for the primary argument first (task/issue), then falls back to
	/// joining all arguments.
	private static func resolveArgumentsText(from arguments: [String: Value]?, definition: Definition) -> String {
		guard let arguments = arguments, !arguments.isEmpty else {
			return ""
		}

		// Try the primary argument name first (the required one)
		if let primaryArg = definition.arguments.first(where: { $0.required == true }),
		   let value = arguments[primaryArg.name] {
			return extractStringValue(from: value)
		}

		// Fallback: try common argument names
		for key in ["task", "issue", "problem", "scope", "target", "arguments", "ARGUMENTS", "input", "query"] {
			if let value = arguments[key] {
				return extractStringValue(from: value)
			}
		}

		// Last resort: join all key-value pairs
		let sortedKeys = arguments.keys.sorted()
		let lines = sortedKeys.compactMap { key -> String? in
			guard let value = arguments[key] else { return nil }
			let stringValue = extractStringValue(from: value)
			return "\(key): \(stringValue)"
		}
		return lines.joined(separator: "\n")
	}

	/// Extracts a string value from an MCP Value.
	private static func extractStringValue(from value: Value) -> String {
		if let str = value.stringValue {
			return str
		}
		// For non-string values, use the description
		return String(describing: value)
	}

	/// Strips YAML frontmatter (content between --- markers at the start).
	private static func stripYAMLFrontmatter(from content: String) -> String {
		let lines = content.components(separatedBy: "\n")
		guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
			return content
		}

		// Find the closing ---
		var endIndex = 1
		while endIndex < lines.count {
			if lines[endIndex].trimmingCharacters(in: .whitespaces) == "---" {
				// Return everything after the frontmatter
				let remaining = lines.dropFirst(endIndex + 1)
				return remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			}
			endIndex += 1
		}

		// No closing --- found, return original
		return content
	}
}
