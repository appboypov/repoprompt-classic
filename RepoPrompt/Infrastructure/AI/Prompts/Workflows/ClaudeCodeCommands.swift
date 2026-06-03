import Foundation

/// Content for Claude Code skills installed by RepoPrompt.
/// These are written to `.claude/skills/<name>/SKILL.md` in workspace directories (folder-per-skill pattern).
/// Also used by MCPPromptRegistry and SystemPromptService for shared workflow content.
enum ClaudeCodeCommands {

	/// Bump when skill content changes.
	/// Version 2: Added embedded version markers to frontmatter, fixed CLI help reference.
	/// Version 3: Added rp-oracle-export command.
	/// Version 4: Added rp-review and rp-refactor commands.
	/// Version 5: Added anti-patterns and scoped down exploration before context_builder.
	/// Version 6: Added Phase 0 workspace verification, mandatory branch confirmation for review, CLI window routing. Renamed commands to skills, added .agents/skills support.
	/// Version 7: Migrated to folder/SKILL.md structure (.claude/skills/<name>/SKILL.md), added name field to frontmatter.
	/// Version 8: Redesigned rp-investigate to leverage agent/context-builder/oracle strengths, preserve selection, and encourage judicious oracle usage.
	/// Version 9: Refreshes installed ChatGPT Prompt Export / rp-oracle-export skill content after the naming and workflow text update.
	/// Version 10: Makes rp-build follow-up chat explicitly optional/targeted rather than a mandatory plan challenge step.
	/// Version 11: Clarifies rp-investigate capability boundaries so factual lookups stay with direct tool calls, not chat/oracle.
	/// Version 12: Tightens rp-build checklist wording and updates rp-investigate metadata to reflect tool-vs-chat boundaries.
	/// Version 13: Aligns rp-build with the measured architect tone: default trust the plan and only validate when a concrete question remains.
	/// Version 14: Clarifies rp-build chat/oracle boundaries and slims metadata to context-builder-plan → implement.
	/// Version 15: Removes redundant rp-build intro role/tool wording.
	/// Version 16: Updates rp-oracle-export to confirm Question/Plan/Review intent, reuse review scope confirmation, and refresh managed exports for the 160k ChatGPT budget/review-hotword flow.
	/// Version 17: Tightens review-shaped clarify instructions for rp-oracle-export and refreshes managed skills after the broader git/review hotword detection update.
	/// Version 18: Reworks rp-oracle-export around conversational intent clarification, a fast path for simple tasks, pre-export selection review, and unique repo-local prompt export paths.
	/// Version 19: Simplifies rp-oracle-export, restores correct agent/workflow structure, and tightens review guidance.
	/// Version 20: Tightens rp-oracle-export so broad Question/Plan exports go straight to context_builder instead of burning tool calls to prove complexity.
	/// Version 21: Tightens rp-oracle-export filename/path guidance so exports default to repo-local prompt-exports paths with request-derived slugs.
	/// Version 22: Skips redundant post-context_builder export re-checks in rp-oracle-export; keep manual selection/prompt review for fast-path exports only.
	/// Version 23: Treats context_builder output as the export prompt source of truth in rp-oracle-export; avoid critiquing or rewriting its generated prompt unless there is a concrete mismatch.
	/// Version 24: Adds `agents/openai.yaml` to managed skill folders so Codex disables implicit skill invocation for every managed skill except `rp-reminder`, which remains eligible for implicit invocation.
	/// Version 25: Quotes YAML frontmatter scalars so skill descriptions containing `:` remain valid for Codex skill parsing.
	/// Version 26: Keeps `rp-oracle-export` implicitly invokable alongside `rp-reminder`.
	/// Version 27: Reverts `rp-oracle-export` to explicit-only; only `rp-reminder` remains implicitly invokable.
	/// Version 28: Removes redundant 'review' word-choice warning; routes audits/evaluations to Plan intent instead of Review.
	/// Version 29: Makes CLI skill frontmatter names match their `*-cli` parent directories for strict skill validators.
	/// Version 30: Fixes prompt-inception bug in rp-oracle-export: strips export/prompt meta-framing from $ARGUMENTS before passing to context_builder, adds anti-pattern against leaking export intent into builder instructions, and defaults ambiguous/generic requests to Plan preset.
	/// Version 31: Adds rp-orchestrate workflow — plan, decompose, and delegate tasks across multiple agents.
	/// Version 32: Teaches rp-orchestrate to export Oracle responses for delegated agent handoff.
	/// Version 33: Slims oracle export format (title + response only), shortens filenames, adds export_response to context_builder, improves orchestrate dispatch scoping guidance.
	/// Version 34: Refreshes managed skills after supported skill changes so existing client setups reinstall current content.
	/// Version 35: Removes `oracle_export_path` parameter guidance from agent_run/agent_explore; rp-orchestrate and rp-refactor now reference exported plan paths inside message text.
	/// Version 36: Fixes CLI workflow examples to use builder --export and pass exported plan paths inside agent_run messages.
	/// Version 37: Replaces generic `agent_run / agent_explore` phrasing with capability-specific wording and removes the `paste` verb in export delegation guidance.
	/// Version 38: Reframes rp-investigate so explore agents are the primary evidence-gathering mechanism; main agent orchestrates and synthesizes instead of duplicating sub-agent reconnaissance.
	/// Version 39: Splits rp-investigate investigator agents into pair (main investigation line, deeper reasoning) + explore (parallel narrow checks); main agent dispatches both and orchestrates.
	/// Version 40: Reworks rp-orchestrate — contextualize-first Phase 1 with explore-agent escalation, fresh-agent-per-item dispatch default with Codex-aware `roles_only` escape hatch. Ports shared orchestration guidance into rp-refactor via 6 new helper blocks (decomposition, roles-only check, parallel dispatch, dispatch brief, final rollup, monitor-and-verify). Softens "CRITICAL"/"DO NOT" tone across rp-investigate, rp-refactor, rp-build, and rp-review; unifies plan-path references to `<plan path>`.
	/// Version 41: Tells rp-orchestrate to stick to the predefined role labels and not reason about specific underlying models unless the user names one — avoids speculative mapping across providers.
	/// Version 42: rp-investigate — sequence explore agents before the pair investigator (so its brief folds in their findings) and direct the pair, as lead investigator, to write findings into the investigation report file.
	/// Version 43: rp-investigate — explore agents are now used for pre-context_builder external info gathering (git/web/docs) and inside the pair investigator's own session; the main agent no longer runs a parallel explore fleet alongside the pair.
	/// Version 44: rp-investigate — adds optional parallel pair investigators for genuinely disjoint hypothesis paths (with disjoint scopes, distinct report sub-sections, and a 2–3 cap); clarifies where more parallelism does and doesn't pay off.
	/// Version 45: rp-investigate — upgrades pair investigator brief from passive permission to active encouragement to fan out explore agents for parallel reconnaissance.
	/// Version 46: rp-investigate — tightening pass: consolidates duplicated guidance, flattens Phase 3 subsections, merges Phase 1/1.5, rewrites file-selection guidance for the delegation model (pair reads don't populate main agent's selection; bias toward inclusion), adds termination criteria and builder-failure fallback, fixes Role Summary inconsistencies.
	/// Version 47: rp-orchestrate — Housekeeping section now also guides cleanup of stray plan/review exports under `prompt-exports/` so superseded or consumed export files don't accumulate across a multi-agent task.
	/// Version 48: rp-reminder — refresh for the current toolset: adds sections for context/planning tools (`manage_selection`, `context_builder`, `ask_oracle`, `workspace_context`, `prompt`, `oracle_chat_log`, `ask_user`, `git`) and agent delegation (`agent_run` / `agent_manage` with role labels explore/engineer/pair/design, fan-out + steer patterns, export handoff). Keeps the MCP/CLI variant split.
	/// Version 49: rp-reminder — drops the workflow-skills cross-reference table so the reminder doesn't nudge the agent to self-invoke other skills; those are user-invoked entry points.
	/// Version 50: rp-investigate — drop the pair-investigator tier. Main agent is the lead investigator and report author again; explore agents are reframed as liberal context-preserving pulses (external facts + narrow in-workspace side-questions) fanned out alongside the main line of inquiry rather than gated behind a delegation layer. Also drops the `## Investigator Findings` report section, the parallel-pair branch, the Phase 1/1.5 split, and pair-era anti-patterns/roles; trims Role Summary to four columns.
	/// Version 51: Adds rp-optimize — an app-agnostic iterative performance optimization loop built on orchestrate's scaffolding. Protocol: define target + stop criterion, instrument with debug-only metrics in secondary test/support files, capture a baseline per AGENTS.md testing protocols, then loop plan → dispatch pair for one optimize+harden cycle → re-measure → ask oracle for next plan, until oracle signals satisfaction, the metric target is met, or the iteration cap is reached.
	/// Version 52: Fixes the shared roles-only check used by rp-orchestrate and rp-refactor — the `codexExec:*` prefix never appears in the `roles_only=true` view, so guidance now keys off the `Codex CLI` display-name prefix (with `codexExec:*` kept as a fallback cue when inspecting an explicit compound `model_id`).
	/// Version 53: Reverts Version 50 — restores the pair-investigator tier in rp-investigate. Main agent returns to orchestrating (dispatches explore agents for…
	/// Version 54: Disables implicit invocation for the `rp-reminder-cli` skill so only the MCP `rp-reminder` variant remains auto-invocable; CLI variant is now explicit-only.
	/// Version 55: rp-optimize — restructures the workflow around delegation. Phase 1 fans out explore agents to map surface area (AGENTS.md/measurement conventions, hot-path location, existing benchmarks, scope boundaries) instead of the main agent doing the navigation. Phase 2 routes through `context_builder` in plan mode to produce the metric definition, instrumentation strategy, first-pass optimization candidates, and scoreboard scaffold in one pass. Phase 3 dispatches a pair agent to land instrumentation and capture the baseline (multi-sample with variance) so the main agent never runs measurements directly. Phase 4 keeps measurement and optimization fully delegated; main agent verifies via scoreboard reads and uses explore agents for deeper checks. Adds a role summary table.
	/// Version 56: rp-optimize — Phase 1 now does bottleneck scouting *around* the named target, not just locating it. Replaces the single "hot path" explore with three: target & call graph (locate + map callers with context), bottleneck candidates (scout target + callers + adjacent code for tight loops, per-iteration allocations, locking, redundant computation, expensive transformations, sync I/O on hot paths, O(n²) patterns; rank 2–3 with rationale), and prior perf work (existing benchmarks, profiler traces, sample reports, perf-related TODOs in the repo). Phase 1c synthesis adds a ranked candidate list as a fifth output. Phase 2's context_builder call now takes those bottleneck candidates and prior perf work as inputs so first-pass optimization candidates are evidence-grounded. Adds matching anti-pattern and role-summary row.
	/// Version 57: rp-optimize — leanness + drift pass per `docs/reviews/rp-optimize-skill-leanness-2026-04-27.md`. Reframes Phase 1a so full bottleneck fan-out is the explicit default and shortcuts are narrow exceptions (closes the v56 off-ramp). Drops sharedMonitorAndVerifyBlock from Phase 4d (it contradicted the surrounding "minimal direct reads" guidance) and replaces it with a one-line domain-specific reminder; same drop for sharedDispatchBriefGuidance in Phase 4c (the inline examples already model dispatch-brief patterns). Compresses Phase 1b's five near-identical agent_run example blobs to two representative ones plus a comment pointing to the table. Makes context_builder the explicit default in Phase 4a, removes the "or the oracle" parenthetical that lets readers drift off the candidate-queue plan format. Collapses duplicate anti-patterns (twins + recipe-restating bullets). Drops the Quick Reference table and one-cell padding rows from the Role Summary; key operations folded into the surrounding prose. Tightens the iteration cap to a hard 5 with explicit user opt-in for loop 6, the "Can't tell" path to a stop-optimizing imperative with rationale, and the divergence-handling in Phase 1c with a concrete pause/ask/wait template. Replaces inline `variant == .cli ? "builder" : "context_builder"` ternaries with the existing `\\(builderName)` constant for consistency. Phase 4 housekeeping no longer re-renders sharedSessionCleanupSection; only the stray-plan-export hint remains with a back-reference to Phase 3.
	/// Version 58: Updates stray prompt-export cleanup guidance to use true absolute delete paths.
	/// Version 59: rp-orchestrate / rp-refactor — adds "two conversations, kept separate" guidance to the shared dispatch-brief block so the orchestrator translates user steering into the technical task instead of proxying user-to-orchestrator commentary verbatim into peer-agent briefs. Adds matching rp-orchestrate anti-pattern with the cancel-and-re-send remedy when a brief already carried that commentary.
	/// Version 60: Adds rp-deep-plan — a delegation-heavy planning workflow that produces a polished `docs/plans/<topic>-<YYYY-MM-DD>.md` document. Mandatory first interactive action is `ask_user` to pick a user-involvement mode (up front / mid-flow / hands-off); the rest of the run pauses for grounded ambiguity-shaping questions only at the chosen checkpoint. Phase 2 fans out explore agents across in-workspace seams, optional external research, and optional prior art lanes. Phase 4 runs `context_builder` in plan mode with `export_response:true` and merges the architectural bones into the plan (not a verbatim append) before deleting the standalone export. Phase 6 is a bounded one-page design-agent critique (under-specified seams / contradictions / overplanning risk / order-changing questions only) — explicitly non-authorial. Phase 7 is the orchestrator's editorial polish: shorter, organized, free of contradiction, no transcript dumps. Hands-off mode becomes interactive at the final hand-off.
	/// Version 61: rp-deep-plan — adds explicit halt-on-`ask_user`-timeout handling for involvement-mode checkpoints. When the user has actively picked a mode that promises a pause (Up front → Phase 1.5, Mid-flow → Phase 5) and a downstream `ask_user` returns `timed_out: true`, the workflow halts at that checkpoint instead of proceeding with assumed answers — resuming from the same prompt when the user replies. The Phase 1 involvement-mode prompt itself is exempt: a timeout there means "no signal" and falls through to Hands-off (same as `skipped: true`), so the workflow doesn't stall before any direction has been given. Adds a Core principle, a Phase 1 "Handling the answer" sub-section that distinguishes the three result shapes, halt reminders at the end of Phase 1.5 / Phase 5, and a matching anti-pattern.
	/// Version 62: rp-deep-plan — reworks the `context_builder` export handoff. Phase 4 now treats the export as the plan *draft*: its content is copied into the plan file faithfully (the scaffold's `Goal` and per-item `Done when` framing preserved), without the orchestrator second-guessing how much implementation detail to keep — if the export framed the approach and work items well, that framing is design output worth keeping. The export survives Phase 4 as a reference input to the Phase 6 design critique, which becomes the arbiter of specificity: it compares plan vs. export and flags both over-specified tactical choices the implementation agent should own and under-specified or dropped framing. The export is deleted only after the critique is folded in. Retunes the "concise" core principle and Phase 7 polish framing so specificity is the critique's call, not a by-hand directive.
	/// Version 63: rp-deep-plan — preserves Phase 2 explore-agent findings as durable context. Phase 2 gains an explicit "capture the findings" step — curate the load-bearing evidence (distill, don't dump raw agent output); Phase 3's `## Background` is now populated substantively at scaffold time (distilled evidence, not draft prose or transcripts) rather than a one-line placeholder; Phase 4 stops re-typing a two-bullet findings summary into the `context_builder` prompt and instead points the builder at the plan's `## Background`. Adds matching anti-patterns against both losing the findings and dumping raw explore output.
	static let skillsVersion = 63

	/// Variant for tool invocation examples in prompts.
	enum ToolVariant {
		case mcp   // JSON-style MCP tool calls
		case cli   // rp-cli command line
		case agent // Agent mode – MCP syntax, auto-mapped workspace, uses ask_oracle

		var preamble: String {
			switch self {
			case .mcp, .agent:
				return ""
			case .cli:
				return """
## Using rp-cli

This workflow uses **rp-cli** (RepoPrompt CLI) instead of MCP tool calls. Run commands via:

```bash
rp-cli -e '<command>'
```

**Quick reference:**

| MCP Tool | CLI Command |
|----------|-------------|
| `get_file_tree` | `rp-cli -e 'tree'` |
| `file_search` | `rp-cli -e 'search "pattern"'` |
| `get_code_structure` | `rp-cli -e 'structure path/'` |
| `read_file` | `rp-cli -e 'read path/file.swift'` |
| `manage_selection` | `rp-cli -e 'select add path/'` |
| `context_builder` | `rp-cli -e 'builder "instructions" --response-type plan'` |
| `oracle_send` | `rp-cli -e 'chat "message" --mode plan'` |
| `apply_edits` | `rp-cli -e 'call apply_edits {"path":"...","search":"...","replace":"..."}'` |
| `file_actions` | `rp-cli -e 'call file_actions {"action":"create","path":"..."}'` |

Chain commands with `&&`:
```bash
rp-cli -e 'select set src/ && context'
```

Use `rp-cli -e 'describe <tool>'` for help on a specific tool, `rp-cli --tools-schema` for machine-readable JSON schemas, or `rp-cli --help` for CLI usage.

JSON args (`-j`) accept inline JSON, file paths (`.json` auto-detected), `@file`, or `@-` (stdin). Raw newlines in strings are auto-repaired.

**⚠️ TIMEOUT WARNING:** The `builder` and `chat` commands can take several minutes to complete. When invoking rp-cli, **set your command timeout to at least 2700 seconds (45 minutes)** to avoid premature termination.

---

"""
			}
		}
	}

	// MARK: - Frontmatter Helpers

	/// Generates YAML frontmatter with embedded version markers for RepoPrompt-managed skills.
	/// - Parameters:
	///   - name: The skill name (becomes the /slash-command)
	///   - description: The skill description
	///   - variant: The tool variant (mcp or cli)
	/// - Returns: Complete YAML frontmatter block including version markers
	static func codexSkillAgentPolicy(forSkillNamed name: String, variant: ToolVariant) -> String {
		// Only the MCP variant of `rp-reminder` is implicitly invokable. The CLI variant
		// (`rp-reminder-cli`) must be invoked explicitly, matching every other skill.
		let implicitlyInvokableSkills: Set<String> = ["rp-reminder"]
		let allowImplicitInvocation = variant != .cli && implicitlyInvokableSkills.contains(name)
		return "policy:\n  allow_implicit_invocation: \(allowImplicitInvocation ? "true" : "false")"
	}

	private static func yamlQuotedScalar(_ value: String) -> String {
		let escaped = value
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\r", with: "\\r")
		return "\"\(escaped)\""
	}

	private static func frontmatter(name: String, description: String, variant: ToolVariant) -> String {
		let variantName: String
		switch variant {
		case .cli: variantName = "cli"
		case .agent: variantName = "agent"
		case .mcp: variantName = "mcp"
		}
		return """
---
name: \(yamlQuotedScalar(name))
description: \(yamlQuotedScalar(description))
repoprompt_managed: true
repoprompt_skills_version: \(skillsVersion)
repoprompt_variant: \(variantName)
---
"""
	}

	// MARK: - Example Generators

	/// Returns the appropriate code example based on variant.
	/// Agent uses the same MCP JSON syntax, so it falls through to the mcp branch.
	private static func example(_ variant: ToolVariant, mcp: String, cli: String) -> String {
		switch variant {
		case .mcp, .agent: return mcp // Agent uses MCP tool syntax
		case .cli: return cli
		}
	}

