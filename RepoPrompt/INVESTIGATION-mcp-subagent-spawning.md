# Investigation: MCP Agent Sub-Agent Spawning Permissions

## Summary
External MCP-started agent runs (e.g., from Claude Code terminal) cannot spawn sub-agents due to two independent blocking issues: (1) a spawn guard that rejects ALL MCP-controlled sessions, and (2) a tool advertisement policy that hides `agent_run`/`agent_manage` from non-explore role agents. Both must be fixed to enable the orchestrate workflow for external MCP clients.

## Symptoms
- External MCP clients calling `agent_run.start` with `workflow=orchestrate` create a session, but the agent inside cannot spawn sub-agents
- The orchestrate workflow system prompt instructs agents to use `agent_run start/steer/wait`, but:
  1. The tools aren't visible in ListTools responses
  2. Even if invoked by name, the spawn guard blocks the call
- This makes the orchestrate workflow non-functional for MCP-started runs

## Current Rules (Desired)
- **Top-level run** (user OR external MCP client) → **CAN** spawn sub-agents
- **Sub-level run** (spawned by another agent) → **CANNOT** spawn sub-agents

---

## Investigation Log

### Issue 1: Spawn Guard Blocks All MCP Sessions

**File:** `RepoPrompt/RepoPrompt/ViewModels/AgentModeViewModel.swift` — line 3305

**Current code:**
```swift
func mcpValidateAgentRunSpawnAllowed(sourceTabID: UUID?) throws {
    guard let sourceTabID,
        let sourceSession = sessions[sourceTabID],
        sourceSession.mcpControlContext != nil else {
        return
    }
    throw MCPError.invalidParams(
        "MCP-controlled agent sessions cannot start nested agent runs. Start the child run from the UI or from a top-level MCP client instead."
    )
}
```

**Problem:** Checks `sourceSession.mcpControlContext != nil` — this is `true` for ALL MCP-controlled sessions, including top-level ones. Should only block nested sessions.

**Evidence:** The lineage signal already exists via `TabSession.parentSessionID` (line 651):
- Top-level MCP sessions: `parentSessionID == nil`
- Nested child sessions: `parentSessionID != nil` (set by `applySpawnParentSessionID` at line 3327)

**Called from:**
- `AgentRunMCPToolService.executeStart` (line 80 of AgentRunMCPToolService.swift)
- `AgentManageMCPToolService.executeCreateSession` (line 248 of AgentManageMCPToolService.swift)

**Fix:** Allow when `parentSessionID == nil`:
```swift
func mcpValidateAgentRunSpawnAllowed(sourceTabID: UUID?) throws {
    guard let sourceTabID,
        let sourceSession = sessions[sourceTabID],
        sourceSession.mcpControlContext != nil else {
        return
    }
    // Top-level MCP sessions (no parent) may spawn sub-agents.
    guard sourceSession.parentSessionID != nil else {
        return
    }
    throw MCPError.invalidParams(
        "Sub-agents cannot start additional agent runs. Only top-level MCP-started agent sessions may spawn sub-agents."
    )
}
```

---

### Issue 2: Tool Advertisement Hides agent_run/agent_manage

**File:** `RepoPrompt/RepoPrompt/Services/MCP/Policies/AgentModeMCPToolAdvertisementPolicy.swift` — line 39

**Current code:**
```swift
/// Tools hidden from non-explore role agents (engineer, pair, design).
/// These agents get full tool access except agent_run/agent_manage to prevent recursive spawning.
private static let nonExploreRoleHiddenTools: Set<String> = {
    MCPToolCapabilities.toolNames(for: [.agentExternalControl])
}()
```

**Problem:** For ALL non-explore roles (engineer, pair, design), `agent_run` and `agent_manage` are hidden from ListTools. The orchestrate workflow defaults to `.pair` role (AgentWorkflow.swift line 101: `case .orchestrate: return .pair`). So the agent running inside a top-level MCP orchestrate session won't see `agent_run` in its tool list.

**Note:** `agent_run`/`agent_manage` are NOT in `MCPPolicyGatedTools` (MCPPolicyGatedTools.swift), so they're only filtered by the advertisement policy. The call-time execution check (MCPConnectionManager.swift line 3987) only blocks policy-gated tools.

