# Investigation: Pair Model Override Ignored by Sub-Agent Launch

## Summary
Changing the Agent Mode Settings override for the Pair role is persisted correctly, but MCP sub-agent launch resolves `pair` through recommendation-only task-label logic instead of the workspace-scoped override-aware service. As a result, Pair still resolves to the recommended Codex GPT-5.4 High path when it should use `mcpAgentRoleOverrides["pair"]`.

## Symptoms
- User changes the Pair model in Agent Mode settings to a different GPT model, e.g. “Glacier alpha”.
- Running a Pair sub-agent still uses the default recommended config, observed as GPT-5.4.
- The behavior appears specific to role/sub-agent defaults, not necessarily explicit compound model IDs.

## Investigation Log

### Phase 1 — Settings persistence path
**Hypothesis:** The settings UI might not persist the Pair override.

**Findings:** The UI writes role changes through `MCPAgentRoleDefaultsService.setSelection`, and the setting is stored as a workspace-scoped dictionary keyed by `TaskLabelKind.rawValue`.

**Evidence:**
- `RepoPrompt/RepoPrompt/Views/Settings/AgentModeGeneralSettingsView.swift:263-268`
  ```swift
  let selection = AgentModelCatalog.NormalizedAgentSelection(agent: agent, modelRaw: option.rawValue)
  MCPAgentRoleDefaultsService.setSelection(selection, for: res.role, workspaceID: wsID, availability: availability)
  ```
- `RepoPrompt/RepoPrompt/Models/Settings/GlobalSettingsManager.swift:103-106`
  ```swift
  /// Explicit role-default overrides. Keys are TaskLabelKind rawValues, values are AgentModelSelectionID rawValues.
  /// nil means no overrides (all roles use recommended defaults).
  var mcpAgentRoleOverrides: [String: String]? = nil
  ```
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift:75-101` writes or removes the override. Non-recommended selections are stored with `settings.mcpAgentRoleOverrides?[role.rawValue] = selectionID.rawValue` at line 97.

**Conclusion:** Eliminated as the primary cause. The Pair override should persist as `mcpAgentRoleOverrides["pair"]`.

### Phase 2 — Override-aware resolution path
**Hypothesis:** There is an override-aware resolver, but runtime may not use it.

**Findings:** `MCPAgentRoleDefaultsService.effectiveSelection` reads `mcpAgentRoleOverrides` and returns a `RoleDefaultResolution` containing both recommended and effective selections.

**Evidence:**
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift:54-68` defines `effectiveSelection(for:workspaceID:...)`.
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift:61` reads `settingsStore.chatSettings(for: workspaceID).mcpAgentRoleOverrides`.
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift:145-164` applies a stored override when it parses and validates successfully, otherwise falls back to the recommendation.

**Conclusion:** Confirmed. The correct API exists for workspace-aware role-default resolution.

### Phase 3 — Recommended Pair default
**Hypothesis:** The observed GPT-5.4 model comes from the recommended Pair chain.

**Findings:** The Pair candidate chain starts with Codex GPT-5.4 High, and `resolveTaskLabelKind` returns the first available candidate.

**Evidence:**
- `RepoPrompt/RepoPrompt/Models/Agent/ModelSelection/AgentModelCatalog.swift:543-549`
  ```swift
  case .pair:
      return [
          SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.gpt54High.rawValue),
          SelectionCandidate(agent: .claudeCode, modelRaw: AgentModel.claudeOpus.rawValue),
          SelectionCandidate(agent: .claudeCodeGLM, modelRaw: AgentModel.claudeOpus.rawValue),
          SelectionCandidate(agent: .gemini, modelRaw: AgentModel.geminiPro3p1Preview.rawValue),
      ]
  ```
- `RepoPrompt/RepoPrompt/Models/Agent/ModelSelection/AgentModelCatalog.swift:593-606` loops over `candidateChain(for:)` and returns the first available candidate.

**Conclusion:** Confirmed. GPT-5.4 High is the recommendation-only Pair default.

### Phase 4 — MCP `agent_run.start` launch path
**Hypothesis:** Sub-agent launch resolves role labels through recommendation-only catalog logic.

**Findings:** `agent_run.start` computes a `defaultTaskLabel`, then calls `AgentMCPSelectionResolver.resolve` before session creation/configuration. For built-in Orchestrate workflow, the default label is `.pair`.

**Evidence:**
- `RepoPrompt/RepoPrompt/Models/Agent/AgentWorkflow.swift:91-101` maps `.orchestrate` to `.pair`.
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentRunMCPToolService.swift:76-82` computes `defaultTaskLabel` from workflow or falls back to `.engineer`.
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentRunMCPToolService.swift:84-89` calls:
  ```swift
  let selection = try AgentMCPSelectionResolver.resolve(
      modelID: normalizedString(args["model_id"]),
      defaultTaskLabel: defaultTaskLabel
  )
  ```

**Conclusion:** Confirmed. This is the runtime path for omitted `model_id` in workflow-driven sub-agent starts.