	/// Generates the workspace verification block for Phase 0 / Step 0.
	/// Returns empty string for agent variant (workspace is auto-mapped).
	/// - Parameters:
	///   - variant: The tool variant
	///   - heading: Section heading including markdown level, e.g. "## Phase 0" or "### Phase 0"
	///   - beforeAction: What comes after "Before any", e.g. "exploration", "investigation"
	///   - nextStep: Where to proceed after verification, e.g. "Phase 1", "Step 1"
	private static func workspaceVerificationBlock(
		variant: ToolVariant,
		heading: String = "Phase 0",
		beforeAction: String = "exploration",
		nextStep: String = "Phase 1"
	) -> String {
		guard variant != .agent else { return "" }
		return """

\(heading): Workspace Verification (REQUIRED)

Before any \(beforeAction), bind to the target codebase using its working directory:

\(example(variant,
	mcp: """
```json
{"tool":"bind_context","args":{"op":"bind","working_dirs":["/absolute/path/to/project"]}}
```
This auto-resolves to the window containing your project. No need to list windows first.
""",
	cli: """
```bash
# First, list available windows to find the right one
rp-cli -e 'windows'

# Then check roots in a specific window (REQUIRED - CLI cannot auto-bind)
rp-cli -w <window_id> -e 'tree --type roots'
```
"""))

\(variant == .mcp ? """
**If binding succeeds** → proceed to \(nextStep)
**If no match** → the codebase isn't loaded. Find and open the workspace:
```json
{"tool":"manage_workspaces","args":{"action":"list"}}
{"tool":"manage_workspaces","args":{"action":"switch","workspace":"<workspace_name>","open_in_new_window":true}}
```
Then retry the `working_dirs` bind.
""" : """
**Check the output:**
- If your target root appears in a window → note the window ID and proceed to \(nextStep)
- If not → the codebase isn't loaded in any window

**CLI Window Routing:**
- CLI invocations are stateless—you MUST pass `-w <window_id>` to target the correct window
- Use `rp-cli -e 'windows'` to list all open windows and their workspaces
- Always include `-w <window_id>` in ALL subsequent commands\(beforeAction == "exploration" ? "\n- Without `-w`, commands may target the wrong workspace" : "")
""")

---
"""
	}

	// MARK: - Orchestration Shared Content

	/// Decomposition guidance shared between orchestration-shaped workflows.
	/// Emits the "for each item, note: goal / done-when / key files / dependencies / size" bullets plus
	/// the 2-3 sweet spot rule and the "1 item = skip ceremony" escape hatch.
	/// - Parameters:
	///   - variant: Tool variant (reserved for future example-bearing variations).
	///   - taskNoun: Singular noun describing what an item produces (e.g. `"item"`, `"refactoring"`).
	///     Substituted into the `Goal` bullet only — the rest uses generic "item"/"task" wording.
	private static func sharedDecompositionGuidance(variant: ToolVariant, taskNoun: String) -> String {
		_ = variant
		return """
For each item, note:
- **Goal**: What this \(taskNoun) accomplishes (1-2 sentences)
- **Done when**: Concrete completion criteria — what should be true when this item is finished
- **Key files/modules**: Where the work happens
- **Dependencies**: Which other items must complete first, if any
- **Size**: Small (focused change) or large (multi-file, architectural)

Most tasks decompose into **2-3 items** — that's the sweet spot. If you're reaching for 4-5, consider whether some items can be combined. If you're beyond 5, you're decomposing too finely — raise the abstraction level.

If the task naturally decomposes into **1 item**, skip the orchestration overhead — just dispatch it directly. Don't create ceremony for simple work.
"""
	}

	/// "Check which model is powering a role" block plus the Codex-family extended-steering caveat.
	private static func sharedRolesOnlyCheck(variant: ToolVariant) -> String {
		return """
To check which model is powering a role:

\(example(variant,
	mcp: """
```json
{"tool":"agent_manage","args":{"op":"list_agents","roles_only":true}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_manage op=list_agents roles_only=true'
```
"""))

A role whose display name starts with `Codex CLI` (or an explicit `model_id` with a `codexExec:*` prefix) signals the role is well-suited to extended steering.
"""
	}

	/// Parallel dispatch guidance: sibling-warning quote block, `detach:true` requirement,
	/// `session_ids` wait semantics, poll option, and "be a pipeline, not a sequential loop" framing.
	/// - Parameters:
	///   - variant: Tool variant — affects MCP vs CLI example syntax.
	///   - defaultRole: `model_id` used in the concurrent-dispatch example (e.g. `"pair"`, `"engineer"`).
	private static func sharedParallelDispatchBlock(variant: ToolVariant, defaultRole: String) -> String {
		return """
If dispatching independent items as fresh agents concurrently, **each agent's brief must mention the sibling**:

> "Another agent is concurrently working on <brief description of sibling task> in <modules>. Avoid modifying files in that area. If you find yourself blocked by or conflicting with that work, stop and report back rather than pushing through."

**Use `detach: true`** when dispatching concurrent items — otherwise the orchestrator blocks on the first agent and can't start the second.

Then pass `session_ids` (array) to `agent_run op=wait` to block until the **first** session finishes or needs input. The response tells you which session won and which are still pending.

\(example(variant,
	mcp: """
```json
// Dispatch both concurrently
{"tool":"agent_run","args":{"op":"start","model_id":"\(defaultRole)","session_name":"1/N: <goal A>","message":"<brief A>","detach":true}}
{"tool":"agent_run","args":{"op":"start","model_id":"\(defaultRole)","session_name":"2/N: <goal B>","message":"<brief B>","detach":true}}

// Then wait for the first session that needs attention
{"tool":"agent_run","args":{"op":"wait","session_ids":["<session_id_A>","<session_id_B>"],"timeout":60}}

// Or poll all current snapshots without blocking
{"tool":"agent_run","args":{"op":"poll","session_ids":["<session_id_A>","<session_id_B>"]}}
```
""",
	cli: """
```bash
# Dispatch both concurrently
rp-cli -w <window_id> -e 'agent_run op=start model_id=\(defaultRole) session_name="1/N: <goal A>" message="<brief A>" detach=true'
rp-cli -w <window_id> -e 'agent_run op=start model_id=\(defaultRole) session_name="2/N: <goal B>" message="<brief B>" detach=true'

# Then wait for the first session that needs attention
rp-cli -w <window_id> -e 'agent_run op=wait session_ids=["<uuid1>","<uuid2>"] timeout=60'

# Or poll all current snapshots without blocking
rp-cli -w <window_id> -e 'agent_run op=poll session_ids=["<uuid1>","<uuid2>"]'
```
"""))

Handle the finished agent, then wait again on the remaining `pending_session_ids`. While waiting, summarize completed work or prepare the next brief — be a pipeline, not a sequential loop.
"""
	}

	/// Dispatch-brief guidance: "scope is your most important job", paraphrase/point/boundary patterns,
	/// include/don't-include lists, and "pass forward discoveries, not instructions".
	private static func sharedDispatchBriefGuidance(variant: ToolVariant) -> String {
		_ = variant
		return """
The agents you dispatch are fully capable — they have tools, they'll read AGENTS.md and project instructions, they can explore and reason. Your job is to orient them, not direct them.

**Scope is your most important job.** When you pass a plan export, the sub-agent can see the full plan — but it doesn't know which part is its responsibility unless you say so. Always be explicit about what it should do *now* and what it should leave alone. A few patterns:

- **Paraphrase for narrow tasks**: If the work is small and self-contained, just describe it in the dispatch message. The agent doesn't need the full plan.
- **Point to a section for broader tasks**: Reference the plan path in the `message` and tell the agent which part to focus on (e.g. "Read the plan at <path> with read_file first. Your job is item 2 in the plan. Items 1 and 3 are handled separately.").
- **State the boundary**: "Do only X. Stop when X is done." is more effective than hoping the agent infers scope from context.

You can always steer additional work later, or spin up a separate agent for the next item.

**Include:** The goal, relevant file paths/modules, and discoveries from planning that the agent wouldn't find on its own. If a separate user plan file exists, point to the relevant section. For small tasks, tell the agent to skip oracle review.

**Don't include:** Project conventions already in CLAUDE.md, step-by-step instructions, or code snippets the agent can read itself.

**Pass forward discoveries, not instructions.**

**Two conversations, kept separate.** You hold one conversation with the user (preferences, course corrections, meta-instructions about how *you* should behave) and a separate one with each peer agent (purely the technical task). When the user steers you, translate the actionable parts into the next brief — never forward their words verbatim, and never narrate what the user told you about your own conduct. If a brief you already dispatched carried that kind of commentary, cancel it and re-send clean.
"""
	}

	/// Final rollup bullets emitted after all work items complete.
	/// - Parameter taskNoun: Singular noun describing each item (e.g. `"item"`). Substituted into the
	///   "After all Xs complete" and "What was accomplished per X" lines.
	private static func sharedFinalRollupBlock(variant: ToolVariant, taskNoun: String) -> String {
		_ = variant
		return """
After all \(taskNoun)s complete, give the user a **final rollup**:
- What was accomplished per \(taskNoun)
- Any failures or partial completions
- Any conflicts or coordination issues that surfaced
- Suggested follow-ups if anything was deferred
"""
	}

	/// Monitor-and-verify pattern: verify each agent's output against the plan's "done when" criteria,
	/// steer a correction if something's off, and summarize status to the user.
	private static func sharedMonitorAndVerifyBlock(variant: ToolVariant) -> String {
		return """
You own the plan. It's your job to ensure each phase respected it.

As each agent completes:

1. **Verify against the plan.** Check the agent's output against the "done when" criteria from the plan. Don't just skim — confirm the goal was actually met. A quick `read_file` or `file_search` on key deliverables costs little and catches drift before it compounds. If the plan said "add error handling to all three endpoints" and the agent only touched two, that's your catch. Mark the item as done (or note gaps) in the export file so you have a running record.
2. **If something's off**, steer a correction before moving on — never proceed with unresolved gaps:
\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"The goal was X but Y appears to be missing. Please address that before wrapping up.",
	"wait":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="The goal was X but Y appears missing." wait=true'
```
"""))
3. **Summarize to the user**: Brief status update — what completed, what's still running.
"""
	}

	/// Gentle housekeeping hint for dismissing completed agent sessions after their
	/// output has been recorded. Sessions persist by default; cleanup is optional but
	/// keeps the session list tidy during multi-agent workflows.
	private static func sharedSessionCleanupHint(variant: ToolVariant) -> String {
		return """
Sessions persist after agents finish — useful when you might revisit output, but they pile up over a multi-agent workflow. Once you've recorded what an agent produced, you can dismiss its session:

\(example(variant,
	mcp: """
```json
{"tool":"agent_manage","args":{"op":"cleanup_sessions","session_ids":["<session_id>"]}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_manage op=cleanup_sessions session_ids=["<session_id>"]'
```
"""))

Explore-agent sessions are good to dismiss right away — narrow reconnaissance, no follow-up value. Keep heavier agent sessions if you might revisit them.
"""
	}

	/// Gentle housekeeping hint for removing stray plan/review export files that were
	/// generated during a multi-agent workflow but are no longer relevant to the task
	/// (superseded drafts, one-shot oracle consultations, exports whose work has already
	/// been merged). Keeps `prompt-exports/` focused on live, in-progress plans.
	private static func sharedStrayPlanExportCleanupHint(variant: ToolVariant) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let oracleName: String
		switch variant {
		case .cli: oracleName = "`chat`"
		case .agent: oracleName = "`ask_oracle`"
		case .mcp: oracleName = "`oracle_send`"
		}
		return """
Plan and review exports generated during orchestration (via `export_response:true` on \(builderName) or \(oracleName)) accumulate under `prompt-exports/` as files like `oracle-plan-<date>-<slug>.md` or `oracle-review-<date>-<slug>.md`. Once an export has been superseded by a newer plan, consumed by the sub-agent it was meant for, or otherwise made irrelevant by completed work, delete it so the folder reflects only live, in-progress plans. `file_actions.delete` requires a true absolute filesystem path, not the relative display path shown under `prompt-exports/`; use `get_file_tree` with `type:"roots"` if you need the loaded root's absolute path. When unsure, leave it.

\(example(variant,
	mcp: """
```json
{"tool":"file_actions","args":{"action":"delete","path":"/absolute/path/to/repo/prompt-exports/<stale-export>.md"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'call file_actions {"action":"delete","path":"/absolute/path/to/repo/prompt-exports/<stale-export>.md"}'
```
"""))
"""
	}

	private static func sharedSessionCleanupSection(
		variant: ToolVariant,
		heading: String,
		includeSessionCleanupGuidance: Bool,
		includeStrayPlanExportCleanup: Bool = false
	) -> String {
		guard includeSessionCleanupGuidance else { return "" }
		var blocks: [String] = [sharedSessionCleanupHint(variant: variant)]
		if includeStrayPlanExportCleanup {
			blocks.append(sharedStrayPlanExportCleanupHint(variant: variant))
		}
		return """
\(heading)

\(blocks.joined(separator: "\n\n"))

"""
	}

	// MARK: - Shared Core Content

	/// Core MCP Builder workflow content - shared across slash commands, MCP prompts, and copy presets.
	/// Does NOT include surface-specific content like YAML frontmatter or embedded file tree mentions.
	static let rpBuildCore = rpBuildCore(variant: .mcp)

	/// Generate build workflow content for a specific variant.
	static func rpBuildCore(variant: ToolVariant) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatName: String
		let chatToolName: String
		switch variant {
		case .cli: chatName = "`chat`"; chatToolName = "chat"
		case .agent: chatName = "`ask_oracle`"; chatToolName = "ask_oracle"
		case .mcp: chatName = "`oracle_send`"; chatToolName = "oracle_send"
		}
		let isAgent = variant == .agent

		return """
## The Workflow
\(isAgent ? "" : "\n0. **Verify workspace** – Confirm the target codebase is loaded")
1. **Quick scan** – Understand how the task relates to the codebase
2. **Context builder** – Call \(builderName) with a clear prompt to get deep context + an architectural plan
3. **Only if needed, ask \(chatName)** – Use it when navigating the selected code is difficult or the plan leaves a concrete unresolved gap
4. **Implement directly** – Use editing tools to make changes once the plan is clear

---

## Before you implement

Work through the phases in order:
\(isAgent ? "" : "1. Completed Phase 0 (Workspace Verification)\n")\
\(isAgent ? "1" : "2"). Completed Phase 1 (Quick Scan)
\(isAgent ? "2" : "3"). Called \(builderName) and received its plan

The quick scan is orientation only — \(builderName) does the deep exploration and produces the plan. Skipping it tends to produce shallow implementations that miss architectural patterns and edge cases.

---
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "exploration", nextStep: "Phase 1"))
## Phase 1: Quick Scan

Keep this phase brief — \(builderName) handles the deep exploration.

Start by getting a lay of the land with the file tree:
\(example(variant,
	mcp: """
```json
{"tool":"get_file_tree","args":{"type":"files","mode":"auto"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'tree'
```
"""))

Then use targeted searches to understand how the task maps to the codebase:
\(example(variant,
	mcp: """
```json
{"tool":"file_search","args":{"pattern":"<key term from task>","mode":"path"}}
{"tool":"get_code_structure","args":{"paths":["RootName/likely/relevant/area"]}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'search "<key term from task>"'
rp-cli -w <window_id> -e 'structure RootName/likely/relevant/area/'
```
"""))

Use what you learn to **reformulate the user's prompt** with added clarity—reference specific modules, patterns, or terminology from the codebase.

Your goal is orientation, not deep understanding — \(builderName) does the heavy lifting.

---

## Phase 2: Context Builder

Call \(builderName) with your informed prompt. Use `response_type: "plan"` to get an actionable architectural plan.

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<reformulated prompt with codebase context>",
  "response_type":"plan"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<reformulated prompt with codebase context>" --response-type plan'
```
"""))

**What you get back:**
- Smart file selection (automatically curated within token budget)
- Architectural plan grounded in actual code
- \(variant == .cli ? "Chat session" : "`chat_id`") for follow-up conversation
\(variant == .cli ? "- `tab_id` for targeting the same tab in subsequent CLI invocations" : "")

\(variant == .cli ? """
**Tab routing:** Each `rp-cli` invocation is a fresh connection. To continue working in the same tab across separate invocations, pass `-t <tab_id>` (the tab ID returned by builder).
""" : "")
**Trust \(builderName)** – it explores deeply, aggregates the relevant context, and selects intelligently. Default to trusting the plan it returns. The \(chatName) follow-up only reasons over that selected context; it cannot fill coverage gaps on its own.

---

## Phase 3: Ask \(chatName) only if needed

\(chatName) deep-reasons over the files selected by \(builderName). It sees those selected files **completely** (full content, not summaries), but it **only sees what's in the selection** — nothing else.

**This phase is optional.** If the builder's plan is already clear and navigation through the selected code is straightforward, proceed straight to Phase 4.

Bring a follow-up to \(chatName) only when:
- Navigating the selected code proves difficult even with the builder's plan
- You need cross-file reasoning over the files already selected
- The plan leaves a concrete unresolved gap you cannot close by reading the selected files directly

If the answer depends on files outside the current selection, \(chatName) cannot answer it from thin air. Do **not** turn this workflow into manual selection management by default — if coverage is materially wrong, prefer rerunning \(builderName) with a better prompt.

\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<from context_builder>",
  "message":"The plan points me to X and Y, but I'm still having trouble tracing how they connect across these selected files. What am I missing, and what edge cases should I watch for?",
  "mode":"plan",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rp-cli -t '<tab_id>' -e 'chat "The plan points me to X and Y, but I'\''m still having trouble tracing how they connect across these selected files. What am I missing, and what edge cases should I watch for?" --mode plan'
```

> **Note:** Pass `-t <tab_id>` to target the same tab across separate CLI invocations.
"""))

**\(chatName) excels at:**
- Deep reasoning over the context_builder output and selected files
- Spotting cross-file connections that piecemeal reading might miss
- Answering targeted "what am I missing in this selected context" questions

**Don't expect:**
- Knowledge of files outside the selection
- Repository exploration or missing-file discovery — that's \(builderName)'s job
- Implementation — that's your job

---

## Phase 4: Direct Implementation

Before implementing, verify you have:
- [ ] \(variant == .cli ? "A builder result available (`tab_id` if follow-up is needed)" : "A builder result available (`chat_id` if follow-up is needed)")
- [ ] An architectural plan grounded in actual code

If a specific point is still unclear, use \(chatName) to clarify before proceeding.

Implement the plan directly. Don't use \(chatName) with `mode:"edit"` — you implement directly.

**Primary tools:**
\(example(variant,
	mcp: """
```json
// Modify existing files (search/replace)
{"tool":"apply_edits","args":{"path":"Root/File.swift","search":"old","replace":"new","verbose":true}}

// Create new files (auto-added to selection)
{"tool":"file_actions","args":{"action":"create","path":"Root/NewFile.swift","content":"..."}}

// Read specific sections during implementation
{"tool":"read_file","args":{"path":"Root/File.swift","start_line":50,"limit":30}}
```
""",
	cli: """
```bash
# Modify existing files (search/replace) - JSON format required
rp-cli -w <window_id> -e 'call apply_edits {"path":"Root/File.swift","search":"old","replace":"new"}'

# Multiline edits
rp-cli -w <window_id> -e 'call apply_edits {"path":"Root/File.swift","search":"old\\ntext","replace":"new\\ntext"}'

# Create new files
rp-cli -w <window_id> -e 'file create Root/NewFile.swift "content..."'

# Read specific sections during implementation
rp-cli -w <window_id> -e 'read Root/File.swift --start-line 50 --limit 30'
```
"""))

**Ask \(chatName) only when navigation or cross-file reasoning is the bottleneck:**
\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<same chat_id>",
  "message":"I'm implementing X. The plan does not fully explain Y, and reading the selected files still leaves a gap. What pattern or connection am I missing here?",
  "mode":"chat",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -t '<tab_id>' -e 'chat "I'\''m implementing X. The plan does not fully explain Y, and reading the selected files still leaves a gap. What pattern or connection am I missing here?" --mode chat'
```
"""))

---

## Key Guidelines

**Token limit:** Stay under ~160k tokens. Check with \(variant == .cli ? "`select get`" : "`manage_selection(op:\"get\")`") if unsure. Context builder manages this, but be aware if you add files.