**Threading path for taskLabelKind:**
1. `AgentWorkflow.defaultTaskLabelKind` → `.pair` for orchestrate (AgentWorkflow.swift:101)
2. → `AgentMCPSelectionResolver.resolve` → selection with taskLabelKind
3. → `AgentExternalMCPRunStarter.start` → `mcpActivateControlContext` (stores in control context)
4. → `MCPBootstrapLeaseSpec.agentMode` (AgentModeRunLease.swift:17) → includes taskLabelKind
5. → `installClientConnectionPolicy` (MCPConnectionManager.swift:3002) → stores in run policy
6. → `effectivePolicyState` (MCPConnectionManager.swift:743-753) → returns taskLabelKind
7. → ListTools handler (MCPConnectionManager.swift:3876-3879) → `shouldAdvertise(toolName:taskLabelKind:)`

**Fix:** Add an explicit `allowsAgentExternalControlTools` flag through the policy pipeline, derived from session lineage (`isMCPOriginated && parentSessionID == nil`). The advertisement policy should skip hiding `agent_run`/`agent_manage` when this flag is true.

---

### Eliminated Hypotheses

**`isMCPOriginated` as the right discriminator:** No — both top-level AND child MCP-created sessions set `isMCPOriginated = true` (set in `mcpActivateControlContext`, line 3505). It's lifecycle/cleanup metadata, not a spawn permission flag.

**Using `additionalTools` to override advertisement:** Doesn't work because `agent_run`/`agent_manage` aren't policy-gated tools. Even if added to `additionalTools`, the advertisement policy filter at MCPConnectionManager.swift:3876 runs independently and would still hide them.

**Setting `taskLabelKind = nil` for top-level sessions:** Would disable ALL role-based filtering, not just for agent delegation tools. Mixes "who the agent is" with "what it's allowed to delegate."

---

## Root Cause
Two independent guards were designed to prevent recursive agent spawning, but both are too broad — they block ALL MCP-controlled sessions rather than just nested ones:

1. **Spawn guard** (`mcpValidateAgentRunSpawnAllowed`): Checks `mcpControlContext != nil` instead of `parentSessionID != nil`
2. **Advertisement policy** (`nonExploreRoleHiddenTools`): Hides agent_run/agent_manage from all non-explore roles, with no exception for top-level sessions

## Recommendations

### 1. Fix spawn guard (AgentModeViewModel.swift:3305)
Change the rejection condition from `mcpControlContext != nil` to `mcpControlContext != nil && parentSessionID != nil`.

### 2. Add helper property on TabSession
```swift
var isTopLevelMCPOriginatedSession: Bool {
    isMCPOriginated && parentSessionID == nil
}
```

### 3. Thread `allowsAgentExternalControlTools` through policy pipeline
Add a `Bool` field through:
- `MCPBootstrapLeaseSpec` (MCPBootstrapLease.swift:6)
- `RunConnectionPolicyState` (MCPConnectionManager.swift:419)
- `ClientConnectionPolicy` (MCPConnectionManager.swift:397)
- `installClientConnectionPolicy` signature (MCPConnectionManager.swift:2991)
- `effectivePolicyState` return tuple (MCPConnectionManager.swift:743)
- `AgentModeMCPPolicyInstaller.install` (AgentModeMCPPolicyInstaller.swift:12)
- `AgentModeRunLease.agentMode` (AgentModeRunLease.swift:4)

Derived from: `session.isMCPOriginated && session.parentSessionID == nil`

### 4. Update advertisement policy (AgentModeMCPToolAdvertisementPolicy.swift)
Add overload:
```swift
static func shouldAdvertise(
    toolName: String,
    taskLabelKind: AgentModelCatalog.TaskLabelKind?,
    allowsAgentExternalControlTools: Bool
) -> Bool {
    if allowsAgentExternalControlTools,
       MCPToolCapabilities.capabilities(for: toolName).contains(.agentExternalControl) {
        return true
    }
    return shouldAdvertise(toolName: toolName, taskLabelKind: taskLabelKind)
}
```

### 5. Update ListTools handler (MCPConnectionManager.swift:3876)
Pass the new flag to `shouldAdvertise`.

### 6. Update tests (AgentModeMCPControlTests.swift)
- `testMCPControlledSessionCannotSpawnNestedAgentRuns` → update to set `parentSessionID` first (nested session)
- Add: `testTopLevelMCPControlledSessionCanSpawnSubAgents`
- Add: advertisement policy tests for `allowsAgentExternalControlTools`

