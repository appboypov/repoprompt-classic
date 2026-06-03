# Investigation: MCP Agent Permission Stalling in Codex (CLI Path)

## Summary
The primary issue is that MCP-spawned Codex agent sessions run with `workspaceWrite` sandbox + `onRequest` approval, but the sandbox physically restricts commands (like `xcodebuild`) from accessing paths outside `writableRoots` (e.g., `~/Library/Developer/Xcode/DerivedData/`). **No approval interaction is ever emitted** because Codex doesn't know the command needs broader access — it just runs inside the sandbox and fails. The `agent_run op=wait` API correctly has nothing to return. Additionally, RepoPrompt treats `item/permissions/requestApproval` as unsupported for non-RP servers, so even if Codex tried to request elevated permissions, it would be rejected rather than surfaced. There are also secondary bugs with approval decision downgrading and MCP session prompt hiding.

## Real-World Failure Report
- **Setup**: OpenClaw → rp-wrapper → `repoprompt-mcp` CLI binary
- **Flow**: `agent_run op=start ... detach=true` → `agent_run op=wait session_id=... timeout=...`
- **Task**: Run `xcodebuild test -scheme Yumami -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:YumamiTests -quiet`
- **Result**: No `waiting_for_input` or `interaction_id` returned. Command ran sandboxed and failed with "Operation not permitted" on `~/Library/Developer/Xcode/DerivedData/...` and `~/Library/Caches/org.swift.swiftpm/...`

## Symptoms
- Agent runs fail silently with sandbox permission errors — no approval surfaces
- `agent_run op=wait` returns no interaction for the wrapper to respond to
- Commands that need access outside the workspace directory simply fail
- Separately: approval decisions are downgraded, and MCP session prompts are hidden from UI

---

## Investigation Log

### Finding 0 — PRIMARY ROOT CAUSE: Sandbox physically blocks xcodebuild with no approval escape path
**Files:**
- `RepoPrompt/ViewModels/AgentModeViewModel.swift` lines 80-105 (AgentPermissionProfile)
- `RepoPrompt/ViewModels/AgentModeViewModel.swift` line 3502 (mcpSafeDefaults forced)
- `RepoPrompt/Services/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` lines 5618-5637 (appServerTurnSandboxPolicyPayload)
- `RepoPrompt/Services/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` lines 2165-2178 (permissions unsupported handling)

**Evidence:**
```swift
// AgentModeViewModel.swift:3500-3502 — MCP sessions force safe defaults
session.permissionProfile = .mcpSafeDefaults

// AgentModeViewModel.swift:94-105 — mcpSafeDefaults resolves to workspaceWrite + onRequest
case .mcpSafeDefaults: .workspaceWrite  // sandbox mode
case .mcpSafeDefaults: .onRequest       // approval policy

// CodexNativeSessionController.swift:5627-5634 — workspaceWrite only allows project dir
case .workspaceWrite:
    var payload: [String: Any] = [
        "type": "workspaceWrite",
        "networkAccess": true
    ]
    if let workspacePath = workspacePath { payload["writableRoots"] = [workspacePath] }

// CodexNativeSessionController.swift:2165-2178 — permissions requests rejected!
case .permissionsUnsupported:
    if let approvalResult = Self.repoPromptPermissionsAutoApprovalResult(params: params) {
        // Auto-approve RepoPrompt MCP only
    }
    await emitServerRequestIssue(...)  // Reject all non-RP permission requests!
```

**Impact chain:**
1. MCP-spawned session gets `workspaceWrite` sandbox → `writableRoots = ["/path/to/project"]`
2. `xcodebuild test` runs inside macOS `sandbox-exec` profile
3. xcodebuild tries to write to `~/Library/Developer/Xcode/DerivedData/` → sandbox physically DENIES
4. Command fails with "Operation not permitted" — Codex never had a chance to request approval
5. Even if Codex's model used the `request_permissions` tool, RepoPrompt would REJECT the `item/permissions/requestApproval` server request for non-RP MCP servers
6. `agent_run op=wait` correctly returns no interaction — there was never one to surface

**This is the primary cause of the reported failure.** There are two problems:
1. The `workspaceWrite` sandbox `writableRoots` doesn't include paths that xcodebuild needs
2. There's no supported escape path — `item/permissions/requestApproval` is rejected as unsupported