**Selection coverage:**
- \(builderName) should already have selected the files needed for the plan
- \(chatName) can reason only over that selected context; it cannot discover missing files on its own
- If a material coverage gap blocks you, prefer rerunning \(builderName) with a better prompt over hand-curating selection
- Use `manage_selection` only as a last resort for a very small, targeted addition

**\(chatName) sees only the selection:** If the answer depends on files outside the selection, \(chatName) cannot provide it until coverage changes — and in this workflow, coverage changes should usually come from \(builderName), not from manual curation.

---

## Anti-patterns to Avoid

- 🚫 Using \(chatName) with `mode:"edit"` – implement directly with editing tools
- 🚫 Asking \(chatName) about files it cannot see in the current selection
- 🚫 Treating Phase 3 as mandatory when the builder's plan is already clear
- 🚫 Reopening or second-guessing the builder's plan by default instead of trusting it
- 🚫 Leaning on manual `manage_selection` work to patch coverage gaps that should be handled by \(builderName)
- 🚫 Skipping \(builderName) and going straight to implementation – you'll miss context
- 🚫 Using `manage_selection` with `op:"clear"` – this undoes \(builderName)'s work; only use small targeted additions if absolutely necessary
- 🚫 Exceeding ~160k tokens – use slices if needed
- 🚫 Extended reading before calling \(builderName) – a quick skim is fine; let the builder do the heavy lifting
- 🚫 Reading full file contents during Phase 1 – save that for after \(builderName) builds context
- 🚫 Convincing yourself you understand enough to skip \(builderName) – you don't\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` – CLI invocations are stateless and require explicit window targeting" : "")

---

**Your job:** Get a solid plan from \(builderName), trust it by default, use \(chatName) only when navigating the selected code proves difficult or the plan leaves a concrete unresolved gap, then implement directly and completely.
"""
	}

	/// Generate investigation workflow content for a specific variant.
	static func rpInvestigateCore(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatTool = variant == .agent ? "`ask_oracle`" : "`oracle_send`"
		let chatLabel = variant == .agent ? "oracle" : "chat"
		let ChatLabel = variant == .agent ? "Oracle" : "Chat"
		let isAgent = variant == .agent

		return """
## Investigation Protocol

This workflow leverages five complementary capabilities:

- **You (the agent)**: Orchestrate. Triage what the task needs, dispatch explore agents for external fact-gathering, run \(builderName), dispatch a pair investigator, curate the file selection, and synthesize the final report. Default posture: coordination, not reconnaissance.
- **Explore agents** (`agent_run` with `model_id:"explore"`): Read-only sub-agents in a fresh context window, for narrow self-contained questions. Used in two places: (1) **before \(builderName)**, for facts outside the workspace (git archaeology, web searches, external docs — findings go to `## Background / Prior Research` in the report); (2) **spawned by the pair** for in-workspace checks.
- **Context Builder** (\(builderName)): Populates the file selection with full files or slices relevant to the task. Feed it the report path so prior research informs the selection.
- **\(ChatLabel)** (\(chatTool)): Deep analytical reasoning over the current file selection. Good for synthesis across selected files; not a lookup tool.
- **Pair investigator** (`agent_run` with `model_id:"pair"`): Full-capability agent for the main line of inquiry. Reads files, runs git, spawns its own explore agents, and writes findings into `## Investigator Findings` in the report.

This workflow is read-only. Output lands in the investigation report; no source code changes.

### How File Selection Drives the Workflow

**The pair's and explores' file reads don't populate your file selection** — they run in their own sessions. Selection curation is **your** job: the \(chatLabel) only sees what's in the selection in your window.

1. \(builderName) seeds the selection during Phase 2
2. After the pair returns, refresh the selection to match what the investigation surfaced — add files the pair referenced, add slices of large files where only a region is relevant, remove fully unrelated files
3. **Bias toward inclusion** — better for the \(chatLabel) to see a related file than miss one. Prune only files/codemaps that are clearly unrelated; when in doubt, keep them
4. **Never `op:"clear"` or `op:"set"`** — they wipe \(builderName)'s curation. Use `op:"add"` / `op:"remove"` / slices

### Core Principles
1. **Don't stop until confident** — pursue every lead until evidence is solid
2. **Delegate before reading** — phases below lay out the default order (explore → \(builderName) → pair → \(chatLabel)). You orchestrate; the pair writes findings directly to the report.
3. **Curate the selection between \(chatLabel) calls** — the pair's reads aren't visible in your selection; add files it surfaced, bias toward inclusion
4. **Direct tool calls are for follow-up** — reserve your own `read_file` / `file_search` / `git` for user-supplied leads, verifying agent findings, and grabbing final line-number evidence
5. **Don't duplicate in-flight work** — while agents are running, don't re-run their investigation or spin up overlapping fleets
\(workspaceVerificationBlock(variant: variant, heading: "### Phase 0", beforeAction: "investigation", nextStep: "Phase 1"))
### Phase 1: Initial Assessment & Triage (Agent — you)

1. Read any provided files/reports (traces, logs, error reports)
2. Summarize symptoms and form initial hypotheses
3. **Create the investigation report file** — use `docs/investigations/<topic>-<YYYY-MM-DD>.md` (or match the repo's existing convention; look under `docs/investigations/` for examples). Note its absolute path; you'll feed it to \(builderName) and the pair.
4. **Triage external info needs.** Does the task require anything \(builderName) can't see in the workspace?
	- Git history (blame, log archaeology, "when did this regress", PR context)
	- Web searches or external documentation
	- Other facts outside the workspace

If yes, run Phase 1.5 first. Otherwise skip to Phase 2.

#### Phase 1.5: External Fact-Gathering (conditional)

Dispatch explore agents in parallel for external facts. As each returns, write a concise entry into the report's `## Background / Prior Research` section — commits, excerpts, links.

\(example(variant,
	mcp: """
```json
// Explore agent for external fact-gathering (git archaeology / web / docs)
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"<kind>: <specific question>",
	"message":"<Specific question>. Report relevant commits/file:line refs or links + short summary.",
	"detach":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="<kind>: <question>" message="<question>. Report commits/links and summary." detach=true'
```
"""))

> ⚠️ **Detached agents may block on permission approvals.** Poll periodically or use `op=wait` so you can approve requests and keep them unblocked. This applies to every detached agent in this workflow.

### Phase 2: Broad Context Gathering (via \(builderName) — REQUIRED)

\(builderName) discovers workspace files you'd miss manually. Pass detailed instructions + the report path so prior research informs its selection:

\(example(variant,
	mcp: """
```
mcp__RepoPrompt__context_builder:
  instructions: |
	<task>Describe the specific issue or question to investigate</task>

	<context>
	See investigation report at `<absolute/path/to/investigation-report.md>` for symptoms, hypotheses, and any prior research (git history, external docs) gathered in Phase 1.5.

	Symptoms:
	- <symptom 1>
	- <symptom 2>

	Hypotheses to test:
	- <theory 1>
	- <theory 2>

	Areas likely involved:
	- <files, patterns, or subsystems>
	</context>

	response_type: question
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>Investigate: specific issue</task>

<context>
See investigation report at <absolute/path/to/investigation-report.md> for symptoms, hypotheses, and prior research.

Symptoms:
- <symptom 1>
- <symptom 2>

Hypotheses to test:
- <theory 1>
- <theory 2>

Areas likely involved:
- <files/patterns/subsystems>
</context>
" --response-type question'
```
"""))

Use `response_type: question` so the \(chatLabel) returns its initial assessment immediately. If \(builderName) produces a thin selection (few files, or misses obvious areas), re-run it with refined instructions rather than doing the broad search yourself.

### Phase 3: Pair Investigator (Main Line of Inquiry)

Dispatch a pair investigator for the main investigation. It handles multi-step reasoning and spawns its own explore agents for in-workspace reconnaissance.

**Skip the pair** only when the \(chatLabel)'s hypotheses point to a single spot one `read_file` would resolve, or when Phase 1.5's external research already answers the task.

**Default: one pair** writing to `## Investigator Findings`. **Escalate to 2–3 parallel pairs** only when the \(chatLabel)'s response surfaces genuinely disjoint hypothesis paths (distinct root-cause theories in different subsystems — e.g., "caching vs. threading vs. encoding"). Each gets a disjoint scope and its own `## Investigator Findings: <path>` sub-section; cap at 3.

Its brief should include:

- Hypothesis and what you want proved or disproved
- Relevant \(chatLabel) analysis points
- Absolute path to the report file, with instruction to append findings under `## Investigator Findings` (file:line refs, evidence, conclusions)
- Encouragement to fan out explore agents for parallel reconnaissance — seed 2–3 concrete candidate checks to kickstart delegation

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Investigate: <hypothesis>",
	"message":"Investigate <hypothesis>. See `<report-path>` for context. Trace <flow>, verify <behavior>. Fan out explore agents for narrow reconnaissance; candidate checks: <check 1>, <check 2>, <check 3>. Append findings to `## Investigator Findings` in the report with file:line refs and evidence.",
	"detach":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Investigate: <hypothesis>" message="Investigate <hypothesis>. See <report-path> for context. Trace <flow>. Fan out explore agents; candidate checks: <check 1>, <check 2>, <check 3>. Append findings to ## Investigator Findings in the report." detach=true'
```
"""))

**While the pair runs**, don't re-run its investigation. Monitor the session for permission approvals, handle user-supplied specifics (files the user pointed you at), run git on already-pinpointed code, and plan the next \(chatLabel) questions. Don't spin up parallel explore agents at your level — the pair is running its own.

**When the pair returns** (wait or poll):

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{"op":"wait","session_id":"<pair_session_id>","timeout":60}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=wait session_id=<pair_uuid> timeout=60'
```
"""))

Read its `## Investigator Findings` — primary evidence. Spot-check specific claims with `read_file` / `file_search` / `git` before folding into the root cause.

\(sharedSessionCleanupSection(variant: variant, heading: "#### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance))
### Phase 4: Refocus Selection + \(ChatLabel) Deep Dives (iterate)

**Before each \(chatLabel) call, curate the selection.** The pair's file reads ran in another session — they aren't in your selection. Update it to match what the investigation surfaced:

- **Add** files the pair referenced in `## Investigator Findings`
- **Add slices** of large files where only a region is relevant
- **Remove** files that turned out to be fully unrelated — bias toward keeping; when in doubt, leave it
- **Never** `op:"clear"` or `op:"set"` — they wipe \(builderName)'s curation. Use `op:"add"` / `op:"remove"` / slices

Then ask a question that requires synthesis, not lookup:

\(example(variant,
	mcp: """
```
// Add files the pair surfaced
mcp__RepoPrompt__manage_selection:
	op: add
	paths: [<files surfaced by the pair>]

// Or add a slice of a large file
mcp__RepoPrompt__manage_selection:
	op: add
	slices:
	- path: "Root/large/file.swift"
		ranges: [{start_line: 100, end_line: 250}]

// Ask a focused question — the \(chatLabel) sees the updated selection
mcp__RepoPrompt__\(chatTool):
  chat_id: <from context_builder>
	message: |
	Here's what the pair found:
	- <evidence 1 with file:line>
	- <evidence 2 with file:line>

	<specific analytical question>
	mode: chat
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'select add <files surfaced by the pair>'
rp-cli -w <window_id> -e 'select add Root/large/file.swift:100-250'

rp-cli -w <window_id> -t '<tab_id>' -e 'chat "Here is what the pair found:
- <evidence 1 with file:line>
- <evidence 2 with file:line>

<specific question>" --mode chat'
```

> Pass `-t <tab_id>` to continue the same \(chatLabel) conversation.
"""))

**Repeat Phases 3–4** as needed. For new evidence between \(chatLabel) calls, steer the existing pair (it keeps its context) or dispatch a fresh explore for narrow external lookups. Don't burn a \(chatLabel) call on a question `read_file` / `file_search` / `git` could answer.

**Stop when**: root cause is identified with concrete file:line evidence, alternate hypotheses are ruled out with specific counter-evidence, and recommended fixes point at exact locations.

### Phase 5: Conclusions & Report (Agent — you)

`## Investigator Findings` and `## Background / Prior Research` are your factual baseline. Verify line references as you fold them into:

- **Root cause** — exact file paths, line numbers, code snippets
- **Eliminated hypotheses** — and the evidence that ruled them out
- **Recommended fixes** — specific, actionable, with file locations
- **Preventive measures** — how to avoid this recurring

---

## Role Summary

| Capability | Agent (you) | Context Builder | \(ChatLabel) (\(chatTool)) | Pair Investigator | Explore Agents |
|------------|-------------|-----------------|--------|-------------------|----------------|
| Triage / orchestrate | ✅ Primary | ❌ | ❌ | ❌ | ❌ |
| Dispatch sub-agents | ✅ | ❌ | ❌ | ✅ | ❌ |
| Discover files in workspace | ⚠️ Limited | ✅ Primary | ❌ | ✅ Good | ⚠️ Narrow |
| Populate file selection | ✅ (curate) | ✅ Primary (seed) | ❌ | ❌ | ❌ |
| Mutate selection to refocus \(chatLabel) | ✅ Primary | ❌ | ❌ | ❌ | ❌ |
| Read file contents & lines | ✅ | ❌ | Sees full selected files | ✅ | ✅ |
| Run git blame/log/diff | ✅ | ❌ | ❌ | ✅ | ✅ |
| **Web searches / external docs** | ❌ | ❌ | ❌ | ❌ | ✅ Primary |
| Multi-step cross-file reasoning | ⚠️ OK | ❌ | ✅ (on selection) | ✅ Primary | ❌ |
| Synthesize patterns & architecture | ⚠️ OK | ❌ | ✅ Primary | ✅ Good | ⚠️ OK |
| Form & refine hypotheses | ⚠️ OK | ❌ | ✅ Primary | ✅ Good | ❌ |
| Produce line-number evidence | ✅ (verify/augment) | ❌ | ❌ | ✅ Primary | ✅ |
| Write findings into report | ✅ (final synthesis) | ❌ | ❌ | ✅ Primary | ❌ |

---

## Report Template

Create a findings report as you investigate:

```markdown
# Investigation: [Title]

## Summary
[1-2 sentence summary of findings]

## Symptoms
- [Observed symptom 1]
- [Observed symptom 2]

## Background / Prior Research
<!-- Findings from Phase 1.5 explore agents: git archaeology, external docs, web searches.
     The agent populates this section before running the context builder. Omit if nothing outside the workspace was needed. -->

## Investigator Findings
<!-- The pair investigator appends its structured analysis here (file:line refs, evidence, conclusions).
     The agent leaves this section for the pair to populate and folds it into the root cause below.

     If running 2–3 parallel pair investigators on disjoint hypothesis paths, replace this single section
     with one sub-section per path, e.g.:
         ## Investigator Findings: <hypothesis path A>
         ## Investigator Findings: <hypothesis path B>
     Each pair writes only to its own sub-section to avoid write contention. -->

## Investigation Log

### [Phase] - [Area Investigated]
**Hypothesis:** [What you were testing]
**Findings:** [What you found]
**Evidence:** [Exact file paths, line numbers, code snippets, git commits]
**Conclusion:** [Confirmed/Eliminated/Needs more investigation]

## Root Cause
[Detailed explanation with precise evidence]

## Recommendations
1. [Fix 1 — specific file and location]
2. [Fix 2 — specific file and location]

## Preventive Measures
- [How to prevent this in future]
```

---

## Anti-patterns to Avoid

- 🚫 **Running \(builderName) with incomplete inputs** — before Phase 1.5 external research, or without the report path\(isAgent ? "" : "\n- 🚫 Skipping Phase 0 — confirm the target codebase is loaded first")
- 🚫 **Skipping \(builderName)** or doing broad manual reads — you'll miss context
- 🚫 **Duplicating in-flight work** — broad reads/searches or parallel explore agents at your level while the pair is investigating. Dispatch, then orchestrate.
- 🚫 **Stale file selection before \(chatLabel) calls** — the pair's reads aren't in your selection; add files it surfaced, bias toward inclusion, never `op:"clear"`/`op:"set"` (wipes \(builderName)'s curation)
- 🚫 Asking the \(chatLabel) for exact line numbers or using it for lookups — it can't produce reliable line numbers and it's not a lookup tool; verify yourself or delegate to a tool call
- 🚫 Calling the \(chatLabel) without new evidence between turns
- 🚫 **Parallel pair investigators on overlapping hypotheses** — only parallelize for genuinely disjoint paths; each pair gets its own `## Investigator Findings: <path>` sub-section
- 🚫 Dispatching the pair without the report path — it should append findings directly
- 🚫 Wrong tool for the job — explore agents for complex multi-step in-workspace investigation (use the pair), or broad prompts like "investigate the auth system" to explores (one specific check each)
- 🚫 Forgetting to poll dispatched agents — they may block on permission approvals\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting `-w <window_id>` — stateless invocations need explicit window targeting" : "")

---

Now begin. \(variant == .cli ? "First run `rp-cli -e 'windows'` to find the correct window. " : "")Follow the phases above: assess → (if needed) gather external facts → \(builderName) → pair investigator → refresh selection → \(chatLabel) synthesis → report. You orchestrate, they investigate.
"""
	}

	// MARK: - Slash Commands

	/// The rp-investigate slash command - deep investigation workflow (MCP variant)
	static let rpInvestigate = rpInvestigate(variant: .mcp)

	/// Generate rp-investigate for a specific variant.
	static func rpInvestigate(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rp-cli commands" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-investigate", description: "Deep investigation with \(toolDesc): tools gather evidence, follow-up reasoning synthesizes selected context", variant: variant))

# Deep Investigation Mode\(suffix)

Investigate: $ARGUMENTS

You are now in deep investigation mode for the issue described above. Follow this protocol rigorously.