### Phase 5 — Resolver behavior
**Hypothesis:** The resolver cannot apply workspace overrides because it does not know the workspace.

**Findings:** `AgentMCPSelectionResolver.resolve` accepts only `modelID`, `defaultTaskLabel`, and `availability`. It has no `workspaceID` or settings store. For omitted `model_id`, it calls `AgentModelCatalog.resolveTaskLabelKind`. For explicit role labels like `"pair"`, it calls `AgentModelCatalog.resolveTaskLabel`, which also delegates to `resolveTaskLabelKind`.

**Evidence:**
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentMCPSelectionResolver.swift:36-38` signature lacks `workspaceID` / `settingsStore`.
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentMCPSelectionResolver.swift:39-45` omitted `model_id` + default role path:
  ```swift
  if let defaultKind = defaultTaskLabel,
      let resolved = AgentModelCatalog.resolveTaskLabelKind(defaultKind, availability: availability) {
      return ResolvedSelection(agentRaw: resolved.agent.rawValue, modelRaw: resolved.modelRaw, taskLabelKind: defaultKind)
  }
  ```
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentMCPSelectionResolver.swift:48-53` explicit no-colon label path calls `AgentModelCatalog.resolveTaskLabel(trimmed, availability: availability)`.
- `RepoPrompt/RepoPrompt/Models/Agent/ModelSelection/AgentModelCatalog.swift:584-590` shows `resolveTaskLabel` delegates to `resolveTaskLabelKind`.

**Conclusion:** Confirmed. This is the core mismatch: runtime role-label resolution bypasses workspace overrides.

### Phase 6 — Session application and prompt context
**Hypothesis:** The model might be corrected later after `taskLabelKind` is stored.

**Findings:** The resolved model is applied in `mcpConfigureSession` before dispatch. Later `taskLabelKind` is stored in `mcpControlContext` and used for prompt shaping, not model selection.

**Evidence:**
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentExternalMCPRunStarter.swift:52-68` activates MCP control context, then calls `mcpConfigureSession` with the already-resolved model.
- `RepoPrompt/RepoPrompt/ViewModels/AgentModeViewModel.swift:3405-3440` normalizes and sets `session.selectedAgent` / `session.selectedModelRaw`.
- `RepoPrompt/RepoPrompt/ViewModels/AgentModeViewModel.swift:3468-3501` stores `taskLabelKind` in `AgentMCPControlContext`.
- `RepoPrompt/RepoPrompt/ViewModels/AgentModeViewModel.swift:7434-7443` later passes `session.mcpControlContext?.taskLabelKind` into `SystemPromptService.agentModePrompt` for prompt shaping.

**Conclusion:** Eliminated. There is no later override lookup; by prompt construction time the selected model is already locked in.

### Phase 7 — Global search and git history
**Hypothesis:** Some other runtime path may read `mcpAgentRoleOverrides` before launch.

**Findings:** A global content search for `mcpAgentRoleOverrides` found matches only in `GlobalSettingsManager.swift` and `MCPAgentRoleDefaultsService.swift`. The MCP launch resolver did not reference the setting. Blame shows the recommendation-only resolver path and the override-aware service were added in separate Apr 2 commits.

**Evidence:**
- Search: `mcpAgentRoleOverrides` matched only:
  - `RepoPrompt/RepoPrompt/Models/Settings/GlobalSettingsManager.swift`
  - `RepoPrompt/RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift`
- Git blame:
  - `AgentMCPSelectionResolver.swift:40-44` came from commit `c54b1a5` on 2026-04-02.
  - `MCPAgentRoleDefaultsService.swift:53-68` came from commit `92ba298` on 2026-04-02.
- Commit `92ba298` message explicitly says it added “MCP agent role overrides persistence and Agent Mode settings UI for role-based defaults,” supporting that the settings system was added separately from the resolver’s recommendation-only default path.

**Conclusion:** Confirmed. No runtime override consumer was found in the MCP role-label start path.

### Phase 8 — Adjacent discovery surface
**Hypothesis:** `agent_manage.list_agents` may also report recommendation-only task-label mappings.

**Findings:** `AgentManageMCPToolService.executeListAgents` builds task-label entries using `AgentModelCatalog.discoveryTaskLabels()`, which is also recommendation-only. `create_session` uses the same resolver with `.engineer` as its default role.