### Finding 0b — RACE CONDITION: mcpControlContext nil when approval arrives on reused sessions
**Files:**
- `RepoPrompt/ViewModels/AgentModeViewModel.swift` line 2931 (`ensureSessionReady`)
- `RepoPrompt/ViewModels/AgentModeViewModel.swift` line 2944-2945 (triggers Codex controller on active session)
- `RepoPrompt/Services/MCP/Agent/AgentExternalMCPRunStarter.swift` lines 58-68 (ordering: configure → bind → activate → dispatch)

**Evidence — The race window:**
```
AgentExternalMCPRunStarter.start() ordering:

1. mcpConfigureSession(...)              ← calls ensureSessionReady()
   └─ ensureSessionReady():
      └─ if session.selectedAgent == .codexExec, session.runState.isActive:
         └─ await codexCoordinator.ensureCodexNativeSession(session:)  // ← STARTS CONTROLLER + EVENTS
            └─ Events can arrive NOW → handleCodexNativeEvent(.approvalRequest)
               └─ session.pendingApproval = request
               └─ shouldSurfaceInteractionsInUI → mcpControlContext == nil → TRUE → SHOWS IN APP UI

2. bindCurrentRequestToTab(...)

3. mcpActivateControlContext(...)        ← sets mcpControlContext (TOO LATE!)
   └─ session.mcpControlContext = AgentMCPControlContext(...)
   └─ session.permissionProfile = .mcpSafeDefaults

4. mcpDispatchInstruction(...)
```

**Impact:** When an MCP client (`agent_run op=start` or `op=steer`) targets an **already-active Codex session**, the Codex controller and event stream can be running before `mcpControlContext` is set. Any approval events arriving in this window:
1. Show in the RepoPrompt app UI (because `shouldSurfaceInteractionsInUI == true`)
2. Are NOT visible via `agent_run op=wait` (because `mcpPendingInteraction` checks `mcpControlContext`)
3. The MCP wrapper has no way to respond
4. If the user clicks approve in the UI, the response goes through `buildApprovalResult` which downgrades it

**This explains the exact user report:** "I saw approval requests that I clicked on to approve and not ask again, but not sure why it seems to stall" — the user saw the approval in the app because MCP context wasn't set yet, clicked it, but the wrapper never knew about it.

**Fix:** Move `mcpActivateControlContext()` to BEFORE `mcpConfigureSession()` in `AgentExternalMCPRunStarter.start()`, or prevent `ensureSessionReady` from triggering `ensureCodexNativeSession` when called from MCP paths.

### Finding 1 — Approval decisions are discarded by `buildApprovalResult`
**File:** `RepoPrompt/Services/AgentMode/Codex/CodexAgentModeCoordinator.swift` lines 4783-4795
**Evidence:**
```swift
case .acceptForSession:
    decisionValue = "accept"           // BUG: Should be "acceptForSession"
case .acceptWithExecpolicyAmendment:
    decisionValue = "accept"           // BUG: Should be {"acceptWithExecpolicyAmendment": {execpolicy_amendment: ...}}
```
**Impact:** User clicks "Always Allow" or "Approve & Remember" in the UI (`AgentApprovalCard.swift` lines 106-118), but Codex only receives `"accept"` (one-time). Codex's session/persistent remember logic (`CommandExecutionApprovalDecision` in `codex_app_server_protocol`) is never triggered. This directly causes the "approve and don't ask again but it keeps asking" behavior.

**Codex protocol reference:** `codex/codex-rs/app-server-protocol/schema/typescript/v2/CommandExecutionApprovalDecision.ts`:
```typescript
export type CommandExecutionApprovalDecision = "accept" | "acceptForSession" | { "acceptWithExecpolicyAmendment": ... } | ...
```

### Finding 2 — MCP tool auto-approval always picks one-time "Allow"
**File:** `RepoPrompt/Services/AgentMode/Codex/CodexAgentModeCoordinator.swift` lines 4769-4778
**Evidence:**
```swift
private static func buildAutoApprovalResponse(for request: AgentRequestUserInputRequest) -> AgentRequestUserInputResponse {
    var answers: [String: [String]] = [:]
    for question in request.questions where question.id.hasPrefix("mcp_tool_call_approval") {
        let label = question.options.first?.label ?? "Allow"  // Always first = "Allow" (one-time)
        answers[question.id] = [label]
    }
    ...
}
```
**Impact:** RepoPrompt auto-answers ALL MCP tool approval requests with "Allow" (one-time). Never selects "Allow for this session" or "Allow and don't ask me again". This means every MCP tool call triggers a fresh approval prompt from Codex, though RepoPrompt silently auto-answers it.