\(variant.preamble)\(rpInvestigateCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	// MARK: - Deep Plan

	/// The rp-deep-plan slash command — deep, delegation-heavy planning workflow that
	/// ends at a polished `docs/plans/<topic>-<YYYY-MM-DD>.md` document (no implementation).
	static let rpDeepPlan = rpDeepPlan(variant: .mcp)

	/// Generate rp-deep-plan for a specific variant.
	static func rpDeepPlan(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-deep-plan", description: "Deep planning workflow using \(toolDesc): map seams, draft, critique, polish — produces a ready-to-execute plan document", variant: variant))

# Deep Plan Mode\(suffix)

Plan: $ARGUMENTS

You are a deep-planning orchestrator. Produce one polished, executable plan document at `docs/plans/<topic>-<YYYY-MM-DD>.md` — and nothing else. No code, no implementation, no half-built scaffolding.

\(variant.preamble)\(rpDeepPlanCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// Core deep-plan workflow content.
	static func rpDeepPlanCore(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatTool: String
		let chatToolName: String
		switch variant {
		case .cli: chatTool = "`chat`"; chatToolName = "chat"
		case .agent: chatTool = "`ask_oracle`"; chatToolName = "ask_oracle"
		case .mcp: chatTool = "`oracle_send`"; chatToolName = "oracle_send"
		}
		_ = chatTool
		_ = chatToolName

		return """
This workflow is delegation-heavy. Explore agents map seams and pull external research. \(builderName) produces the draft plan in plan mode. A design agent does a bounded critique. **You own the writing**, the structure, and the final shape.

## Core principles

- **Plan only.** Implementation belongs in `rp-build` or `rp-orchestrate`. End at a polished document.
- **Delegate evidence, not voice.** Sub-agents gather; you write.
- **Tight, not thin — and not your call to make alone.** The plan locks down decisions (chosen approach, named seams, ordering, constraints) without dictating every tactical choice the implementation agent should own. Don't pre-edit the \(builderName) draft toward either extreme — the Phase 6 design critique is the arbiter of specificity.
- **Reference, don't reproduce.** Point to `file:line` and external links. Don't paste full files into the plan.
- **Ground every user question in something you found.** Generic interview questions waste the user's time.
- **Honor the involvement promise.** Once the user has picked **Up front** or **Mid-flow**, every downstream `ask_user` is a checkpoint they asked for. If one returns `timed_out: true`, **halt** — don't proceed with assumed answers and silently break the promise. Resume from the same prompt when the user replies. (Phase 1 itself is exempt: a timeout on the involvement-mode question means "no signal yet," and the documented Hands-off default applies.) `skipped: true` is always an explicit user choice and falls back to documented defaults.
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "the involvement question", nextStep: "Phase 1"))
## Phase 1: User Involvement Decision (REQUIRED — first interactive action)

Before any exploration, ask the user how involved they want to be. This is the **only** mandatory user prompt — the rest of the run pauses for input only at the chosen checkpoint.

\(example(variant,
	mcp: """
```json
{"tool":"ask_user","args":{
	"question":"How involved would you like to be while I shape this plan?",
	"options":[
		"Up front — I want to clarify the prompt before exploration begins.",
		"Mid-flow — check in with me before the design agent reviews the draft.",
		"Hands-off — surface the plan when it is ready, then we can refine it interactively."
	],
	"context":"This decides where I pause for your input. The default if you skip or don't reply is hands-off.",
	"timeout_seconds":120
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'call ask_user {"question":"How involved would you like to be while I shape this plan?","options":["Up front — I want to clarify the prompt before exploration begins.","Mid-flow — check in with me before the design agent reviews the draft.","Hands-off — surface the plan when it is ready, then we can refine it interactively."],"context":"This decides where I pause for your input. The default if you skip or don'\''t reply is hands-off.","timeout_seconds":120}'
```
"""))

The answer drives the rest of the run:

| Mode | Where you pause for the user |
|------|------------------------------|
| **Up front** | Phase 1.5 — grounded interview before broad exploration |
| **Mid-flow** | Phase 5 — review the draft before the design critique |
| **Hands-off** | Phase 7 — final hand-off, then interactive refinement |

### Handling the answer

Inspect the `ask_user` result before moving on:

- **Answered** (one of the three options, or a freeform reply) → set the involvement mode and continue. If they picked **Up front** or **Mid-flow**, treat that as a promise: a timeout at the chosen checkpoint later means **halt**, not "default and keep going".
- **`skipped: true`** (user explicitly skipped) → fall back to **Hands-off** and continue. The user has signaled they don't want to be involved.
- **`timed_out: true`** (no reply) → fall back to **Hands-off** and continue. A timeout here means no signal yet — don't stall the workflow before any direction has been given. (This is the **only** `ask_user` in this workflow where a timeout is treated as a default-fallback. Once the user has picked Up front or Mid-flow, downstream timeouts halt instead.)

When you do involve the user, ask **2–4 thoughtful, plan-shaping questions** — questions that surface a real ambiguity in the work. If you couldn't have asked the question without first looking at the code or current draft, it's probably a good question. Generic workflow meta-questions ("what's the priority?") and unfocused asks ("what do you want?") don't count.

### Phase 1.5: Grounded Interview (only if "Up front")

Don't jump to questions. Dispatch 1–2 narrow explore agents first, **scoped to ambiguity-finding**, not seam mapping (Phase 2 does the broad map):

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Ambiguity scout: <area>",
	"message":"What existing patterns or conventions in <area> might apply to <user task>? Report 2–3 concrete patterns with file:line refs and a one-sentence description of each. Don't propose solutions.",
	"detach":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Ambiguity scout: <area>" message="What existing patterns or conventions in <area> might apply to <user task>? Report 2–3 concrete patterns with file:line refs and a one-sentence description. Don'\\''t propose solutions." detach=true'
```
"""))

When the explores return, ask 2–4 questions the findings made askable. Good shapes:

- *"Two existing patterns could apply: `<patternA>` in `<file>` and `<patternB>` in `<file>`. Which fits — or does this need a new pattern?"*
- *"Current behavior assumes `<invariant>`. Is that load-bearing, or are you open to changing it?"*
- *"This work could land in `<module A>` or `<module B>`. Any preference on scope?"*

Use `ask_user` per question, or batch related ones. Wait for answers; fold them into your working understanding before Phase 2.

The user picked **Up front** — they explicitly asked to be involved here. If any `ask_user` returns `timed_out: true`, **halt** — don't fold a non-answer in, don't proceed to Phase 2 with an assumed answer, don't silently demote them to Hands-off. Report you're waiting on the outstanding question(s) and stop. Resume Phase 1.5 from the same prompt when the user replies. (`skipped: true` is fine — treat it as the user opting out of that one question and continue with what you know.)

---

## Phase 2: Map the Seams

Dispatch explore agents in parallel to map the surface area the plan will touch. Three lanes — use only what's relevant:

| Lane | When to use | Question shape |
|------|-------------|----------------|
| **In-workspace seams** | Always | "How does `<subsystem>` connect to `<adjacent area>`? Key types, extension points, file:line refs." |
| **External research** | Only when the plan depends on external APIs, libraries, standards, or behaviour outside the repo | "Look up <library/API/RFC>. Report current behavior, version notes, and links." |
| **Prior art** | When the area has likely been touched before | "Check `docs/plans/`, `docs/completed/`, recent commits in `<area>`. Anything similar tried? Summarize." |

Each explore gets ONE narrow question. Spawn with `detach: true`, then wait on the batch.

\(example(variant,
	mcp: """
```json
// In-workspace seam probe
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Seams: <area>",
	"message":"How does <subsystem> connect to <adjacent area>? Key types, extension points, file:line refs. No proposals.",
	"detach":true
}}

// External research probe (only if relevant)
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"External: <topic>",
	"message":"Look up <library/API/RFC>. Report current behavior, version notes, and 2–3 links.",
	"detach":true
}}

{"tool":"agent_run","args":{"op":"wait","session_ids":["<id1>","<id2>"],"timeout":120}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Seams: <area>" message="How does <subsystem> connect to <adjacent area>? Key types, extension points, file:line refs." detach=true'
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="External: <topic>" message="Look up <library/API/RFC>. Report current behavior, version notes, and 2–3 links." detach=true'
rp-cli -w <window_id> -e 'agent_run op=wait session_ids=["<id1>","<id2>"] timeout=120'
```
"""))

> ⚠️ **Detached agents may block on permission approvals.** Poll periodically or use `op=wait` so you can approve and keep them unblocked.

Skip lanes that don't apply. **Don't dispatch external research just because you can** — the relevance trigger is "the plan depends on facts I can't see in this workspace."

**Capture the findings — don't just absorb them.** The explore agents did real reconnaissance, but they also return a lot. Curate: distill the *load-bearing* evidence — file:line refs, type names, extension points, links, prior art (including anything useful the Phase 1.5 ambiguity scouts surfaced) — into the plan's `## Background` when you scaffold the file next. The goal is enough grounding that \(builderName) doesn't re-derive seams from scratch — not a verbatim dump of every agent's output. When unsure whether a concrete reference matters, keep it; leave the raw transcripts and narration behind.

---

## Phase 3: Scaffold the Plan File

Create `docs/plans/<topic>-<YYYY-MM-DD>.md`. Seed it with a **lightweight scaffold** — the standard sections are **Goal**, **Background**, **Open Questions**, and **References** — with one exception: **`## Background` is populated substantively now**, with the curated Phase 2 explore findings. It's distilled evidence — not draft prose, not raw agent output — and \(builderName) reads it in Phase 4. Goal stays a sentence or two; Approach and Work Items wait for \(builderName).

\(example(variant,
	mcp: """
```json
{"tool":"file_actions","args":{
	"action":"create",
	"path":"docs/plans/<topic>-<YYYY-MM-DD>.md",
	"content":"# <Topic>: Plan\\n\\n## Goal\\n<1–2 sentence restatement in the codebase's actual terms>\\n\\n## Background\\n<curated Phase 2 explore findings — the load-bearing seams with file:line refs and type names, prior art, external research with links. Distilled evidence for \(builderName), not raw agent output.>\\n\\n## Open Questions\\n<anything still unresolved after Phase 1 / Phase 2>\\n\\n## References\\n<external links, prior plans, supporting docs>\\n"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'file create docs/plans/<topic>-<YYYY-MM-DD>.md "# <Topic>: Plan

## Goal
<1–2 sentence restatement in the codebase'\\''s actual terms>

## Background
<curated Phase 2 explore findings — the load-bearing seams with file:line refs and type names, prior art, external research with links. Distilled evidence for \(builderName), not raw agent output.>

## Open Questions
<anything still unresolved after Phase 1 / Phase 2>

## References
<external links, prior plans, supporting docs>
"'
```
"""))

Don't write the Approach or Work Items yet — \(builderName) produces those.

---

## Phase 4: \(builderName) Plan Pass

Call \(builderName) in plan mode with `export_response: true`. Pass the plan path and the contextualized prompt — pointing at the plan file lets the builder ground its output in the explore findings you captured in `## Background`:

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
	"instructions":"<task><user task, restated in the codebase's terms></task>\\n\\n<context>See the in-progress plan at `docs/plans/<topic>-<YYYY-MM-DD>.md` — its `## Background` section holds the curated explore-agent findings (seams, file:line refs, prior art, external research), plus the goal and open questions gathered so far. Build on that context rather than re-deriving it.\\n\\nProduce a concrete approach + ordered work items. Note tradeoffs only when they change the recommended path.</context>",
	"response_type":"plan",
	"export_response":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task><user task, restated in the codebase'\\''s terms></task>

<context>See the in-progress plan at docs/plans/<topic>-<YYYY-MM-DD>.md — its ## Background section holds the curated explore-agent findings (seams, file:line refs, prior art, external research), plus the goal and open questions gathered so far. Build on that context rather than re-deriving it.

Produce a concrete approach + ordered work items. Note tradeoffs only when they change the recommended path.</context>" --response-type plan --export'
```
"""))

The tool returns `oracle_export_path`. **The export is your draft** — \(builderName)'s plan pass is more grounded than your scaffold, and if it framed the approach and work items well, that framing *is* design output worth keeping. Build the plan body *out of it*; don't pre-edit it down.

1. Read the export with `read_file`.
2. Copy its substantive content — the proposed approach, ordered work items, named seams — into the plan file (the plan substance, not any raw file dumps or transcripts the export may carry). This becomes the body of your plan. Keep the export's framing where it's good; you're assembling the draft, not second-guessing its specificity. That's the Phase 6 critique's job.
3. Keep the scaffold's framing: your `## Goal` (restated in the codebase's terms) stays, and make sure each work item carries the repo's convention — **Goal**, **Done when**, **Key files**, **Dependencies**, and **Size**. `Done when` pins the *outcome* without dictating the *path*.
4. Assert voice and fill genuine gaps: tidy \(builderName)'s phrasing into the plan's voice, and where the export is thin or hand-waves a seam, enhance it from your Phase 2 findings. Don't strip detail just because it looks tactical — leave specificity calls to Phase 6.
5. **Leave the export in place** — it is a reference input to the Phase 6 design critique. Don't delete it yet; save that path for later.

\(example(variant,
	mcp: """
```json
{"tool":"read_file","args":{"path":"<oracle_export_path>"}}

{"tool":"apply_edits","args":{
	"path":"docs/plans/<topic>-<YYYY-MM-DD>.md",
	"search":"## Open Questions",
	"replace":"## Approach\\n<the export's approach, edited into your voice — keep the detail>\\n\\n## Work Items\\n### Item 1 — <name>\\n**Goal:** <what this item achieves>\\n**Done when:** <concrete acceptance criteria>\\n**Key files:** <file:line refs>\\n\\n### Item 2 — <name>\\n...\\n\\n## Open Questions"
}}
```
_(Keep `<oracle_export_path>` for Phase 6 — do not delete it here.)_
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'read <oracle_export_path>'
rp-cli -w <window_id> -e 'call apply_edits {"path":"docs/plans/<topic>-<YYYY-MM-DD>.md","search":"## Open Questions","replace":"## Approach\\n<the export'\\''s approach, edited into your voice — keep the detail>\\n\\n## Work Items\\n### Item 1 — <name>\\n**Goal:** <...>\\n**Done when:** <...>\\n**Key files:** <file:line refs>\\n\\n## Open Questions"}'
# Keep <oracle_export_path> for Phase 6 — do not delete it here.
```
"""))

Assemble and tidy here — don't gut the draft, and don't agonize over how much *how* belongs. Phase 6 calls that.

---

## Phase 5: Mid-flow Check-in (only if "Mid-flow")

Read your own draft. Identify 2–4 ambiguities — places where \(builderName) hedged ("could go either way"), tradeoffs without a pick, or assumptions the user might want to weigh in on. Ask via `ask_user`. Fold answers in before Phase 6.

The user picked **Mid-flow** — they explicitly asked to be involved here. If any `ask_user` returns `timed_out: true`, **halt** — don't push to Phase 6 (the design critique) with unresolved ambiguities, don't silently demote them to Hands-off. Report you're waiting on the outstanding question(s) and stop. Resume Phase 5 from the same prompt when the user replies. (`skipped: true` means the user is fine with your current draft on that point — continue.)

---

## Phase 6: Bounded Design Critique

Dispatch a design agent — **once**, with tight scope — to spot-check the plan. Give it **both** the plan and the original \(builderName) export from Phase 4. The design agent is the **arbiter of specificity**: it judges where the plan over-specifies choices the implementation agent should own, and where it under-specifies or dropped useful framing the export had. It's a critic, not a co-author.

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"design",
	"session_name":"Plan critique: <topic>",
	"message":"Read the plan at `docs/plans/<topic>-<YYYY-MM-DD>.md` and the original context_builder export at `<oracle_export_path>`. Produce a max-1-page critique under `docs/reviews/`. Cover ONLY:\\n1. Top 3 under-specified seams — places an implementer would have to guess (with file:line if applicable)\\n2. Specificity balance — work items that over-specify a tactical choice the implementation agent should own, OR that dropped useful framing the export had (compare plan vs. export)\\n3. Contradictions or missing dependencies in the plan\\n4. Risk of over-planning — sections that should be cut or simplified\\n5. Questions whose answers would change implementation order\\n\\nDo NOT expand scope, do NOT rewrite the plan, do NOT do broad codebase exploration unless one named seam needs spot-checking.",
	"wait":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=design session_name="Plan critique: <topic>" message="Read the plan at docs/plans/<topic>-<YYYY-MM-DD>.md and the original context_builder export at <oracle_export_path>. Produce a max-1-page critique under docs/reviews/. Cover ONLY: top 3 under-specified seams an implementer would have to guess (with file:line if applicable); specificity balance — work items that over-specify tactical choices the implementer should own, or that dropped useful framing the export had (compare plan vs export); contradictions or missing dependencies; risk of over-planning (sections to cut or simplify); questions whose answers would change implementation order. Do NOT expand scope, rewrite the plan, or do broad exploration." wait=true'
```
"""))

When the critique returns, fold actionable findings into the plan: tighten under-specified seams, loosen over-specified ones, restore useful framing the plan dropped, resolve contradictions, cut what should be cut. **Don't fold in the critique itself** — its job is to inform your edits, not to live in the plan.

Once the critique is folded in, the \(builderName) export has served its purpose — **delete it now** so `prompt-exports/` doesn't accumulate:

\(example(variant,
	mcp: """
```json
{"tool":"file_actions","args":{"action":"delete","path":"<oracle_export_path>"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'call file_actions {"action":"delete","path":"<oracle_export_path>"}'
```
"""))

It's still a plan, not an implementation. Don't over-engineer this pass — the design agent is looking for genuine gaps, not nitpicks.

---

## Phase 7: Editorial Polish + Final Hand-off

The plan should be **clearer and tighter** after this pass. The Phase 6 critique already settled what's over- or under-specified — this pass is editorial, not structural. Specific moves:

- Drop tradeoff narration unless one tradeoff is load-bearing.
- Promote concrete next steps; demote speculation.
- Verify `file:line` refs and external links are accurate.
- Trim genuinely duplicated context — the same evidence stated twice — but preserve the curated load-bearing Phase 2 refs in `## Background`.
- Make sure each section earns its space; remove anything that doesn't.

**Acceptance criteria for the final plan:**

- [ ] Lives at `docs/plans/<topic>-<YYYY-MM-DD>.md`
- [ ] Sections are concise and well-organized (Goal, Background, Approach, Work Items, Open Questions, References — adjust as the task warrants)
- [ ] No transcript dumps, no raw agent output
- [ ] Open questions only if they would block or shape implementation
- [ ] A reader unfamiliar with the area can pick it up and execute

If the user picked **Hands-off**, surface the plan now and offer interactive refinement: *"Plan is at `<path>`. Want me to revise any section, expand scope, or trim anything?"* Treat each round as a focused edit pass on the file, not a re-plan.

For **all** modes, report:

- Plan path
- 2–3 sentence summary
- Any open questions that survived the polish pass
- Suggested next workflow (`rp-build` for direct implementation, `rp-orchestrate` for multi-agent execution)

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance, includeStrayPlanExportCleanup: true))
---

## Anti-patterns

- 🚫 Skipping the involvement-level question — always ask first; the answer changes the run
- 🚫 Asking generic or thin questions when in "Up front" / "Mid-flow" mode — questions must be informed by exploration findings or by the current draft's ambiguities
- 🚫 More than 4 questions per checkpoint — interrogation isn't shaping
- 🚫 Implementing code — this workflow ends at a plan
- 🚫 Pasting full file contents into the plan — refer to `file:line`, don't reproduce
- 🚫 Losing the Phase 2 explore findings — distill the load-bearing evidence into `## Background`; it's \(builderName)'s critical context
- 🚫 Dumping raw explore-agent output into `## Background` — curate it; the section is distilled evidence, not transcripts
- 🚫 Treating the \(builderName) export as a skeleton to mine — it's your *draft*; build the plan out of it and keep its framing where it's good
- 🚫 Pre-editing the export's specificity in Phase 4 — copy it in faithfully; the Phase 6 critique is the arbiter of how much *how* belongs
- 🚫 Over-specifying tactical choices the implementation agent should own — the plan locks down decisions, not every step
- 🚫 Deleting the \(builderName) export before the Phase 6 design critique has used it — it's a critique input; delete it only after the critique is folded in
- 🚫 Letting the design critique rewrite the plan — it's a critic, not a co-author
- 🚫 Dispatching external/web research when the plan only depends on in-repo facts — the trigger is real external dependency
- 🚫 Doing broad codebase reading yourself instead of dispatching an explore agent — keep your context lean for writing
- 🚫 Forgetting to poll dispatched agents — they may block on permission approvals
- 🚫 Silently demoting an Up-front / Mid-flow user to Hands-off when their checkpoint `ask_user` times out — they asked to be involved; honor it. Halt and resume when they reply. (Phase 1's involvement-mode prompt is the one exception: a timeout there is treated as "no signal" and falls through to the Hands-off default.)\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` — CLI invocations are stateless and require explicit window targeting" : "")

---

Now begin with Phase 0.\(variant == .cli ? " First run `rp-cli -e 'windows'` to find the correct window." : "")
"""
	}

	/// Token-efficient reminder to use RepoPrompt tools (MCP variant).
	/// No arguments - just a gentle nudge to prefer RP tools over built-in alternatives.
	static let rpReminder = rpReminder(variant: .mcp)

	/// Generate rp-mcp (reminder) for a specific variant.
	static func rpReminder(variant: ToolVariant) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-reminder", description: "Reminder to use \(toolDesc)", variant: variant))

# RepoPrompt Tools Reminder\(suffix)

Continue your current workflow using \(toolDesc) instead of built-in alternatives.

## File & Code

| Task | Use | Not |
|------|-----|-----|
| Search paths/content | \(variant == .cli ? "`search`" : "`file_search`") | grep, find, Glob |
| Read file (whole or sliced) | \(variant == .cli ? "`read`" : "`read_file`") | cat, head, Read |
| Directory tree | \(variant == .cli ? "`tree`" : "`get_file_tree`") | ls, find |
| Signatures / overview | \(variant == .cli ? "`structure`" : "`get_code_structure`") | reading whole files |
| Edit file | \(variant == .cli ? "`edit`" : "`apply_edits`") | sed, Edit |
| Create / delete / move | \(variant == .cli ? "`file`" : "`file_actions`") | touch, rm, mv, Write |
| Git status / diff / log / blame | `git` | shelling out for analysis |

## Context & Planning

| Tool | Use for |
|------|---------|
| `manage_selection` | Curate the file set used by chat, builder, and exports. Refresh before each planning call. Modes: `full`, `slices`, `codemap_only`. |
| `workspace_context` | Snapshot current prompt + selection + token budget; also exports. |
| `prompt` | Read/set the shared prompt; list or select copy presets. |
| `context_builder` | Heavy discovery sub-agent — describe the task, it curates files + rewrites the prompt. `response_type`: `clarify` / `plan` / `question` / `review`. Pass `export_response:true` to hand the result to a child agent. |
| \(variant == .cli ? "`chat` (`ask_oracle`)" : "`ask_oracle`") | Chat-mode reasoning over the current selection. Continue existing chats (`new_chat:false`) rather than opening new ones. Modes: `chat` / `plan` / `review`. |
| `oracle_chat_log` | Recover recent Oracle messages after compaction. |
| `ask_user` | Ask the user when ambiguity is load-bearing — don't guess at requirements. |

## Agent Delegation — `agent_run` / `agent_manage`

Dispatch a sub-agent when a side investigation or delegated chunk of work would otherwise flood this session's context.

**Role labels** (pass as `model_id` on `agent_run op=start`):

| Role | Use for |
|------|---------|
| `explore` | Fast **read-only** probes — git archaeology, "where is X wired?", narrow lookups, web/doc search. One question per probe. |
| `engineer` | Balanced implementation work delegated to a child agent. |
| `pair` | Multi-step reasoning with back-and-forth — lead investigator or main implementer of a decomposed item. |
| `design` | Architecture / review / extended analysis — primary deliverable is a markdown report under `docs/reviews/`, `docs/designs/`, or `docs/analysis/`. Expect the report path in the summary. |

**Key `agent_run` ops:** `start` (creates a new session/tab — never pass `session_id` here), `wait` / `poll` (accept `session_id` **or** `session_ids` array), `steer` (continue an existing session), `respond` (answer a pending `interaction_id`), `cancel`.

**Key `agent_manage` ops:** `list_agents` (discover roles + compound model_ids), `list_sessions`, `get_log`, `cleanup_sessions` (delete finished MCP-started sessions).

**Fan-out pattern:** call `agent_run op=start` with `detach:true` for each probe, then `agent_run op=wait session_ids=[…]` to block on the batch. Always follow a `detach` with a `wait` — don't leave probes unattended.

**Export handoff:** when `context_builder` or `ask_oracle` returns `oracle_export_path`, include that path inside the child agent's next `message` so it reads the export with `read_file`.

## Quick Reference

\(example(variant,
	mcp: """
```json
// Search · Read · Edit · File ops
{"tool":"file_search","args":{"pattern":"keyword","mode":"auto"}}
{"tool":"read_file","args":{"path":"Root/file.swift","start_line":50,"limit":30}}
{"tool":"apply_edits","args":{"path":"Root/file.swift","search":"old","replace":"new"}}
{"tool":"file_actions","args":{"action":"create","path":"Root/new.swift","content":"..."}}

// Selection · Builder · Oracle
{"tool":"manage_selection","args":{"op":"add","paths":["Root/path/file.swift"]}}
{"tool":"context_builder","args":{"instructions":"<task>","response_type":"plan"}}
{"tool":"ask_oracle","args":{"message":"...","mode":"plan","new_chat":false}}

// Delegate · Fan-out · Steer · Cleanup
{"tool":"agent_run","args":{"op":"start","model_id":"explore","session_name":"Probe: X","message":"<question>","detach":true}}
{"tool":"agent_run","args":{"op":"wait","session_ids":["<uuid1>","<uuid2>"],"timeout":60}}
{"tool":"agent_run","args":{"op":"steer","session_id":"<uuid>","message":"now do Y","wait":true}}
{"tool":"agent_manage","args":{"op":"cleanup_sessions","session_ids":["<uuid>"]}}
```
""",
	cli: """
```bash
# Search · Read · Edit · File ops
rp-cli -w <window_id> -e 'search "keyword"'
rp-cli -w <window_id> -e 'read Root/file.swift --start-line 50 --limit 30'
rp-cli -w <window_id> -e 'call apply_edits {"path":"Root/file.swift","search":"old","replace":"new"}'
rp-cli -w <window_id> -e 'file create Root/new.swift "content..."'

# Selection · Builder · Oracle
rp-cli -w <window_id> -e 'select add Root/path/file.swift'
rp-cli -w <window_id> -e 'builder "<task>" --response-type plan'
rp-cli -w <window_id> -e 'chat "..." --mode plan'

# Delegate · Fan-out · Steer · Cleanup
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Probe: X" message="<question>" detach=true'
rp-cli -w <window_id> -e 'agent_run op=wait session_ids=["<uuid1>","<uuid2>"] timeout=60'
rp-cli -w <window_id> -e 'agent_run op=steer session_id="<uuid>" message="now do Y" wait=true'
rp-cli -w <window_id> -e 'agent_manage op=cleanup_sessions session_ids=["<uuid>"]'
```
"""))

Continue with your task using these tools.
"""
	}

	/// CLI variant of rp-mcp (reminder) - uses rp-cli commands.
	static var rpReminderCLI: String { rpReminder(variant: .cli) }

	/// The rp-build slash command - context builder workflow (MCP variant).
	static let rpBuild = rpBuild(variant: .mcp)

	/// Generate rp-build for a specific variant.
	static func rpBuild(variant: ToolVariant) -> String {
		let suffix: String
		let title: String
		switch variant {
		case .cli: suffix = " (CLI)"; title = "CLI Builder Mode"
		case .agent: suffix = ""; title = "Builder Mode"
		case .mcp: suffix = ""; title = "MCP Builder Mode"
		}
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"

		return """
\(frontmatter(name: "rp-build", description: "Build with \(toolDesc) context builder plan → implement", variant: variant))

# \(title)\(suffix)

Task: $ARGUMENTS

Build deep context via \(builderName) to get a plan, then implement directly. Use follow-up reasoning only when navigating the selected code proves difficult or the plan leaves a concrete gap.

\(variant.preamble)\(rpBuildCore(variant: variant))
"""
	}

	// MARK: - ChatGPT Prompt Export

	/// The rp-oracle-export command - exports a prompt file for GPT Pro models on ChatGPT (MCP variant).
	static let rpOracleExport = rpOracleExport(variant: .mcp)

	/// Generate rp-oracle-export for a specific variant.
	static func rpOracleExport(variant: ToolVariant) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"
		let isAgent = variant == .agent
		let reviewBudgetRule: String
		let budgetGuidanceLine: String
		let reviewFastPathLine: String
		let reviewDeepPathLine: String

		switch variant {
		case .agent:
			reviewBudgetRule = "Use the workflow's export-mode budget guidance. Only skip `context_builder` when the uncommitted review scope is small enough that the full changed-file review export clearly fits within that budget."
			budgetGuidanceLine = "Use the workflow's export-mode budget guidance unless the user explicitly asks for a leaner or larger export."
			reviewFastPathLine = "For `Review`, the fast path is the **exception**, not the default. It is allowed only when the confirmed scope is **uncommitted changes** and the **full changed-file review scope** clearly fits within the workflow's export-mode budget."
			reviewDeepPathLine = "For `Review`, this is the default path. If the review is not a small uncommitted-change export that clearly fits within the workflow's export-mode budget with all changed files included, `context_builder` is required."
		case .mcp, .cli:
			reviewBudgetRule = "This prompt does not expose the workflow export-mode budget directly. Lean on `context_builder` unless the uncommitted review scope is clearly tiny, obviously bounded, and safe to include in full."
			budgetGuidanceLine = "Because this prompt does not expose the workflow export budget directly, prefer `context_builder` unless the review scope is obviously tiny."
			reviewFastPathLine = "For `Review`, the fast path is the **exception**, not the default. It is allowed only when the confirmed scope is **uncommitted changes** and the **full changed-file review scope** is obviously tiny and safe to include in full. Otherwise require `context_builder`."
			reviewDeepPathLine = "For `Review`, this is the default path. If the review is not a tiny uncommitted-change export that is obviously safe to include in full, `context_builder` is required."
		}

		return """
\(frontmatter(name: "rp-oracle-export", description: "Export a ChatGPT-ready Question / Plan / Review prompt using \(toolDesc)", variant: variant))

# ChatGPT Prompt Export\(suffix)

Raw request: $ARGUMENTS

Your job: select the right files and export a prompt file that another model can act on directly.

**Before you do anything else**, extract the real task from the raw request above. Users often phrase this as "export a prompt for X" or "write a prompt about Y" — strip away any meta-framing about exporting/prompting and identify the underlying problem. For example:
- "export a prompt to evaluate the auth refresh logic" → the task is "evaluate the auth refresh logic"
- "write a ChatGPT prompt about the token caching bug" → the task is "investigate the token caching bug"
- "review the last 3 commits" → the task is already clean

Use the extracted task (not the raw request) for all downstream steps — intent classification, `context_builder` instructions, and the final exported prompt.

## Rules

- Infer **Question / Plan / Review** when obvious. Ask only if unclear.
- For vague requests, use repo evidence before asking questions.
- Use the fast path only when the scope is already small, concrete, and obviously file-local.
- For broad **Question/Plan** exports, `context_builder` is the default path.
- For review exports, `context_builder` is the default path.
- Do **not** spend exploratory tool calls proving that a broad request is complex enough for `context_builder`.
- When you do use `context_builder` here, keep `response_type: "clarify"`.
- If you used the fast path, review the selection and prompt text before exporting.
- If you used `context_builder`, trust its curated selection, budget, and generated prompt by default; only re-check or adjust prompt/selection/tokens if you noticed a concrete issue.
- Export to a unique repo-local file, usually in `prompt-exports/`.
- Derive a short slug from the user's request and use it in the filename.
- Use a relative repo-local path by default; do not use an absolute path or another folder unless the user explicitly asks for it.

## Workflow
\(workspaceVerificationBlock(variant: variant, heading: "### 0", beforeAction: "building context", nextStep: "Step 1"))
### 1. Determine intent and scope

Infer the prompt type from the request:
- **Review** for git diff / PR / branch comparison requests — i.e. the user wants to inspect *changes*
- **Plan** for design / approach / implementation-plan / architectural audit / code evaluation requests — even if the user says "review" or "audit", if there are no diffs involved, this is a Plan
- **Question** only when the user is asking a specific, bounded question with a clear answer
- **When in doubt, default to Plan.** Generic or open-ended requests ("look into X", "help me with Y", "figure out Z") produce better results with the Plan preset, which gives the receiving model structured guidance.

If the request is vague:
- for **Review**: inspect git state first
- for **Question/Plan**: if it sounds broad, architectural, evaluative, redesign-oriented, or likely multi-file, skip manual exploration and go straight to `context_builder`

Ask **one specific question** only if needed, and base it on the repo state you found.
Good question shapes:
- “I see changes in A and B. Do you want review of these current uncommitted changes, or against `main`?”
- “I found likely touchpoints in X and Y. Is the fix plan for X only, or this broader flow?”

\(isAgent ? """
If clarification is needed, use `ask_user`:

```json
{"tool":"ask_user","args":{
  "question":"I found likely scope in <A> and <B>. Which one should the exported prompt focus on?",
  "options":["Focus on A","Focus on B","Cover both"],
  "context":"I want the export scope to match the code I found instead of guessing.",
  "timeout_seconds":90
}}
```
""" : "")
**If the scope is still unclear, STOP and ask the user.** Do not ask generic workflow questions when you could ask a concrete scope question instead.

### 2. Choose context path

\(budgetGuidanceLine)

#### Review

Start by checking git state:
\(example(variant,
	mcp: """
```json
{"tool":"git","args":{"op":"status"}}
{"tool":"git","args":{"op":"diff","detail":"files"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'git status'
rp-cli -w <window_id> -e 'git diff --detail files'
```
"""))

\(reviewScopeConfirmationBlock(variant: variant, heading: "#### Review Scope Confirmation"))

\(reviewBudgetRule)
\(reviewFastPathLine)
\(reviewDeepPathLine)
For review exports, explicitly reference the diff / changed files in the context you build.

**Always include the phrase "code review" in your `context_builder` instructions for Review exports.** This phrase activates diff analysis in the discovery agent. Without it, the builder treats the request as a general exploration.

#### Question / Plan

Default to `context_builder` for any request that is broad, architectural, evaluative, redesign-oriented, or likely to touch multiple files.

Do **not** spend tool calls proving that these requests are complex. If the user is asking you to evaluate logic, assess a design, rethink a flow, or reason about behavior across a system, call `context_builder` immediately.

Use the fast path only when the request is already small and obvious:
\(example(variant,
	mcp: """
```json
{"tool":"file_search","args":{"pattern":"<key term>","mode":"both"}}
```

```json
{"tool":"manage_selection","args":{"op":"add","paths":["RootName/path/to/FileA.swift","RootName/path/to/FileB.swift"]}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'search "<key term>"'
rp-cli -w <window_id> -e 'select add RootName/path/to/FileA.swift RootName/path/to/FileB.swift'
```
"""))

If there is any real doubt that the fast path will fully cover the task, use `context_builder`.

Otherwise use `context_builder`:
\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>The actual problem to solve — not about exporting or prompting</task>\\n<context>Scope: <what you found>.</context>",
  "response_type":"clarify"
}}
```

```json
{"tool":"context_builder","args":{
	"instructions":"<task>Code review of changes against <confirmed_scope>.</task>\\n<context>Intent: code review. Branch: <branch_name>.</context>",
  "response_type":"clarify"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>The actual problem to solve — not about exporting or prompting</task>
<context>Scope: <what you found>.</context>" --response-type clarify'

rp-cli -w <window_id> -e 'builder "<task>Code review of changes against <confirmed_scope>.</task>
<context>Intent: code review. Branch: <branch_name>.</context>" --response-type clarify'
```
"""))