## Files to Modify
1. `RepoPrompt/RepoPrompt/ViewModels/AgentModeViewModel.swift` — spawn guard + helper property
2. `RepoPrompt/RepoPrompt/Services/MCP/Policies/AgentModeMCPToolAdvertisementPolicy.swift` — flag-aware shouldAdvertise
3. `RepoPrompt/RepoPrompt/Services/MCP/MCPBootstrapLease.swift` — add field to MCPBootstrapLeaseSpec
4. `RepoPrompt/RepoPrompt/Services/MCP/MCPConnectionManager.swift` — thread flag through policy structs, ListTools, effectivePolicyState
5. `RepoPrompt/RepoPrompt/Services/AgentMode/AgentModeMCPPolicyInstaller.swift` — compute flag from session state
6. `RepoPrompt/RepoPrompt/Services/AgentMode/AgentModeRunLease.swift` — add parameter
7. `RepoPromptTests/AgentModeMCPControlTests.swift` — update/add tests

## Preventive Measures
- When adding permission guards, prefer explicit lineage-based checks (`parentSessionID`) over MCP-control-context presence
- Keep role-based filtering separate from delegation/lineage permissions
- The helper `isTopLevelMCPOriginatedSession` should be the canonical way to check this, rather than ad-hoc `mcpControlContext` checks

---

# Feature: Multi-Session Wait for agent_run

## Summary
Add support for `agent_run op=wait` and `op=poll` to accept `session_ids` (array) in addition to the existing `session_id` (single). For `wait`, return when the **first** session reaches an interesting state. For `poll`, return all current snapshots immediately.

## Motivation
An orchestrator that dispatches multiple agents in parallel (e.g., via the orchestrate workflow) currently has no way to block until the first agent needs attention. It must either poll each session individually or wait sequentially — both wasteful and slow.

## Current Architecture

### Wait Mechanism
- `AgentRunMCPToolService.executeWait` → single `session_id` → `waitForInterestingState`
- `waitForInterestingState` → `withHeartbeat` wrapper → `AgentRunSessionStore.waitUntilInteresting(sessionID:timeoutSeconds:)`
- `AgentRunSessionStore` is an actor with per-session `Record` structs containing `waiters: [Waiter]`
- Each `Waiter` holds a `CheckedContinuation<WaitDisposition, Never>` + optional timeout `Task`
- Woken by `noteSnapshot` when snapshot is terminal or has an `interaction`
- Cancellation: `withTaskCancellationHandler` → `cancelWaiter` → resumes with `.expired`, cancels timeout task

### Key files
- `AgentRunSessionStore.swift` (lines 1-232) — waiter actor
- `AgentRunMCPToolService.swift` — executeWait, waitForInterestingState, resolveControlSessionID
- `MCPServerViewModel.swift` (lines 6032-6151) — tool schema definition
- `ToolOutputFormatter.swift` (lines 3380-3529) — formatAgentRun response formatting
- `AgentRunMCPSnapshot.swift` — snapshot model and serialization

## Design Decisions

### 1. No changes needed to AgentRunSessionStore
The existing `waitUntilInteresting` per-session primitive is composable. Multi-wait races N single-session waits using Swift's `withTaskGroup` + `cancelAll()`. Cancellation safety is already built in.

### 2. Response format
- **Winner at top level**: The winning snapshot is serialized at the top level (backward compatible with single-session consumers)
- **`wait` metadata object**: Contains `mode`, `result`, `winner_session_id`, `session_ids`, `pending_session_ids`, `waited_count`
- **`snapshots` array**: Only included on **timeout** (no winner to report, caller needs all current states)
- On success, `snapshots` is NOT included to avoid bloat (assistant_text can be large) and non-atomic implied semantics

### 3. Multi-poll support
- `op=poll` with `session_ids` returns all current snapshots immediately in a collection response
- Different response shape from multi-wait — polling is a dashboard, not a race
- Small additive feature since session_ids parsing/resolution is already needed

### 4. Scope restrictions
- `session_ids` only for `wait` and `poll`
- NOT supported for `steer`, `respond`, `cancel` (single-session operations by nature)
- `session_id` and `session_ids` are mutually exclusive

## Implementation Plan

### 1. AgentRunMCPToolService.swift — Core Implementation

#### a) Add helper struct
```swift
private struct WaitAnyResult: Sendable {
    let sessionID: UUID
    let disposition: AgentRunSessionStore.WaitDisposition
}
```

#### b) Refactor resolveControlSessionID
Extract a `resolveControlSessionID(reference:targetWindow:agentModeVM:)` overload from the args-based method:
```swift
private func resolveControlSessionID(
    reference raw: String,
    targetWindow: WindowState,
    agentModeVM: AgentModeViewModel
) async throws -> UUID
```