**Options available:** `mcp_tool_call.rs` lines 1073-1091 defines: `Allow`, `Allow for this session`, `Allow and don't ask me again`, `Cancel`

### Finding 3 — MCP-controlled sessions hide ALL approval prompts
**File:** `RepoPrompt/ViewModels/AgentModeViewModel.swift` lines 686-688
**Evidence:**
```swift
var shouldSurfaceInteractionsInUI: Bool {
    mcpControlContext == nil
}
```
**Impact:** When an MCP parent agent controls the session, ALL approval/question cards are suppressed from the UI. The parent is expected to handle them via `agent_run.respond`, but if it doesn't poll promptly, the session sits in `waitingForApproval` with no visible prompt for the user. This is the "hidden prompt" behavior the user described.

**Suggestion:** Either show the prompt to the user anyway (with a note that the parent agent can also respond), or delay hiding by ~5 seconds to give the parent time to handle it.

### Finding 4 — Transport-close with pending approval leaves session stranded
**File:** `RepoPrompt/Services/AgentMode/Codex/CodexAgentModeCoordinator.swift` lines 3392-3413
**Evidence:**
```swift
let isTransportClosed = message.localizedCaseInsensitiveContains("transport closed")
if isTransportClosed {
    if !session.runState.isActive { /* cleanup */ return }
    if session.pendingApproval == nil, session.runState != .waitingForApproval {
        // Only THIS path attempts reconnect
        setRunningStatus("Reconnecting…", ...)
        scheduleCodexTransportClosedFallback(...)
    }
    return  // <-- If pendingApproval != nil, just return! No reconnect, no finalization!
}
```
**Impact:** If the transport dies while an approval is pending, the session is permanently stuck. No reconnect, no failure, no cleanup.

### Finding 5 — Pre-bind buffer overflow silently drops server requests
**File:** `RepoPrompt/Services/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` lines 1218-1224
**Evidence:**
```swift
private func appendBufferedInbound(_ inbound: BufferedInbound) {
    if bufferedInbound.count >= maxBufferedInbound {
        bufferedInbound.removeFirst()
        Self.logCodexDebug("[CodexNativeController] dropping oldest pre-bind inbound event due to buffer cap")
    }
    bufferedInbound.append(inbound)
}
```
**Impact:** If 128+ events arrive during session binding, the oldest are silently dropped. Unlike Codex's Rust `app-server-client` (which explicitly rejects dropped `ServerRequest` via `fail_server_request`), RepoPrompt's drop path sends NO response back. If the dropped event was an approval/permission request, Codex waits forever.

### Finding 6 — `cancelPendingApproval` doesn't respond to Codex
**File:** `RepoPrompt/ViewModels/AgentModeViewModel.swift` line ~8162
**Evidence:**
```swift
private func cancelPendingApproval(for session: TabSession) {
    session.pendingApproval = nil  // Just clears local state — no response sent to Codex!
}
```
**Impact:** When RepoPrompt cancels a pending approval (e.g., on run finalization), no decline/cancel response is sent back to Codex. This can leave the Codex-side request_user_input call hanging.

### Finding 7 — Permissions requests are rejected (not prompted) for non-RP MCP
**File:** `RepoPrompt/Services/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` lines 2165-2178
**Evidence:**
```swift
case .permissionsUnsupported:
    if let approvalResult = Self.repoPromptPermissionsAutoApprovalResult(params: params) {
        await respondToServerRequest(id: request.id, result: approvalResult)
        return
    }
    await emitServerRequestIssue(
        requestID: request.id, method: method,
        kind: .permissionsRequestUnsupported, code: -32001,
        message: "Codex requested item/permissions/requestApproval for a non-RepoPrompt MCP server..."
    )
```
**Impact:** `item/permissions/requestApproval` (elevated sandbox access) is never shown to the user. It's either auto-approved (RepoPrompt MCP) or immediately rejected (everything else). The rejection causes `finalizeCodexRun` with `.failed` — not a stall per se, but the user may perceive it as one since the run just dies.

---

## Root Causes

### Primary Root Cause: Race condition — MCP context not set when approval arrives (Finding 0b)
When `agent_run op=start` or `op=steer` targets an already-active Codex session, `ensureSessionReady()` calls `ensureCodexNativeSession()` BEFORE `mcpActivateControlContext()`. This means the Codex event stream is live while `mcpControlContext` is still nil. Approvals arriving in this window show in the app UI instead of being routed through the MCP snapshot → the wrapper never sees them → the wrapper has nothing to respond to → the user sees the approval in the app, responds there, but the wrapper stalls.