### 3. Final check (fast path only — skip after `context_builder`)

**If you used `context_builder`, skip this step entirely and go straight to Step 4.** The builder already curated the selection, managed the token budget, and wrote the prompt. Do not read the prompt back, do not inspect the selection, do not check token counts, and do not critique, rewrite, or "improve" the generated prompt text. Treat the builder's output as the final payload for export.

**If you used the fast path**, check the selection and prompt text before exporting:
\(example(variant,
	mcp: """
```json
{"tool":"manage_selection","args":{"op":"get","view":"summary"}}
```

```json
{"tool":"prompt","args":{"op":"get"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'select get'
rp-cli -w <window_id> -e 'prompt get'
```
"""))

If available in this surface, the fast path may also inspect token state:
\(example(variant,
	mcp: """
```json
{"tool":"workspace_context","args":{"include":["selection","tokens"]}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'context --include selection,tokens'
```
"""))

If the prompt wording or selection is off, fix it before exporting.

### 4. Export

Use a unique repo-local relative path such as:
- `prompt-exports/<yyyy-mm-dd>-<hhmmss>-question-<slug-from-request>.md`
- `prompt-exports/<yyyy-mm-dd>-<hhmmss>-plan-<slug-from-request>.md`
- `prompt-exports/<yyyy-mm-dd>-<hhmmss>-review-<slug-from-request>.md`

Choose `<slug-from-request>` by summarizing the user's request into a short filesystem-safe phrase. Prefer descriptive slugs like `collapsing-tool-logic` or `agent-transcript-redesign`, not generic names like `export` or `question`.

Unless the user explicitly asks for another destination, keep the export path relative and repo-local under `prompt-exports/`.

Preset mapping:
- `Question` → `standard` (only for specific, bounded questions)
- `Plan` → `plan` (default for generic, open-ended, or ambiguous requests)
- `Review` → `codeReview`

\(example(variant,
	mcp: """
```json
{"tool":"prompt","args":{"op":"export","path":"prompt-exports/<unique filename>.md","copy_preset":"<standard|plan|codeReview>"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'prompt export "prompt-exports/<unique filename>.md" --copy-preset <standard|plan|codeReview>'
```
"""))

## Anti-patterns

- Asking generic workflow questions before checking repo state
- Skipping `context_builder` for branch / PR / large review exports
- Doing exploratory searches or file reads before `context_builder` for a broad Question/Plan export just to prove the task is complex
- Treating requests like "evaluate this logic", "assess this design", or "rethink this flow" as fast-path exports
- Using the fast path when scope is still vague
- Exporting from the fast path without checking the selection and prompt text
- Re-checking selection, prompt text, or tokens after `context_builder` — the builder already finalized the payload
- Reading the prompt back after `context_builder` to review, critique, rewrite, or "improve" it — export it as-is
- Calling `prompt get`, `manage_selection get`, or `workspace_context` after `context_builder` completed — go straight to export
- Reusing generic filenames like `oracle-prompt.md` by default
- Using generic slugs like `export`, `question`, or `plan` when the request gives you enough detail for a better filename
- Writing to an absolute path or outside the repo by default when the user did not ask for that
- Passing export/prompt meta-framing to `context_builder` — instructions like "export a prompt for X" or "build context for a ChatGPT prompt about Y" cause the builder to write a prompt *about prompting* instead of a prompt that solves X. Always pass the extracted task directly.

Report the final export path, prompt type, whether you used the fast path or `context_builder`, and token count if available.
"""
	}

	/// CLI variant of rp-oracle-export - uses rp-cli commands.
	static var rpOracleExportCLI: String { rpOracleExport(variant: .cli) }

	// MARK: - Review

	/// The rp-review slash command - code review workflow (MCP variant).
	static let rpReview = rpReview(variant: .mcp)

	/// Generate rp-review for a specific variant.
	static func rpReview(variant: ToolVariant) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-review", description: "Code review workflow using \(toolDesc) git tool and context_builder", variant: variant))

# Code Review Mode\(suffix)

Review: $ARGUMENTS

You are a **Code Reviewer** using \(toolDesc). Your workflow: understand the scope of changes, gather context, and provide thorough, actionable code review feedback.

\(variant.preamble)\(rpReviewCore(variant: variant))
"""
	}

	/// CLI variant of rp-review.
	static var rpReviewCLI: String { rpReview(variant: .cli) }

	/// Core review workflow content.
	static func rpReviewCore(variant: ToolVariant) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatToolName = variant == .agent ? "ask_oracle" : "oracle_send"
		let isAgent = variant == .agent

		return """
## Protocol
\(isAgent ? "" : "\n0. **Verify workspace** – Confirm the target codebase is loaded\(variant == .cli ? " and identify the correct window" : "").")
1. **Survey changes** – Check git state and recent commits to understand what's changed.
2. **Determine scope** – Infer the comparison scope from the user's request. Only ask for clarification if the scope is ambiguous or unspecified.
3. **Deep review** – Run \(builderName) with `response_type: "review"`, explicitly specifying the confirmed comparison scope.
4. **Fill gaps** – If the review missed areas, run focused follow-up reviews explicitly describing what was/wasn't covered.

---
\(workspaceVerificationBlock(variant: variant, heading: "## Step 0", beforeAction: "git operations", nextStep: "Step 1"))
## Step 1: Survey Changes
\(example(variant,
	mcp: """