**Evidence:**
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentManageMCPToolService.swift:85-89` calls `AgentModelCatalog.discoveryTaskLabels()`.
- `RepoPrompt/RepoPrompt/Models/Agent/ModelSelection/AgentModelCatalog.swift:610-624` builds discovery task labels from `resolveTaskLabelKind`.
- `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentManageMCPToolService.swift:257-263` calls `AgentMCPSelectionResolver.resolve(modelID: ..., defaultTaskLabel: .engineer)`.

**Conclusion:** Confirmed adjacent issue. If runtime role labels become workspace-aware, discovery should likely show effective workspace mappings to avoid misleading clients.

## Root Cause
MCP role-label runtime resolution was wired to `AgentModelCatalog` recommendation defaults instead of the workspace-scoped, override-aware `MCPAgentRoleDefaultsService`.

Concrete failing flow:

```text
agent_run.start
→ defaultTaskLabel = .pair (for Orchestrate workflow, or explicit model_id "pair")
→ AgentMCPSelectionResolver.resolve(...)
→ AgentModelCatalog.resolveTaskLabelKind(.pair)
→ first available Pair recommendation = codexExec + gpt-5.4-high
→ AgentExternalMCPRunStarter.start(...)
→ AgentModeViewModel.mcpConfigureSession(...)
→ session.selectedModelRaw = gpt-5.4-high
```

Expected flow:

```text
agent_run.start
→ defaultTaskLabel = .pair
→ workspace-aware role-default resolution
→ MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, workspaceID: activeWorkspace.id)
→ use mcpAgentRoleOverrides["pair"] when present and available
→ fall back to recommended Pair default only when no valid override exists
```

## Eliminated Hypotheses
- **Settings UI did not persist the override:** eliminated by `AgentModeGeneralSettingsView.swift:263-268` and `MCPAgentRoleDefaultsService.swift:75-101`.
- **Override model setting field does not exist:** eliminated by `GlobalSettingsManager.swift:103-106`.
- **A later task-label context pass corrects the selected model:** eliminated by `AgentModeViewModel.swift:3405-3440` and `AgentModeViewModel.swift:7434-7443`; `taskLabelKind` affects prompt context, not model selection.
- **Another runtime path reads `mcpAgentRoleOverrides`:** eliminated by global search; only settings/service files reference the field.

## Recommendations
1. Make `AgentMCPSelectionResolver.resolve` workspace-aware for role-driven paths.
   - Suggested signature change location: `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentMCPSelectionResolver.swift:36-39`.
   - Add optional `workspaceID: UUID?` and `settingsStore: GlobalSettingsStore = .shared` parameters.
   - For omitted `model_id` + `defaultTaskLabel`, and for explicit role labels like `"pair"`, first call `MCPAgentRoleDefaultsService.effectiveSelection(for: role, workspaceID: workspaceID, availability: availability, settingsStore: settingsStore)` when a workspace ID is available.
   - Preserve current `AgentModelCatalog.resolveTaskLabelKind` fallback when no workspace is available or no valid override exists.
   - Do not rewrite explicit compound IDs such as `codexExec:gpt-5.4-high`; those should remain exact user requests.

2. Pass the active workspace ID from MCP callers.
   - `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentRunMCPToolService.swift:68-89` already has `workspace`; pass `workspace.id` into the resolver.
   - `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentManageMCPToolService.swift:240-263` should pass active workspace ID for `create_session` default `.engineer` resolution.
   - `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentManageMCPToolService.swift:303-313` should pass active workspace ID for explicit role labels during resume.

3. Update `agent_manage.list_agents` task-label discovery to reflect effective workspace defaults.
   - Current location: `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentManageMCPToolService.swift:85-89`.
   - Minimum: use `MCPAgentRoleDefaultsService.resolutions(for: workspace.id)` and show `effective` selections for `task_labels`.
   - Better: include both effective and recommended metadata, e.g. `has_custom_override`, `recommended_model_id`, and `override_unavailable`, if schema compatibility allows.
   - If no workspace is available, retain current recommendation-only fallback.

4. Add focused regression tests.
   - Add unit tests for `MCPAgentRoleDefaultsService` persistence/effective resolution: a Pair override should persist as a compound `AgentModelSelectionID` under key `"pair"` and resolve as effective.
   - Add resolver tests for:
     - `modelID: nil, defaultTaskLabel: .pair, workspaceID: workspaceID` returns the override.
     - `modelID: "pair", workspaceID: workspaceID` returns the override.
     - no override still falls back to `codexExec + AgentModel.gpt54High.rawValue` when available.
     - explicit compound IDs are not overridden.
   - Add a lightweight `AgentRunMCPToolService.executeStart` spy/integration test: active workspace has Pair override, workflow is Orchestrate, `model_id` omitted, and captured `startRun` receives the overridden `agentRaw` / `modelRaw` with `taskLabelKind == .pair`.
   - If `list_agents` is updated, add a payload test that `task_labels` reports the effective Pair override rather than the recommended GPT-5.4 default.

## Preventive Measures
- Keep a single resolver responsible for the `model_id` grammar so role-label behavior does not drift across `agent_run`, `agent_manage`, and future MCP tools.
- Any new role-default UI setting should have a runtime-path test proving the setting affects actual launch arguments, not just the settings display.
- Discovery APIs (`list_agents`) should report the same effective role-label mapping that runtime will apply, or clearly include both effective and recommended mappings.
- Add search-helper comments near `AgentMCPSelectionResolver` and `MCPAgentRoleDefaultsService` after the fix to make the relationship between task labels and workspace overrides obvious.