### Contributing: Sandbox too restrictive for builds (Finding 0)
MCP-spawned sessions use `workspaceWrite` sandbox with `writableRoots = [projectDir]` only. `xcodebuild` needs `~/Library/Developer/Xcode/DerivedData/` etc. The sandbox blocks writes without generating an approval prompt.

### Contributing: Approval decision downgrading (Finding 1)
When the user DOES click the approval in the app UI, `buildApprovalResult` downgrades `acceptForSession` → `"accept"`, so Codex re-prompts on the next command. This creates a cycle.

### Contributing: Hidden prompts + stall paths (Findings 3-6)
MCP-controlled sessions hide prompts, transport-close strands sessions, buffer drops lose requests.

---

## Recommendations

### Fix 0: Fix the MCP activation race (CRITICAL — explains the exact user report)
**File:** `AgentExternalMCPRunStarter.swift` — `start()` method (~line 58)

Move `mcpActivateControlContext()` to BEFORE `mcpConfigureSession()`:
```swift
// Current (buggy) order:
// 1. mcpConfigureSession(...)     ← can start controller/events
// 2. bindCurrentRequestToTab(...)
// 3. mcpActivateControlContext(...)  ← sets MCP context (too late!)
// 4. mcpDispatchInstruction(...)

// Fixed order:
// 1. mcpActivateControlContext(...)  ← set MCP context FIRST
// 2. mcpConfigureSession(...)     ← now controller starts with context set
// 3. bindCurrentRequestToTab(...)
// 4. mcpDispatchInstruction(...)
```

Note: `mcpActivateControlContext` needs `sessionID` which comes from the target. The target is created before this, so the sessionID should be available. Alternatively, add a flag to `ensureSessionReady` to skip `ensureCodexNativeSession` when called from MCP paths, deferring controller creation to the dispatch step.

### Fix 0a: Expand `workspaceWrite` sandbox for Xcode builds
**File:** `CodexNativeSessionController.swift` — `appServerTurnSandboxPolicyPayload` (~line 5618)

Option A — Add common Xcode paths to `writableRoots`:
```swift
case .workspaceWrite:
    var writableRoots: [String] = []
    if let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
       !workspacePath.isEmpty {
        writableRoots.append(workspacePath)
    }
    // Add Xcode/SwiftPM paths needed for builds
    let home = NSHomeDirectory()
    writableRoots.append("\(home)/Library/Developer/Xcode/DerivedData")
    writableRoots.append("\(home)/Library/Caches/org.swift.swiftpm")
    var payload: [String: Any] = [
        "type": "workspaceWrite",
        "networkAccess": true,
        "writableRoots": writableRoots
    ]
    return payload
```

Option B — Support `item/permissions/requestApproval` as a real approval surface:
Instead of rejecting non-RP permission requests, surface them as `AgentApprovalRequest` so the user/wrapper can approve. This is the more correct long-term fix.

Option C — For MCP-spawned sessions, allow the caller to specify sandbox mode:
Add a `sandbox_mode` parameter to `agent_run op=start` that allows callers like rp-wrapper to request `dangerFullAccess` when needed for builds.

**Recommended approach:** Option C (most flexible, immediate fix) + Option B (proper long-term fix).

### Fix 0b: Surface `item/permissions/requestApproval` as approval interaction
**File:** `CodexNativeSessionController.swift` — `handleServerRequest` (~line 2165)
Instead of rejecting non-RP permission requests as unsupported, emit them as `.approvalRequest` so they surface through `mcpPendingInteraction` → `agent_run op=wait` → wrapper can respond.

### Fix 1: Send correct approval decisions to Codex
**File:** `CodexAgentModeCoordinator.swift` — `buildApprovalResult` method (~line 4780)
```swift
case .acceptForSession:
    decisionValue = "acceptForSession"
case .acceptWithExecpolicyAmendment(let amendment):
    if let data = amendment.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return ["decision": ["acceptWithExecpolicyAmendment": json]]
    }
    decisionValue = "acceptForSession" // fallback
```

### Fix 2: Auto-approve MCP tools with session persistence
**File:** `CodexAgentModeCoordinator.swift` — `buildAutoApprovalResponse` (~line 4769)
```swift
let label = question.options.first(where: { $0.label == "Allow for this session" })?.label
    ?? question.options.first?.label ?? "Allow"
```