```json
{"tool":"git","args":{"op":"status"}}
{"tool":"git","args":{"op":"log","count":10}}
{"tool":"git","args":{"op":"diff","detail":"files"}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'git status'
rp-cli -w <window_id> -e 'git log --count 10'
rp-cli -w <window_id> -e 'git diff --detail files'
```
"""))

\(reviewScopeConfirmationBlock(variant: variant))

## Step 3: Deep Review (via \(builderName) - REQUIRED)

⚠️ Don't skip this step. Call \(builderName) with `response_type: "review"` for proper code review context.

Include the confirmed comparison scope in your instructions so the context builder knows exactly what to review.

Use XML tags to structure the instructions:
\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>Review changes comparing <current_branch> against <confirmed_comparison_target>. Focus on correctness, security, API changes, error handling.</task>\n\n<context>Comparison: <confirmed_scope> (e.g., 'uncommitted', 'main', 'staged')\nCurrent branch: <branch_name>\nChanged files: <list key files from git diff></context>\n\n<discovery_agent-guidelines>Focus on the directories containing changes.</discovery_agent-guidelines>",
  "response_type":"review"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>Review changes comparing <current_branch> against <confirmed_comparison_target>. Focus on correctness, security, API changes, error handling.</task>

<context>Comparison: <confirmed_scope> (e.g., uncommitted, main, staged)
Current branch: <branch_name>
Changed files: <list key files></context>

<discovery_agent-guidelines>Focus on directories containing changes.</discovery_agent-guidelines>" --response-type review'
```
"""))
\(variant == .cli ? "\n**Tab routing:** The builder response returns a `tab_id` — pass `-t <tab_id>` in follow-up `chat` invocations to continue the same conversation.\n" : "")
## Optional: Clarify Findings

After receiving review findings, you can ask clarifying questions in the same chat:
\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<from context_builder>",
  "message":"Can you explain the security concern in more detail? What's the attack vector?",
  "mode":"chat",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -t '<tab_id>' -e 'chat "Can you explain the security concern in more detail? What'\\''s the attack vector?" --mode chat'
```

> Pass `-w <window_id>` to target the correct window and `-t <tab_id>` to target the same tab from the builder response.
"""))

## Step 4: Fill Gaps

If the review omitted significant areas, run a focused follow-up. **Explicitly describe** what was already covered and what needs review now (\(builderName) has no memory of previous runs):
\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>Review <specific area> in depth.</task>\n\n<context>Previous review covered: <list files/areas reviewed>.\nNot yet reviewed: <list files/areas to review now>.</context>\n\n<discovery_agent-guidelines>Focus specifically on <directories/files not yet covered>.</discovery_agent-guidelines>",
  "response_type":"review"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>Review <specific area> in depth.</task>

<context>Previous review covered: <list files/areas reviewed>.
Not yet reviewed: <list files/areas to review now>.</context>

<discovery_agent-guidelines>Focus specifically on <directories/files not yet covered>.</discovery_agent-guidelines>" --response-type review'
```
"""))

---

## Anti-patterns to Avoid

- 🚫 Proceeding with an ambiguous scope – if the user didn't specify a comparison target and it's unclear from context, you must ask before calling \(builderName)
- 🚫 Skipping \(builderName) and attempting to review by reading files manually – you'll miss architectural context
- 🚫 Calling \(builderName) without specifying the confirmed comparison scope in the instructions
- 🚫 Doing extensive file reading before calling \(builderName) – git status/log/diff is sufficient for Step 1
- 🚫 Providing review feedback without first calling \(builderName) with `response_type: "review"`
- 🚫 Assuming the git diff alone is sufficient context for a thorough review
- 🚫 Reading changed files manually instead of letting \(builderName) build proper review context\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` – CLI invocations are stateless and require explicit window targeting" : "")

---

## Output Format (be concise, max 15 bullets total)

- **Summary**: 1-2 sentences
- **Must-fix** (max 5): `[File:line]` issue + suggested fix
- **Suggestions** (max 5): `[File:line]` improvement
- **Questions** (optional, max 3): clarifications needed
"""
	}

	private static func reviewScopeConfirmationBlock(variant: ToolVariant, heading: String = "## Step 2: Determine Comparison Scope") -> String {
		let isAgent = variant == .agent
		return """
\(heading)

Determine the comparison scope from the user's request and git state.

**If the user already specified a clear comparison target** (e.g., "review against main", "compare with develop", "review last 3 commits"), **skip confirmation and proceed** using the scope they specified.

**If the scope is ambiguous or not specified**, ask the user to clarify:
- **Current branch**: What branch are you on? (from git status)
- **Comparison target**: What should changes be compared against?
  - `uncommitted` – All uncommitted changes vs HEAD (default)
  - `staged` – Only staged changes vs HEAD
  - `back:N` – Last N commits
  - `main` or `master` – Compare current branch against trunk
  - `<branch_name>` – Compare against specific branch

\(isAgent ? """
If clarification is needed, use `ask_user`:

```json
{"tool":"ask_user","args":{
  "question":"You're on branch `feature/xyz`. What should I compare against?\\n- `uncommitted` (default) - review all uncommitted changes\\n- `main` - review all changes on this branch vs main\\n- Other branch name?"
}}
```
""" : """
**Example prompt to user (only if scope is unclear):**
> "You're on branch `feature/xyz`. What should I compare against?
> - `uncommitted` (default) - review all uncommitted changes
> - `main` - review all changes on this branch vs main
> - Other branch name?"

**If you need to ask, STOP and wait for user confirmation before proceeding.**
""")
"""
	}

	// MARK: - Refactor

	/// The rp-refactor slash command - refactoring assistant (MCP variant).
	static let rpRefactor = rpRefactor(variant: .mcp)

	/// Generate rp-refactor for a specific variant.
	static func rpRefactor(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-refactor", description: "Refactoring assistant using \(toolDesc) to analyze and improve code organization", variant: variant))

# Refactoring Assistant\(suffix)

Refactor: $ARGUMENTS

You are a **Refactoring Assistant** using \(toolDesc). Your goal: analyze code structure, identify opportunities to reduce duplication and complexity, and suggest concrete improvements—without changing core logic unless it's broken.

\(variant.preamble)\(rpRefactorCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// CLI variant of rp-refactor.
	static var rpRefactorCLI: String { rpRefactor(variant: .cli) }

	/// Core refactoring workflow content.
	static func rpRefactorCore(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatToolName = variant == .agent ? "ask_oracle" : "oracle_send"
		let isAgent = variant == .agent

		return """
## Goal

Analyze code for redundancies and complexity, then orchestrate agents to implement improvements. **Preserve behavior** unless something is broken.

---

## Protocol
\(isAgent ? "" : "\n0. **Verify workspace** – Confirm the target codebase is loaded\(variant == .cli ? " and identify the correct window" : "").")
1. **Scope & Analyze** – Scout target areas with explore agents, then use \(builderName) with `response_type: "review"` informed by their findings.
2. **Plan** – Use \(builderName) with `response_type: "plan"` and `export_response: true` to generate and export a refactoring plan.
3. **Decompose & Dispatch** – Break the plan into ordered work items and dispatch agents to implement.
4. **Verify** – Check each completed item before proceeding to the next.

---
\(workspaceVerificationBlock(variant: variant, heading: "## Step 0", beforeAction: "analysis", nextStep: "Step 1"))
## Step 1: Scope & Analyze

### 1a. Scout the territory with explore agents

Before calling \(builderName), dispatch explore agents to map the areas the user wants refactored. A quick `get_file_tree` or `file_search` orients you, then spawn 2–3 explore agents for the most relevant areas:

\(example(variant,
	mcp: """
```json
// Quick orientation
{"tool":"get_file_tree","args":{"type":"files","mode":"auto"}}

// Dispatch explore agents to scout target areas
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Scout: <area 1>",
	"message":"Map <target area>: what are the key types, their responsibilities, and how do they interact? Note any obvious duplication or complexity.",
	"detach":true
}}
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Scout: <area 2>",
	"message":"Check <related area> — what patterns does it use? How does it relate to <area 1>? Any shared logic that could be consolidated?",
	"detach":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'tree'
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Scout: <area 1>" message="Map <area>: key types, responsibilities, interactions. Note duplication." detach=true'
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Scout: <area 2>" message="Check <area> — patterns, relationship to <area 1>, shared logic." detach=true'
```
"""))

Keep each explore prompt **short and focused** — one area per agent. Good: "Map the auth module's types and interactions." Bad: "Find all refactoring opportunities in the codebase."

Collect results before proceeding:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{"op":"wait","session_ids":["<id_1>","<id_2>"],"timeout":60}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=wait session_ids=["<id_1>","<id_2>"] timeout=60'
```
"""))

Not every refactor needs explore agents. If the user's request already names specific files and the scope is narrow, skip straight to 1b.

### 1b. Analyze with \(builderName) (REQUIRED)

⚠️ Don't skip this step. Use the explore agents' findings to write a well-informed \(builderName) call with `response_type: "review"`:

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
	"instructions":"<task>Analyze for refactoring opportunities. Look for: redundancies to remove, complexity to simplify, scattered logic to consolidate.</task>\n\n<context>Target: <files, directory, or recent changes to analyze>.\nGoal: Preserve behavior while improving code organization.\n\nFrom initial scouting:\n- <key finding from explore agent 1>\n- <key finding from explore agent 2>\n- <patterns/duplication already identified></context>\n\n<discovery_agent-guidelines>Focus on <target directories/files informed by scouting>.</discovery_agent-guidelines>",
  "response_type":"review"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>Analyze for refactoring opportunities. Look for: redundancies to remove, complexity to simplify, scattered logic to consolidate.</task>

<context>Target: <files, directory, or recent changes>.
Goal: Preserve behavior while improving code organization.

From initial scouting:
- <key finding from explore agent 1>
- <key finding from explore agent 2>
- <patterns/duplication already identified></context>

<discovery_agent-guidelines>Focus on <target directories/files informed by scouting>.</discovery_agent-guidelines>" --response-type review'
```
"""))

The explore agents' findings make this call more effective — \(builderName) knows where to look and what patterns to analyze instead of discovering everything from scratch.

Review the findings. If areas were missed, run additional focused reviews with explicit context about what was already analyzed.

## Optional: Clarify Analysis

After receiving analysis findings, you can ask clarifying questions in the same chat:
\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<from context_builder>",
  "message":"For the duplicate logic you identified, which location should be the canonical one?",
  "mode":"chat",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -t '<tab_id>' -e 'chat "For the duplicate logic you identified, which location should be the canonical one?" --mode chat'
```

> Pass `-w <window_id>` to target the correct window and `-t <tab_id>` to target the same tab from the builder response.
"""))

## Step 2: Plan the Refactorings (via \(builderName) - REQUIRED)

Once you have a clear list of refactoring opportunities, use \(builderName) with `response_type: "plan"` and `export_response: true` to generate a concrete plan and export it for agents:

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>Plan these refactorings in order:</task>\n\n<context>Refactorings to apply:\n1. <specific refactoring with file references>\n2. <specific refactoring with file references>\n\nPreserve existing behavior. Order by: safest/highest-value first, respecting dependencies between changes.</context>\n\n<discovery_agent-guidelines>Focus on files involved in the refactorings.</discovery_agent-guidelines>",
  "response_type":"plan",
  "export_response":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>Plan these refactorings in order:</task>

<context>Refactorings to apply:
1. <specific refactoring with file references>
2. <specific refactoring with file references>

Preserve existing behavior. Order by: safest/highest-value first, respecting dependencies.</context>

<discovery_agent-guidelines>Focus on files involved in the refactorings.</discovery_agent-guidelines>" --response-type plan --export'
```
"""))

The tool returns `oracle_export_path` and `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next `agent_run` `start` call. The `oracle_export_instruction` field is a ready-made sentence ("Read the Oracle export at `<path>` with `read_file` …") you can emit verbatim at the head of that `message`. The child agent opens the file with `read_file`.

## Step 3: Decompose & Dispatch

Take the plan and break it into **ordered work items**. Refactorings are usually sequential — later changes often depend on structures introduced by earlier ones.

\(sharedDecompositionGuidance(variant: variant, taskNoun: "item"))

### Sequential steering loop

Start a single agent and feed it work **one item at a time**. Refactorings usually compound — later items build on structures introduced in earlier ones — so steering keeps the relevant decisions in working memory, unlike `rp-orchestrate`'s fresh-per-item default.

\(example(variant,
	mcp: """
```json
// 1. Start with the first refactoring item
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"engineer",
	"session_name":"Refactor: <overall goal>",
	"message":"Read the refactoring plan at <plan path> with read_file first. Implement refactoring item 1: <brief>. Preserve existing behavior."
}}

// 2. Agent completes — verify the change preserves behavior.
//    Spot-check key files:
{"tool":"read_file","args":{"path":"<key file from item 1>"}}

// 3. If satisfied, steer the next item:
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"Item 1 looks good. Moving on to item 2: <brief>. The structures from item 1 are now in place.",
	"wait":true
}}

// 4. If something's off, steer a correction first:
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"Item 1 missed <specific gap>. Please fix before we continue.",
	"wait":true
}}
```
""",
	cli: """
```bash
# 1. Start with the first refactoring item
rp-cli -w <window_id> -e 'agent_run op=start model_id=engineer session_name="Refactor: <goal>" message="Read the refactoring plan at <plan path> with read_file first. Implement item 1: <brief>. Preserve existing behavior."'

# 2. Verify, then steer the next item
rp-cli -w <window_id> -e 'read "<key file from item 1>"'
rp-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="Item 1 looks good. Item 2: <brief>" wait=true'

# 3. If something's off, steer a correction
rp-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="Item 1 missed <gap>. Fix first." wait=true'
```
"""))

Verify each item against the plan's "done when" criteria before steering the next. A quick `read_file` or `file_search` on key files costs little and catches drift early.

**Use `engineer` role** for refactoring items — the plan already makes the path clear, so the agent just needs precise execution. Use `pair` only if an item involves architectural decisions not covered by the plan.

Since refactor relies on extended steering, it's worth checking whether the `engineer` role is powered by a Codex-family model (which handles long steering sessions best).

\(sharedRolesOnlyCheck(variant: variant))

### Writing the dispatch brief

\(sharedDispatchBriefGuidance(variant: variant))

### When to use parallel dispatch

Refactorings that touch **completely independent modules** can run concurrently.

\(sharedParallelDispatchBlock(variant: variant, defaultRole: "engineer"))

Only parallelize when items have **zero file overlap**. When in doubt, run sequentially — refactoring conflicts are painful to untangle.

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance))
## Step 4: Monitor & Verify

\(sharedMonitorAndVerifyBlock(variant: variant))

\(sharedFinalRollupBlock(variant: variant, taskNoun: "item"))

---

## Anti-patterns to Avoid

- 🚫 This workflow requires \(builderName) for both analysis (Step 1) and planning (Step 2) — don't skip either.\(isAgent ? "" : "\n- 🚫 Skipping Step 0 (Workspace Verification) – you must confirm the target codebase is loaded first")
- 🚫 Skipping Step 1's \(builderName) call with `response_type: "review"` and attempting to analyze manually
- 🚫 Skipping Step 2's \(builderName) call with `response_type: "plan"` — you need a concrete plan before dispatching agents
- 🚫 Extended reading before the first \(builderName) call – a quick skim is fine; let the builder do the heavy lifting
- 🚫 Implementing refactorings yourself — you are the coordinator; dispatch agents to do the work
- 🚫 Dispatching all items at once without verifying each one — refactorings compound; verify before proceeding
- 🚫 Parallelizing items that share files — sequential is safer for dependent refactorings
- 🚫 Forgetting to check on dispatched agents — they may block on permission approvals; poll periodically to keep them unblocked
- 🚫 Assuming you understand the code structure without \(builderName)'s architectural analysis\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` – CLI invocations are stateless and require explicit window targeting" : "")
"""
	}

	// MARK: - Orchestrate Workflow

	/// The rp-orchestrate command — plans, decomposes, and dispatches work across agents.
	static let rpOrchestrate = rpOrchestrate(variant: .mcp)

	/// Generate rp-orchestrate for a specific variant.
	static func rpOrchestrate(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix: String
		let title: String
		switch variant {
		case .cli: suffix = " (CLI)"; title = "CLI Orchestrator"
		case .agent: suffix = ""; title = "Orchestrator"
		case .mcp: suffix = ""; title = "MCP Orchestrator"
		}
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-orchestrate", description: "Plan, decompose, and delegate complex tasks across multiple agents using \(toolDesc)", variant: variant))

# \(title)\(suffix)

Raw request: $ARGUMENTS

\(variant.preamble)\(rpOrchestrateCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// Core orchestration workflow content.
	static func rpOrchestrateCore(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let isAgent = variant == .agent
		let cleanupQuickReferenceRow = includeSessionCleanupGuidance
			? "| Dismiss a completed session | `agent_manage op=cleanup_sessions session_ids=[\"...\"]` |\n"
			: ""

		return """
You are an orchestrator: **plan**, **decompose**, **delegate**. Implementation and deep context-gathering happen in sub-agents. Keep your own context lean for coordination.
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "planning", nextStep: "Phase 1"))
## Phase 1: Contextualize the Task

Translate the user's prompt into the codebase's actual nouns — concrete modules, filenames, patterns — so builder can focus immediately instead of disambiguating. 1-2 navigation calls (tree or search) is usually enough.

Example:
- Raw: *"Add retry logic to the API layer"*
- Contextualized: *"Add retry logic to `NetworkService` (HTTP wrapper) — see `APIClient` for the existing auth retry pattern."*

Shortcuts:
- **User named the file/module** → use their reference, skip the scan.
- **User provided a plan file** → read it, skip straight to Phase 2.
- **Still ambiguous after 2 calls** → dispatch a narrow explore agent with one specific question.

Keep this light — builder handles the deep reading.

\(example(variant,
	mcp: """
```json
{"tool":"get_file_tree","args":{"type":"files","mode":"auto"}}
{"tool":"file_search","args":{"pattern":"<key term>","mode":"path"}}
```

Then:
```json
{"tool":"context_builder","args":{
	"instructions":"<contextualized task>",
	"response_type":"plan",
	"export_response":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'tree'
rp-cli -w <window_id> -e 'search "<key term>"'
rp-cli -w <window_id> -e 'builder "<contextualized task>" --response-type plan --export'
```
"""))

If you can't disambiguate from a quick scan, dispatch a narrow explore agent first:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Explore: <area>",
	"message":"Check <specific thing> — report back briefly."
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Explore: <area>" message="Check <specific thing>"'
```
"""))

Explore agents are cheap — spawn multiple in parallel for different areas, but keep each prompt narrow. They tend to overthink broad instructions.

---

## Sharing the plan with sub-agents

Once you have a plan — whether generated via builder or provided by the user — you'll want sub-agents to see it. Use `export_response:true` to write any generated plan to a shareable file. This works on:
- **`context_builder`** (with `response_type: "plan"`, `"question"`, or `"review"`) — exports the generated response
- **\(isAgent ? "`ask_oracle`" : "`oracle_send`")** — exports any oracle response, including follow-ups to a context_builder chat

For user-provided plan files, you already have a path — just reference it in dispatch briefs.

The tool returns `oracle_export_path` and `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next `agent_run` `start` call. The `oracle_export_instruction` field is a ready-made sentence ("Read the Oracle export at `<path>` with `read_file` …") you can emit verbatim at the head of that `message`. The child agent opens the file with `read_file`. Do **not** ask child agents to continue your Oracle chat — they are in different tabs.

**The export is a shared document.** Sub-agents treat it as **read-only** context. As the orchestrator, you own this file — use it as a living checklist by updating it (via `apply_edits`) to mark items complete, note deferred work, or track progress across phases.