#### c) Add session_ids parsing + resolution
```swift
private func parseSessionIDArray(_ args: [String: Value]) throws -> [String]
private func resolveControlSessionIDs(_ references: [String], ...) async throws -> [UUID]
```

#### d) Update executeWait
- Check for `session_ids` first; if present and not `forcePoll`, call `executeWaitAny`
- Existing single-session path unchanged

#### e) Add executeWaitAny
- Parse + resolve session IDs
- Single-element optimization: delegate to existing single-session path
- Check initial snapshots for already-interesting sessions (first in input order wins)
- If timeout <= 0, return immediately with all snapshots
- Otherwise race via `waitUntilFirstInteresting` using `withTaskGroup`

#### f) Add executePollMany (if multi-poll included)
- Parse + resolve session IDs
- Collect all current snapshots
- Return collection response with derived convenience arrays

#### g) Add response builders
```swift
private func decoratedMultiWaitValue(snapshot:sessionIDs:result:snapshots:) -> Value
private func decoratedMultiPollValue(sessionIDs:snapshots:) -> Value  // if multi-poll
```

### 2. MCPServerViewModel.swift — Schema Updates (lines 6032-6151)

#### a) Update tool description
```
- `wait`: Block until the run finishes or needs input. Default 300s. `timeout: 0` = poll.
  Requires `session_id` for single-session wait, or `session_ids` for multi-session wait
  (returns when the first session reaches an interesting state).
- `poll`: Return current snapshot immediately. Requires `session_id` or `session_ids`.
  With `session_ids`, returns all current snapshots in a collection response.
```

#### b) Update inputSchema description
```
**poll / wait**: session_id (single session) or session_ids (multiple sessions), timeout? (wait only)
```

#### c) Add session_ids property
```swift
"session_ids": .array(
    description: "[wait, poll] Array of session UUIDs. For wait: returns when first session reaches interesting state. For poll: returns all current snapshots. Mutually exclusive with session_id.",
    items: .string()
),
```

### 3. ToolOutputFormatter.swift — Formatting (lines 3380-3529)

#### a) Multi-wait formatting
After status line in `formatAgentRun`, detect `wait.mode == "any"` and append:
- Wait mode line
- Wait result line (snapshot_ready / timed_out / expired)
- Winner session ID
- Pending session IDs

#### b) Multi-poll formatting
Detect `poll.mode == "many"` or presence of `snapshots` array — render a concise session list with status for each.

### 4. Tests

#### AgentRunSessionStoreTests.swift
- Already has full coverage of single-session waiter behavior
- No changes needed — multi-wait composes existing primitive

#### AgentMCPToolServiceTests.swift
Add:
- `testAgentRunWaitAnyReturnsFirstInterestingSession` — 2 sessions running, signal one completed, verify winner
- `testAgentRunWaitAnyTimeoutReturnsAllSnapshots` — timeout=0, verify snapshots array
- `testAgentRunWaitAnyAlreadyInterestingReturnsImmediately` — one session already terminal at entry
- `testAgentRunWaitAnyRejectsMixedSessionIDInputs` — both session_id and session_ids → error
- `testAgentRunPollManyReturnsAllSnapshots` — (if multi-poll included)

## Edge Cases

| Case | Behavior |
|------|----------|
| All sessions already interesting | First in input order wins (deterministic) |
| Single-element session_ids | Delegates to existing single-session path |
| session_id + session_ids both present | Error: mutually exclusive |
| Empty session_ids array | Error: must be non-empty |
| Duplicate session IDs | Deduplicated (Set) |
| Session expired during wait | WaitDisposition.expired from that session |
| Timeout boundary race | Re-collect snapshots on timeout, check for last-second winner |
| session_ids with steer/respond/cancel | Error (not supported) |

## Files to Modify
1. `RepoPrompt/RepoPrompt/Services/MCP/Agent/AgentRunMCPToolService.swift` — core multi-wait + multi-poll logic
2. `RepoPrompt/RepoPrompt/ViewModels/MCPServerViewModel.swift` — schema/docs update (lines ~6032-6151)
3. `RepoPrompt/RepoPrompt/Services/MCP/ToolOutputFormatter.swift` — response formatting (lines ~3380-3529)
4. `RepoPrompt/RepoPromptTests/AgentMCPToolServiceTests.swift` — new tests
