# Transcript-collapse fixture: ACP steering coalesce (minimized)

## Purpose

Regression fixture for the long-thread transcript over-compression bug where
repeated compaction cycles collapsed all but the very last turn to summary/archived,
breaking tool-call-anchored tail retention: the suffix beginning at the earliest
of the last 8 visible tool executions plus surrounding/intervening context.

## Regression shape preserved

- 39 turns, transcript version 3.
- Compaction frontier: `frozenPrefixTurnCount: 38`, `lastFrozenTurnID` matches turn 37.
- Retention tiers: 6 archived (turns 0–5), 32 summary (turns 6–37), 1 full (turn 38).
- Only the final turn retains inline activities; all earlier spans are structurally trimmed.
- Summary and collapsedSummary structures present on compacted turns (mix of patterns).
- `nextSequenceIndex = 50`.

## Fixture details

- **Minimized**: Synthetic deterministic UUIDs and timestamps. No user content, local
  paths, or debug data. Generated programmatically to match the structural fingerprint
  of the original `AgentSession-A4B8CF7F-ED12-494C-ABED-4F3840E9318E.json` session.
- **Decodes as**: `AgentSession` (serializationVersion 4).
- **Size**: ~52 KB.

## Original source

Derived from session `ACP steering coalesce` (ID `A4B8CF7F`) in
`Workspace-RepoPrompt-AFF2A12B-2965-4426-9FE5-4494D4534204`. The original session
was a 39-turn codexExec (GPT-5.5 Codex) session with 89M total tokens that exhibited
the over-compression bug in production use.