\(example(variant,
	mcp: """
```json
// Generate and export the plan in one call
{"tool":"context_builder","args":{
	"instructions":"<task description>",
	"response_type":"plan",
	"export_response":true
}}

// Or export an oracle follow-up
{"tool":"\(isAgent ? "ask_oracle" : "oracle_send")","args":{
	"message":"Plan: <focused planning question>",
	"mode":"plan",
	"export_response":true
}}

// Then reference the export path in the child agent message
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Orchestrate: <goal>",
	"message":"Read the plan at <plan path> with read_file first. Implement <work item>."
}}
```
""",
	cli: """
```bash
# Generate and export the plan, then reference the returned path in agent_run message.
rp-cli -w <window_id> -e 'builder "<task description>" --response-type plan --export'
rp-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Orchestrate: <goal>" message="Read the plan at <plan path> with read_file first. Implement <work item>."'
```
"""))

---

## Phase 2: Decompose into Work Items

Take the plan (from \(builderName) or a user-provided plan file) and break it into **up to 5 discrete work items**.

\(sharedDecompositionGuidance(variant: variant, taskNoun: "item"))

---

## Phase 3: Dispatch

### Default: fresh agent per item

For multi-item work, dispatch a **fresh agent per item**. The plan file provides continuity — each agent reads it first, sees what's already done, and reasons with a clean context budget.

The pattern is a **verify-then-dispatch-fresh loop**:

1. **Dispatch** the first work item with a self-contained brief + plan reference.
2. **Wait** for the agent to finish.
3. **Verify** against the plan — did it meet the "done when" criteria from Phase 2? A quick scan of the agent's output and, if needed, a lightweight `file_search` or `read_file` on key deliverables catches drift before it compounds.
4. **Update the plan file** to record progress so the next agent sees current state.
5. **Dispatch the next item fresh**, referencing the updated plan.

Do **not** fire-and-forget the full list. Catching drift early — before the next agent builds on a flawed foundation — is your value as the orchestrator.

\(example(variant,
	mcp: """
```json
// 1. Dispatch item 1 as a fresh agent
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Orchestrate 1/N: <item 1 goal>",
	"message":"Read the plan at <plan path> with read_file first. Your job is item 1: <brief>. Later items are handled separately."
}}

// 2. Agent completes — verify against the plan.
//    Optionally spot-check a key file:
{"tool":"read_file","args":{"path":"<key file from item 1>"}}

// 3. Update the plan file to record progress:
{"tool":"apply_edits","args":{
	"path":"<plan path>",
	"search":"- [ ] Item 1:",
	"replace":"- [x] Item 1:"
}}

// 4. Dispatch item 2 as a new fresh agent:
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Orchestrate 2/N: <item 2 goal>",
	"message":"Read the plan at <plan path> with read_file first. Item 1 is complete. Your job is item 2: <brief>."
}}
```
""",
	cli: """
```bash
# 1. Dispatch item 1 as a fresh agent
rp-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Orchestrate 1/N: <goal>" message="Read the plan at <plan path> with read_file first. Your job is item 1: <brief>."'

# 2. Verify output, spot-check key files
rp-cli -w <window_id> -e 'read "<key file from item 1>"'

# 3. Update plan file to record progress
rp-cli -w <window_id> -e 'call apply_edits {"path":"<plan path>","search":"- [ ] Item 1:","replace":"- [x] Item 1:"}'

# 4. Dispatch item 2 as a new fresh agent
rp-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Orchestrate 2/N: <goal>" message="Read the plan at <plan path> with read_file first. Item 1 is complete. Your job is item 2: <brief>."'
```
"""))

### When steering one agent through multiple items works better

Sometimes it's better to keep a single agent alive and steer it through work. Consider steering when:

- **Tightly coupled items** — item 2 builds directly on a decision the agent made in item 1's working memory.
- **Codex-family sub-agents** — Codex sessions compact reliably, making extended steering a natural fit.
- **Many tiny items** — spawn overhead outweighs context cost.

\(sharedRolesOnlyCheck(variant: variant))

When steering, the loop is the same but step 5 becomes `agent_run op=steer` on the existing `session_id` instead of a fresh dispatch:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"Item 1 looks good. Moving on to item 2: <brief>. Refer back to the plan at <plan path> if needed.",
	"wait":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="Item 1 looks good. Moving on to item 2: <brief>" wait=true'
```
"""))

### Choosing the right agent role

- **`pair`** — The default for complex work. Architectural decisions, multi-file changes, deep reasoning.
- **`engineer`** — Well-scoped items where the goal and approach are already clear from the plan.
- **`design`** — UI, layout, visual polish, copy/text editing, anything user-facing.
- **`explore`** — Short reconnaissance only (already used in Phase 1 escalation path).

Stick to these role labels. The specific model behind a role isn't your concern unless the user names one.

When in doubt, use `pair`. The tasks reaching this workflow are complex by nature. Use `engineer` when the plan already makes the path obvious and the item just needs execution.

When questions arise during coordination, reason through them yourself. If you're uncertain, negotiate with the agent already working on the relevant task — it has the deepest context. Steer it with your thinking and work toward consensus rather than dictating a direction.

### Writing the dispatch brief

\(sharedDispatchBriefGuidance(variant: variant))

### Parallel dispatch

\(sharedParallelDispatchBlock(variant: variant, defaultRole: "pair"))

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance, includeStrayPlanExportCleanup: true))
---

## Phase 4: Monitor and Verify

\(sharedMonitorAndVerifyBlock(variant: variant))

\(sharedFinalRollupBlock(variant: variant, taskNoun: "item"))

### Quick reference: orchestrator operations

| Operation | Tool call |
|-----------|-----------|
| Start a fresh agent | `agent_run op=start model_id=<role> session_name="..." message="..." detach=true/false` |
| Steer an existing agent | `agent_run op=steer session_id="..." message="..." wait=true` |
| Wait for an agent | `agent_run op=wait session_id="..."` |
| Wait for first of multiple agents | `agent_run op=wait session_ids=["...", "..."] timeout=60` |
| Poll without blocking | `agent_run op=poll session_id="..."` |
| Poll multiple agents | `agent_run op=poll session_ids=["...", "..."]` |
\(cleanupQuickReferenceRow)| Read plan/context | `read_file`, `get_file_tree`, `file_search` |
| Reason with oracle | `\(isAgent ? "ask_oracle" : "oracle_send")` — requires file selection from \(builderName) |

---

## Key Principles

- **You are the coordinator, not the implementer.** Read to verify sub-agent work, not to build your own mental model. Keep your context focused on coordination.
- **Trust the agents.** They're smart, they have tools, they read project instructions. Give them goals and reference points, not turn-by-turn directions.
- **Be strategic about parallelism.** Independent items can run concurrently, but always warn agents about siblings working in adjacent areas.
- **Graceful scaling.** 1 item = just dispatch it. 2-3 items = straightforward. 4-5 items = be deliberate about dependencies and parallelism.
- **Escalation point.** You're the one with the full picture. Sub-agents should surface coordination problems to you rather than solving them unilaterally.

## Anti-patterns

- 🚫 Implementing code yourself — you're the orchestrator, dispatch an agent\(isAgent ? "" : "\n- 🚫 Skipping Phase 0 (Workspace Verification) — you must confirm the target codebase is loaded first")
- 🚫 Extended code reading before delegating — a quick skim is fine; deep reads belong in builder or explore agents
- 🚫 Writing detailed step-by-step instructions for dispatched agents — they can reason for themselves
- 🚫 Dispatching parallel agents to overlapping files without warning them about each other
- 🚫 Waiting idle for an agent when you could be dispatching the next independent item or preparing the next brief
- 🚫 Forgetting to check on dispatched agents — they may block on permission approvals; poll periodically to keep them unblocked
- 🚫 Creating 5 work items when the task is naturally 2 — decompose to the right granularity, not a target number
- 🚫 Repeating project conventions from CLAUDE.md in dispatch briefs — the agents will read those themselves
- 🚫 Forwarding user-to-orchestrator commentary (preferences, criticisms, meta-instructions about how you should operate) into a peer-agent brief — translate the actionable parts into the technical task and keep the rest between you and the user
"""
	}

	// MARK: - Optimize Workflow

	/// The rp-optimize command — iterative performance optimization loop:
	/// define target, instrument with debug-only metrics, establish baseline, then loop
	/// plan → dispatch pair → re-measure → ask oracle for next plan until satisfied.
	static let rpOptimize = rpOptimize(variant: .mcp)

	/// Generate rp-optimize for a specific variant.
	static func rpOptimize(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix: String
		let title: String
		switch variant {
		case .cli: suffix = " (CLI)"; title = "CLI Optimizer"
		case .agent: suffix = ""; title = "Optimizer"
		case .mcp: suffix = ""; title = "MCP Optimizer"
		}
		let toolDesc = variant == .cli ? "rp-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-optimize", description: "Iterative performance optimization loop using \(toolDesc): instrument with debug-only metrics, establish a baseline, then plan → delegate one optimize+harden cycle → re-measure → ask oracle for next plan, looping until the oracle is satisfied or the target metric is met", variant: variant))

# \(title)\(suffix)

Raw request: $ARGUMENTS

\(variant.preamble)\(rpOptimizeCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// Core optimize workflow content.
	static func rpOptimizeCore(variant: ToolVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatTool = variant == .agent ? "`ask_oracle`" : (variant == .cli ? "`chat`" : "`oracle_send`")
		let chatToolName = variant == .agent ? "ask_oracle" : (variant == .cli ? "chat" : "oracle_send")
		let ChatLabel = variant == .agent ? "Oracle" : (variant == .cli ? "Chat" : "Oracle")
		let isAgent = variant == .agent

		return """
You are an **optimization orchestrator**. Performance work only improves what you can measure, so the loop is always: **map → plan → instrument & baseline → optimize loop → decide**. Keep looping until the oracle signals the gains have plateaued, the target metric is met, or the iteration cap is reached.

This workflow is delegation-heavy by design. Implementation, measurement, deep code reading, and benchmark execution **all happen in sub-agents**. You own coordination, planning, and the stop decision. Your direct tool calls are reserved for: triaging the user's prompt, reading the scoreboard, spot-checking sub-agent claims, and curating the file selection that the oracle and \(builderName) reason over.

### How delegation flows

- **You (the agent)**: Orchestrate. Translate the prompt, fan out explore agents to map surface area, run \(builderName) to plan setup, dispatch a pair to land instrumentation + baseline, then loop pair dispatches for each optimization. Your context stays lean.
- **Explore agents** (`agent_run` with `model_id:"explore"`): Read-only sub-agents that map the surface — find AGENTS.md, locate hot paths, discover existing benchmarks, define scope boundaries. Cheap and parallel; spawn liberally during Phase 1.
- **\(builderName)**: Used in **plan mode** during Phase 2 to design the metric, instrumentation strategy, and first-pass optimization candidates in one shot. Reused in the loop to plan each individual optimization.
- **Pair agents** (`agent_run` with `model_id:"pair"`): Carry out implementation, measurement, and hardening. Phase 3's pair lands instrumentation and the baseline. Each loop iteration's pair lands one attributed change, runs tests, re-measures, and appends to the scoreboard.
- **\(ChatLabel)** (\(chatTool)): Reasons over the scoreboard and changed files at decision points — "did this iteration earn its keep?" and "should we keep going?". Selection-aware; you curate before each call.

### Core principles

- **Don't read what an agent can read for you.** Reserve direct `read_file` / `file_search` / `git` for verifying agent claims and reading the scoreboard. Mapping the codebase, running benchmarks, reading AGENTS.md — those go to sub-agents.
- **One attributed change per loop iteration.** Causality is cheap to preserve and expensive to recover.
- **The scoreboard is the shared truth.** Every iteration appends; nothing gets overwritten. Sub-agents and the oracle both read from it.
- **The oracle is the stop signal.** You don't decide when to stop on gut feel — you ask, with the scoreboard in selection, and respect the answer.
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "optimization work", nextStep: "Phase 1"))
## Phase 1: Surface Mapping & Bottleneck Scouting (delegate to explore agents)

Your job here is **prompt translation + orchestrated scouting**, not codebase exploration. Spend at most 1–2 navigation calls turning the user's request into the codebase's actual nouns, then **fan out explore agents in parallel** to scout for bottleneck candidates around the named target.

The user names what to optimize, but the actual bottleneck is rarely just inside that function. It can sit in the **callers** (called 10k times in a tight loop, where the loop itself is the cost), in the **inputs** (caller wastefully constructs the data the target consumes), in **adjacent operations** that run together in the same code path, or in **shared infrastructure** the target touches (locks, caches, allocators). Scouting radiates outward from the named target so Phase 2's plan is grounded in evidence about where time is actually going.

### 1a. Translate the prompt

Rewrite the user's request in the repo's likely terminology — don't dive deeper yet.

Example:
- Raw: *"Speed up search"*
- Translated: *"Reduce p95 latency of path-matching under the test fixtures — likely `PathMatcher` and friends. Need to confirm exact module and existing benchmarks."*

**Default: run the full fan-out.** Even when the user names the function, the cost is rarely all inside that function — callers, inputs, and adjacent operations often dominate. Bottleneck scouting is what surfaces that.

Two narrow exceptions:
- **Profile data already exists** (user attached a sample report or pointed at a recent profiler trace in the repo) → dispatch one focused explore to read the trace + summarize bottleneck candidates, then go to Phase 2. Skip the rest of the fan-out.
- **User gave a feature/feeling** ("feels slow during X") → full fan-out, plus add `<X>`-entry-point discovery to the "Target & call graph" brief.

### 1b. Dispatch explore agents in parallel

Spawn explore agents — each with one narrow question — for the facts you need before \(builderName) can plan. **The bottleneck-candidates explore is the heart of this phase.** Typical fan-out:

| Explore | Question |
|---------|----------|
| **Bottleneck candidates** | "Scout for performance bottlenecks around `<translated target>`. Look at the target itself AND its surrounding context: callers (especially loops or hot code paths that invoke the target frequently), data dependencies (how inputs to the target are constructed upstream), adjacent operations that run together in the same code path, shared infrastructure the target touches (locks, caches, allocators). Hunt for: tight loops with per-iteration allocations, redundant computation across iterations, locking/serialization, expensive data transformations (JSON/XML/string), sync I/O on hot paths, O(n²) patterns, repeated work that could be cached, unbatched UI/IO updates. Report 2–3 ranked candidates with `file:line` refs and a one-sentence rationale per candidate ('suspicious because…'). Don't propose fixes yet — just identify what looks expensive." |
| Target & call graph | "Locate the implementation of `<translated target>`. Then map its call graph: who calls it, how often, and in what context (tight loop? cold init? user-driven? background job?). Report the implementation `file:line` and the 3–5 most relevant call sites with the surrounding code context that explains how the target is invoked." |
| Prior perf work | "Find prior performance work related to `<area>`. Look for: (a) existing benchmarks, perf tests, or instrumentation in code (search `*Tests`, `*Bench*`, `*Perf*`, `benchmarks/`, `bench/`); (b) profiler traces, sample reports, or perf logs in the repo (look under `error-triage/`, `reports/`, `docs/investigations/`, `perf/`, or similar); (c) TODOs/FIXMEs/comments mentioning 'slow', 'perf', 'O(n', 'hot path', 'bottleneck' in or near `<area>`. Report what exists, where it lives, and (for benchmarks/instrumentation) how to invoke it." |
| Conventions | "Read AGENTS.md (or the project's testing/benchmarking doc). Report: how to run unit tests, how to run benchmarks if any, how to launch a debug harness, and any sanctioned measurement commands. Quote the exact commands." |
| Scope | "Identify the file/module boundary that defines `<area>` — which files are in scope for changes, which are clearly out of scope. List both." |

Use `detach:true` so they run concurrently:

\(example(variant,
	mcp: """
```json
// The Bottleneck candidates explore — full prose, since this is the heart of Phase 1
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Bottleneck candidates: <area>",
	"message":"Scout for performance bottlenecks around <translated target>. Look at the target AND its surrounding context: callers (especially loops or hot paths invoking it frequently), data dependencies (how inputs are constructed upstream), adjacent operations in the same code path, shared infrastructure the target touches. Hunt for: tight loops with per-iteration allocations, redundant computation, locking/serialization, expensive transformations, sync I/O on hot paths, O(n²) patterns, unbatched updates. Report 2–3 ranked candidates with file:line refs and a one-sentence rationale per candidate. Don't propose fixes yet.",
	"detach":true
}}

// One more representative one — same shape, different question
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Conventions: AGENTS.md",
	"message":"Read AGENTS.md (or the project's equivalent). Report how to run unit tests, benchmarks, debug harness, sanctioned measurement commands. Quote exact commands.",
	"detach":true
}}

// Repeat the same shape for the remaining 3 explores in the table above
// (Target & call graph, Prior perf work, Scope), each with detach:true.