### Fix 3: Show approval prompts for MCP sessions (or delay hiding 5s)
**File:** `AgentModeViewModel.swift` — `shouldSurfaceInteractionsInUI` (~line 686)

### Fix 4: Handle transport-close with pending approval
**File:** `CodexAgentModeCoordinator.swift` — transport-close handler (~line 3406)

### Fix 5: Reject dropped server requests in pre-bind buffer
**File:** `CodexNativeSessionController.swift` — `appendBufferedInbound` (~line 1218)

### Fix 6: Send cancel response when clearing pending approval
**File:** `AgentModeViewModel.swift` — `cancelPendingApproval` (~line 8162)

---

## Cascade Scenario (Confirmed)

The complete failure cascade that explains the user's experience:

1. MCP parent agent (e.g., Claude Code) spawns a Codex session via `agent_run.start`
2. Codex needs elevated access for iOS test command → sends `commandExecution/requestApproval`
3. RepoPrompt surfaces it as `AgentApprovalCard` (if not MCP-controlled) OR routes to parent agent (if MCP-controlled)
4. User/parent responds with "accept_for_session" or "always allow"
5. RepoPrompt correctly parses to `.acceptForSession` (AgentModeViewModel.swift:3780)
6. **BUG:** `buildApprovalResult` downgrades to `"accept"` (CodexAgentModeCoordinator.swift:4790)
7. Codex does one-time approval only — doesn't remember for session
8. Next similar command → Codex re-prompts
9. **If MCP-controlled:** prompt hidden from user (`shouldSurfaceInteractionsInUI == false`)
10. Parent agent must handle via `agent_run.respond` — if it's slow/distracted, session stalls
11. If transport hiccups during this waiting state → session permanently stranded (Bug 4)
12. Repeat until user gives up

The `agent_run.respond` → `submitApprovalDecision` → `buildApprovalResult` path was confirmed at AgentModeViewModel.swift:3798, meaning BOTH user UI clicks AND MCP parent agent responses are affected by the downgrade.

---

## Live Verification (via rp-cli-debug)

### Test 1: Simple `echo hello` — ✅ Completed without approval
- No sandbox issue for basic commands

### Test 2: `ls ~/Library/Developer/Xcode/DerivedData/` — ✅ Read succeeded
- `workspaceWrite` allows read access everywhere, writes only to writableRoots

### Test 3: `touch ~/Library/Developer/Xcode/DerivedData/test-file` — ✅ Approval surfaced!
- `agent_run op=wait` returned `waiting_for_input` with `interaction_id`
- Interaction kind: `approval`
- Codex detected the write was outside sandbox and requested approval
- After `decline`, command showed "Operation not permitted" as expected

### Analysis of OpenClaw's xcodebuild failure
The discrepancy between our test (approval surfaced for `touch`) and OpenClaw's report (no approval for `xcodebuild`) suggests one of:

1. **Codex's approval policy may handle `xcodebuild` differently** — it's a complex command that spawns subprocesses (xcodebuild → clang → ld, etc.) and they may fail inside the sandbox at subprocess level, with the parent `xcodebuild` returning a non-zero exit code. Codex may interpret this as "command failed" rather than "sandbox escape needed"

2. **Timing / race condition** — If the xcodebuild command starts running, Codex may have already committed to the sandbox. When internal writes fail, the error bubbles up as build failure rather than sandbox escape request

3. **The approval DOES surface but the wrapper misses it** — If the wrapper's `agent_run op=wait` timeout is too short, or if the approval appears briefly then gets auto-handled by another path (e.g., transport reconnect clears pending approval)

4. **The `onRequest` approval policy** only prompts for certain command patterns — Codex may auto-approve `xcodebuild` as a "known safe" command, then the sandbox restriction causes the actual failure

Most likely: **Scenario 1 or 2** — xcodebuild fails inside the sandbox and Codex reports it as a build error, not a sandbox escape request.

---

## Preventive Measures
1. Add unit tests for approval decision serialization → Codex protocol conformance
2. Add integration test verifying "Always Allow" → Codex receives `"acceptForSession"`
3. Add timeout/watchdog for pending approval states with no user interaction
4. Log and alert on pre-bind buffer overflows of server requests
5. Add MCP-controlled session interaction timeout with escalation to user UI
6. Consider adding common development tool paths (DerivedData, SwiftPM caches) to `writableRoots` for `workspaceWrite` sandbox
7. Implement `item/permissions/requestApproval` as a real approval surface (not just RP-only auto-approve)