// Then wait on all of them at once
{"tool":"agent_run","args":{"op":"wait","session_ids":["<id1>","<id2>","<id3>","<id4>","<id5>"],"timeout":180}}
```
""",
	cli: """
```bash
# The Bottleneck candidates explore — full prose, since this is the heart of Phase 1
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Bottleneck candidates: <area>" message="Scout for performance bottlenecks around <translated target>. Look at the target AND surrounding context: callers, data dependencies, adjacent operations, shared infrastructure. Hunt for tight loops with per-iteration allocations, redundant computation, locking, expensive transformations, sync I/O on hot paths, O(n²), unbatched updates. Report 2–3 ranked candidates with file:line and one-sentence rationale per candidate. No fixes yet." detach=true'
rp-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Conventions: AGENTS.md" message="Read AGENTS.md. Report how to run unit tests, benchmarks, debug harness, sanctioned measurement commands. Quote exact commands." detach=true'
# Repeat the same shape for the remaining 3 explores in the table above (Target & call graph, Prior perf work, Scope), each with detach=true.
rp-cli -w <window_id> -e 'agent_run op=wait session_ids=["<id1>","<id2>","<id3>","<id4>","<id5>"] timeout=180'
```
"""))

> ⚠️ **Detached agents may block on permission approvals.** Poll periodically or use `op=wait` so you can approve and keep them unblocked.

If the bottleneck-candidates explore returns thin or generic results ("nothing obviously expensive"), that's a signal — either the area is genuinely well-tuned and the user's complaint is elsewhere, or the explore needed broader radius. Either way, **re-dispatch one targeted explore** with a wider radius (e.g., "look two call levels up") rather than reading the code yourself.

### 1c. Synthesize the target

When the explores return, write down (in your head or as scratch — no need for a file yet):

1. **Metric**: a single, nameable number (latency, peak memory, allocations, frame time, etc.) plus its unit.
2. **Stop criterion**: hard threshold ("p95 < 50 ms"), relative target ("30% faster"), or "until oracle says diminishing returns".
3. **Scope**: the file/module boundary, citing what's in and what's out (from the Scope explore).
4. **Measurement command**: the exact command(s) the explores reported (from Conventions + Prior perf work).
5. **Ranked bottleneck candidates**: 2–3 candidates with `file:line` and rationale, augmented by call-site context from the call-graph explore.

If the bottleneck candidates and the user's named target diverge significantly — e.g., user said "speed up `PathMatcher.match`" but the explore reports the real cost is in the **caller's per-iteration allocation** of `MatchOptions` — **pause** before dispatching Phase 2 and ask the user explicitly: *"Scouting suggests the bigger lever is X (file:line). Pursue X, stay on the original target, or both?"* Wait for their answer; don't reframe the scope unilaterally.

You'll feed all five to \(builderName) in Phase 2.

---

## Phase 2: Plan Setup with \(builderName) (plan mode)

Now that the surface is mapped and bottleneck candidates are in hand, route the setup design through \(builderName) in **plan mode**. One call produces:

- **Instrumentation strategy** — where the metric will be measured, what build gate to use, which secondary test/support file holds the collection logic. Where the instrumentation lives is informed by the bottleneck candidates from Phase 1 — measure where the cost actually is.
- **Baseline procedure** — how many samples, how to discard outliers, what variance band to expect.
- **First-pass optimization candidates** — 2–3 concrete optimizations ranked by expected delta vs. risk, **grounded in the bottleneck candidates from Phase 1** (each of those is now a candidate to address; \(builderName) translates them into actionable changes with risk assessment).
- **Scoreboard scaffold** — the markdown shape for `prompt-exports/optimize-<slug>-runs.md`.

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
	"instructions":"<task>Design the setup for an iterative optimization loop targeting <metric> on <scope>.\\n\\nReturn an actionable plan with:\\n1. Instrumentation strategy: which file to add/extend (must be a test/support file, not production code), the debug-build gate to use (e.g. #if DEBUG / cfg(debug_assertions) / NODE_ENV / etc. — pick what matches this repo's convention), and the smallest hook the production code needs to expose.\\n2. Baseline procedure: how many samples, how to discard outliers, expected variance band, and the exact command to run (per AGENTS.md).\\n3. First-pass optimization candidates: 2–3 concrete optimizations ranked by (expected delta / risk). For each: the change, why it should help the metric, and what could regress.\\n4. Scoreboard scaffold: the initial contents for prompt-exports/optimize-<slug>-runs.md.</task>\\n\\n<context>\\nUser request: <raw request>\\nMetric + units: <name + units>\\nStop criterion: <threshold or 'oracle-satisfied'>\\nScope: <files/modules in play>\\nMeasurement command (from Conventions explore): <exact command>\\nTarget & call graph (from Target explore): <implementation file:line + 3–5 callers with context>\\nBottleneck candidates (from Bottleneck explore — the heart of Phase 1): <ranked list with file:line and one-sentence rationale per candidate>\\nPrior perf work (from Prior perf work explore): <existing benchmarks, profiler traces, perf TODOs and what they say>\\nProject conventions doc: AGENTS.md (already summarized by explore — the agent doesn't need to re-read it)\\n\\nWhen ranking first-pass optimization candidates, treat the Bottleneck candidates list as the seed. Each item there is a hypothesis about where time is going; the plan should propose how to address each, with risk and verification.\\n</context>",
	"response_type":"plan",
	"export_response":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'builder "<task>Design the setup for an iterative optimization loop targeting <metric> on <scope>.

Return an actionable plan with:
1. Instrumentation strategy: which file to add/extend (must be a test/support file, not production code), the debug-build gate matching this repo, and the smallest hook the production code needs to expose.
2. Baseline procedure: sample count, outlier rules, expected variance, exact command (per AGENTS.md).
3. First-pass optimization candidates: 2–3 concrete optimizations ranked by (expected delta / risk).
4. Scoreboard scaffold: initial contents for prompt-exports/optimize-<slug>-runs.md.</task>

<context>
User request: <raw request>
Metric + units: <name + units>
Stop criterion: <threshold>
Scope: <files/modules>
Measurement command: <exact command>
Target & call graph: <implementation file:line + 3–5 callers with context>
Bottleneck candidates (heart of Phase 1): <ranked list with file:line + rationale>
Prior perf work: <existing benchmarks, profiler traces, perf TODOs>

Treat the Bottleneck candidates list as the seed for first-pass optimization candidates — each is a hypothesis about where time is going.
</context>" --response-type plan --export'
```
"""))

The tool returns `oracle_export_path` and `oracle_export_instruction`. **Save the export path** — Phase 3 and every loop iteration reference it.

If the plan looks thin (no concrete instrumentation site, vague candidates), refine the instructions and re-run rather than trying to fill gaps yourself.

---

## Phase 3: Land Instrumentation + Baseline (delegate to pair)

You don't run measurements. Dispatch a single `pair` agent to execute the setup plan:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Optimize setup: instrumentation + baseline",
	"message":"Read the setup plan at <plan path> with read_file first. Execute the setup phase only — do not pursue any optimization yet:\\n\\n1. Land the instrumentation per the plan: keep it in a secondary test/support file, gate it behind the repo's debug build flag, and expose only the minimum hook in production code.\\n2. Verify a release build with instrumentation stripped still compiles cleanly.\\n3. Capture the baseline: run the measurement command 3–5 times. Discard obvious outliers. Record the median and p95 (or whichever is appropriate for this metric). Note the variance band — if optimizations smaller than that band would be invisible, say so explicitly.\\n4. Create prompt-exports/optimize-<slug>-runs.md from the scoreboard scaffold in the plan, fill in the baseline row with median, p95, environment notes, and current commit.\\n5. Report back: instrumentation files touched, the exact command used, baseline numbers, variance, and any concerns about measurement reliability.\\n\\nDo not attempt any optimization yet — that's the next iteration. Skip oracle review; the orchestrator handles that."
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Optimize setup" message="Read the setup plan at <plan path> with read_file first. Execute the setup phase only: land instrumentation in a test/support file gated behind the debug build flag; verify release builds strip it; capture 3–5 baseline samples per AGENTS.md; create prompt-exports/optimize-<slug>-runs.md and fill the baseline row (median, p95, variance, env, commit). Report files touched, command used, baseline numbers, variance, and any reliability concerns. Do not optimize anything yet."'
```
"""))

When the pair returns:

- **Read the scoreboard.** That's your verification surface — not the diff. If the baseline row looks reasonable, move on.
- **Sanity-check variance.** If the variance band is large enough to swallow a 10–20% optimization, that's a problem. Steer the pair to take more samples or narrow the workload before continuing.
- **Don't read the instrumentation diff yet.** If concerns surface in later phases, dispatch a narrow explore to summarize the diff for you.

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance, includeStrayPlanExportCleanup: false))
---

## Phase 4: The Optimization Loop

One iteration = one attributed change + one re-measurement. Running multiple optimizations in parallel destroys causality — keep the loop **serial** by default.

Loop until one of the **termination criteria** in 4d fires.

### 4a. Plan the next optimization

The Phase 2 plan listed first-pass candidates. For iteration 1, pick the top-ranked one and skip straight to 4b. From iteration 2 onward, use \(builderName) to plan the next single change with the scoreboard in selection. The Phase 2 plan's candidates are still the seed; \(builderName) refines whichever you select next. Reach for the oracle in this slot only when you already have a fully-formed candidate and just need a sanity check before dispatch.

\(example(variant,
	mcp: """
```json
{"tool":"manage_selection","args":{
	"op":"set",
	"paths":["<target source files>","<benchmark or test>","prompt-exports/optimize-<slug>-runs.md","<setup plan path>"],
	"mode":"full"
}}
{"tool":"context_builder","args":{
	"instructions":"<task>Propose the single next optimization to pursue for <metric>. One change, not a list. Include: the specific change, why you expect it to move the metric, any risks to behavior or correctness, how to verify it didn't regress other tests.</task>\\n\\n<context>Current baseline and prior runs are in prompt-exports/optimize-<slug>-runs.md. The setup plan at <setup plan path> already listed first-pass candidates — prefer one of those if it still looks promising and hasn't been tried. Target: <threshold or directional goal>. Scope: <modules>.</context>",
	"response_type":"plan",
	"export_response":true
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'select set <target source files> <benchmark or test> prompt-exports/optimize-<slug>-runs.md <setup plan path>'
rp-cli -w <window_id> -e 'builder "<task>Propose the single next optimization to pursue for <metric>. One change, not a list. Include the change, why it moves the metric, risks, and how to verify no regressions.</task>

<context>Baseline and prior runs in prompt-exports/optimize-<slug>-runs.md. Setup plan with first-pass candidates at <setup plan path>. Target: <threshold>. Scope: <modules>.</context>" --response-type plan --export'
```
"""))

If the plan proposes more than one change, pick the one with the **best expected delta per unit of risk**.

### 4b. Dispatch one full optimize-and-harden loop

Dispatch **one `pair` agent** for the selected change. The brief covers landing the optimization **and** hardening it in one shot — implementation, tests, re-measurement, scoreboard append:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Optimize <N>: <change summary>",
	"message":"Read the plan at <plan path> with read_file first. Run one full optimize-and-harden loop:\\n\\n1. Implement the change in <files>.\\n2. Run the project's standard test command (see AGENTS.md) for the touched modules — fix anything that breaks.\\n3. Re-run the same measurement command used for the baseline (in prompt-exports/optimize-<slug>-runs.md). Take the same number of samples as the baseline so deltas are comparable. Append a new row — don't overwrite.\\n4. If the change regressed the metric or broke correctness, either revert it or iterate once to fix, then report back.\\n5. Summarize: what you changed, what the metric moved to, tests touched, concerns worth flagging.\\n\\nStay inside <scope>. Don't pursue tangential optimizations — one attributed change per loop. Skip oracle review; the orchestrator handles that."
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Optimize <N>: <change summary>" message="Read the plan at <plan path> with read_file first. Implement the change in <files>; run the project test command per AGENTS.md and fix breaks; re-run the baseline measurement command with matching sample count and append a new row to prompt-exports/optimize-<slug>-runs.md; if regressed, revert or iterate once to fix; then report changes, new metric value, updated tests, and concerns. Stay inside <scope>. Skip oracle review."'
```
"""))

Always use `pair`. Optimizations involve trade-offs (correctness, locality, complexity) that benefit from the more capable agent, and re-measurement requires interpreting noisy results. Use `engineer` only if you have a specific reason — and the user has agreed it's safe to drop trade-off review.

### 4c. Verify (without re-reading the codebase)

Verify the agent's output against the plan's done-when criteria — for optimize, that's the scoreboard, not the diff. Optimization-specific checks, all designed for **minimal direct reads**:

- **Read the scoreboard, not the diff.** A new row should be there with sample-matched numbers. If the agent forgot to append, steer it to fix.
- **Is the delta real?** Compare to the variance band you recorded in Phase 3. Single-digit shifts inside the noise band are inconclusive — note that in the scoreboard before consulting the oracle.
- **Tests actually ran?** "Ran the tests" in a summary isn't the same as tests passing. If you're suspicious, ask the agent for the exact command and exit code, or dispatch a narrow explore to re-run them.
- **Behavior spot-check, when needed.** If the change touches a correctness-sensitive surface, dispatch a narrow explore agent to read the diffed files and report whether semantics shifted (early returns, cache invalidation, ordering). Don't pull the diff into your own context unless the explore flags something concrete.

If the change regressed the metric or broke correctness that the sub-agent didn't catch, **steer** the same agent to fix it before opening a new loop. Rolling back counts as progress — record the attempt in the scoreboard so the next plan knows that path was tried.

### 4d. Ask the oracle for the next plan (and the stop decision)

After a successful iteration, refresh the selection and ask the oracle both questions in one call:

\(example(variant,
	mcp: """
```json
{"tool":"manage_selection","args":{
	"op":"set",
	"paths":["<files changed this iteration>","<benchmark or test>","prompt-exports/optimize-<slug>-runs.md"],
	"mode":"full"
}}
{"tool":"\(chatToolName)","args":{
	"message":"Plan: We just landed <change summary>. Metric moved from <baseline> to <new>. Scoreboard is in the selection. Given the stop criterion (<criterion>), should we run another iteration? If yes, what's the single best next optimization to pursue. If no, explain why you think we've hit diminishing returns or the target.",
	"mode":"plan"
}}
```
""",
	cli: """
```bash
rp-cli -w <window_id> -e 'select set <files changed this iteration> <benchmark or test> prompt-exports/optimize-<slug>-runs.md'
rp-cli -w <window_id> -e 'chat "Plan: We just landed <change summary>. Metric moved from <baseline> to <new>. Scoreboard is in the selection. Given the stop criterion (<criterion>), should we run another iteration? If yes, what is the single best next optimization. If no, explain why we have hit diminishing returns or the target." --mode plan'
```
"""))

The oracle's answer determines the loop's next step:

- **"Keep going, try X next"** → return to 4a with X as the seed for the next plan. Reuse the same scoreboard and instrumentation; only re-instrument if the hot path moved.
- **"We're done" / "Diminishing returns" / target met** → exit the loop, go to Phase 5.
- **"Can't tell — measurement is too noisy" or "behavior may have regressed"** → **stop optimizing.** The next dispatch must be a pair to harden the instrumentation or fix the regression. Do not plan a new optimization on top of an unreliable measurement — every later result becomes uninterpretable.

### Termination criteria (stop conditions)

Exit the loop when **any** of these fire:

1. **Oracle says so.** "Good enough" or "diminishing returns".
2. **Target metric met.** The stop criterion from Phase 1 is satisfied in the latest measurement.
3. **Iteration cap.** 5 loops, hard. Before dispatching loop 6, surface the scoreboard to the user and ask explicitly to continue. Don't extend the cap on your own judgment.
4. **Oracle can't propose a plausible next move.** Two consecutive "I'm not sure what to try" responses means the search has stalled.
5. **Regression budget exhausted.** If correctness keeps breaking faster than performance improves, stop and escalate to the user.

### Parallelism note

The loop is serial by design — attribution collapses when you run multiple changes at once. The one legitimate use of parallelism is **evaluating alternatives** for the same slot: dispatch two pair agents to try two different candidate optimizations on branches or temporary copies, pick the winner, discard the loser. This is advanced and rarely worth the coordination cost; don't reach for it unless the oracle explicitly suggests it.

\(includeSessionCleanupGuidance ? """
### Housekeeping (loop)

Same session-cleanup hygiene as Phase 3. Also delete superseded plan exports each iteration so `prompt-exports/` reflects only live work:

\(sharedStrayPlanExportCleanupHint(variant: variant))

""" : "")
---

## Phase 5: Final Rollup

\(sharedFinalRollupBlock(variant: variant, taskNoun: "iteration"))

Specifically for optimize:

- **Starting metric → final metric**, with iteration count. A one-line summary: "`PathMatcher.match` p95: 124ms → 38ms over 4 iterations (-69%)."
- **Which changes landed**, in order, with their individual deltas.
- **Which changes were tried and reverted**, with the reason — useful so the next person doesn't repeat dead ends.
- **State of the instrumentation.** If the debug-only metrics are worth keeping, say so; otherwise suggest removal. The scoreboard file under `prompt-exports/` can stay as historical record or be deleted — default to keeping it and let the user decide.
- **Known follow-ups.** Anything the oracle flagged but wasn't pursued this session.

---

## Role Summary

You (the agent) own triage, prompt translation, scoreboard reads, sub-agent verification, and the stop decision. Everything else is delegated:

| Capability | Explore Agents | \(builderName) | Pair (setup) | Pair (each loop) | \(ChatLabel) (\(chatTool)) |
|---|---|---|---|---|---|
| Map surface (AGENTS.md, target & call graph, prior perf work, scope) | ✅ Primary | — | — | — | — |
| Scout bottleneck candidates around target | ✅ Primary | — | — | — | — |
| Plan setup (metric, instrumentation, candidates from scouting) | — | ✅ Primary | — | — | — |
| Land instrumentation + capture baseline | — | — | ✅ Primary | — | — |
| Plan one optimization | — | ✅ Primary | — | — | ⚠️ sanity-check only |
| Implement + test + re-measure + append scoreboard | — | — | — | ✅ Primary | — |
| Delegated spot-check / diff summary | ✅ on demand | — | — | — | — |
| Decide continue vs stop | — | — | — | — | ✅ Primary |

**Cheat sheet for the four operations you'll repeat:**
```
agent_run op=start  model_id=<explore|pair>  detach=true       # dispatch
agent_run op=wait   session_ids=["..."]      timeout=N         # block
agent_run op=steer  session_id="..."         wait=true         # correct
\(builderName)  response_type=plan  export_response=true              # plan
```

---

## Anti-patterns

- 🚫 Skipping the bottleneck-candidates explore because the user named a specific function — even with a named target, callers and inputs often dominate the cost
- 🚫 Skipping \(builderName) in Phase 2 and dispatching the setup pair from your own sketch — you'll lose the candidate queue and the instrumentation gating discipline
- 🚫 Letting \(builderName) re-derive optimization candidates from scratch instead of seeding it with the bottleneck candidates from Phase 1 — the explore already paid for that scouting; pass it forward
- 🚫 Starting to optimize before defining the metric and stop criterion — you won't know when you're done
- 🚫 Shipping measurement overhead to production — always gate metrics behind a debug/test build flag
- 🚫 Putting instrumentation in the same file as the code being measured — it belongs in a secondary test/support file\(isAgent ? "" : "\n- 🚫 Skipping Phase 0 (Workspace Verification) — you must confirm the target codebase is loaded first")
- 🚫 Taking a single sample as a baseline — one number isn't a measurement, it's a guess
- 🚫 Running multiple optimizations in one loop iteration — you'll never know which change produced which delta
- 🚫 Forgetting to re-run tests after the optimization — speed without correctness isn't a win
- 🚫 Skipping the oracle check and looping on your own judgment — the oracle sees the whole scoreboard; use it
- 🚫 Overwriting scoreboard rows instead of appending — historical data is how you spot regressions and dead ends\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` — CLI invocations are stateless and require explicit window targeting" : "")

---

Now begin with Phase 0.\(variant == .cli ? " First run `rp-cli -e 'windows'` to find the correct window." : "")
"""
	}

	// MARK: - CLI Variants (convenience accessors)

	/// CLI variant of rp-investigate - uses rp-cli commands instead of MCP tools.
	static var rpInvestigateCLI: String { rpInvestigate(variant: .cli) }

	/// CLI variant of rp-deep-plan - uses rp-cli commands instead of MCP tools.
	static var rpDeepPlanCLI: String { rpDeepPlan(variant: .cli) }

	/// CLI variant of rp-build - uses rp-cli commands instead of MCP tools.
	static var rpBuildCLI: String { rpBuild(variant: .cli) }

	/// CLI variant of rp-orchestrate - uses rp-cli commands instead of MCP tools.
	static var rpOrchestrateCLI: String { rpOrchestrate(variant: .cli) }

	/// CLI variant of rp-optimize - uses rp-cli commands instead of MCP tools.
	static var rpOptimizeCLI: String { rpOptimize(variant: .cli) }

	// MARK: - Agent Variants (convenience accessors)

	/// Agent variant of rp-build - no Phase 0, uses ask_oracle instead of oracle_send.
	static var rpBuildAgent: String { rpBuild(variant: .agent) }

	/// Agent variant of rp-review - no Step 0, uses ask_oracle and ask_user.
	static var rpReviewAgent: String { rpReview(variant: .agent) }

	/// Agent variant of rp-refactor - no Step 0, uses ask_oracle.
	static var rpRefactorAgent: String { rpRefactorAgent(includeSessionCleanupGuidance: true) }
	static func rpRefactorAgent(includeSessionCleanupGuidance: Bool) -> String {
		rpRefactor(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
	}

	/// Agent variant of rp-investigate - no Phase 0, uses ask_oracle.
	static var rpInvestigateAgent: String { rpInvestigateAgent(includeSessionCleanupGuidance: true) }
	static func rpInvestigateAgent(includeSessionCleanupGuidance: Bool) -> String {
		rpInvestigate(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
	}

	/// Agent variant of rp-deep-plan - no Phase 0, uses ask_user / ask_oracle / agent_run.
	static var rpDeepPlanAgent: String { rpDeepPlanAgent(includeSessionCleanupGuidance: true) }
	static func rpDeepPlanAgent(includeSessionCleanupGuidance: Bool) -> String {
		rpDeepPlan(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
	}

	/// Agent variant of rp-oracle-export - no Phase 0.
	static var rpOracleExportAgent: String { rpOracleExport(variant: .agent) }

	/// Agent variant of rp-orchestrate - no Phase 0, uses agent_run for dispatch.
	static var rpOrchestrateAgent: String { rpOrchestrateAgent(includeSessionCleanupGuidance: true) }
	static func rpOrchestrateAgent(includeSessionCleanupGuidance: Bool) -> String {
		rpOrchestrate(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
	}

	/// Agent variant of rp-optimize - no Phase 0, uses ask_oracle and agent_run for dispatch.
	static var rpOptimizeAgent: String { rpOptimizeAgent(includeSessionCleanupGuidance: true) }
	static func rpOptimizeAgent(includeSessionCleanupGuidance: Bool) -> String {
		rpOptimize(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
	}
}
