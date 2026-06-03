# Historical AgentSession Audit Corpus v1

This directory contains a small, redacted, minimized corpus of historical `AgentSession` JSON fixtures for transcript correctness and payload-quality regressions.

## Contents

- `manifest.json` — parseable provenance, issue labels, minimization notes, and expected metrics.
- `sessions/*.min.json` — minimized session fixtures. These are not raw Application Support sessions.

## Redaction/minimization policy

The fixtures preserve structural signal needed by transcript metrics:

- provider/`agentKind` and run state;
- turn/span/activity ordering and original `sequenceIndex` values;
- `itemKind`, `role`, tool names, tool statuses, terminal state, and `conclusionActivityID` relationships;
- deterministic invocation-ID equivalence classes, including the Gemini duplicate invocation case;
- exact pathological assistant texts: `"\n\n\n"`, `""`, `"."`, and `"resumed after stop"`.

The fixtures intentionally redact or replace:

- user prompts and non-essential assistant prose;
- source code, full file contents, search output, bash output, and huge payloads;
- provider session IDs and local absolute paths;
- provider/user-specific UUIDs, remapped deterministically per fixture.

Original source file hashes, byte counts, and source/original payload metrics live in `manifest.json`. Do not add raw full historical sessions or raw tool payloads to this directory; persisted tool data must be summary-only.

The corpus policy in `manifest.json` uses `maxPersistedToolSummaryBytes` for compact persisted summaries only. It is not a raw payload allowance: raw file contents, search results, bash output, patches, and per-file tool arrays should never be committed even when they are below that byte budget.

## Deferred samples and future work

Some baseline or label-only samples from the Oracle plan are explicitly deferred in `manifest.json` when a distinct clean source filename was not resolved or when v1 already covers the provider/issue class with a smaller representative fixture.

Batch 6 intentionally leaves the following P2/future-work areas non-blocking for the v1 gates:

- **Assistant micro-noise provider policy** — `codex-dot-assistant-dcc3d87f` preserves `"."` as displayable assistant text and records `assistantMicroNoiseCount` diagnostically. Do not globally suppress punctuation-like assistant rows without provider-specific evidence.
- **Thinking/reasoning persistence policy** — Codex/Gemini fixtures can expose persisted thinking rows, but v1 gates only P0/P1 correctness, no-raw-tool-payload persistence, and compact summary budgets. A future policy should decide which reasoning rows remain useful in committed session storage.
- **Subjective transcript quality scoring** — metrics such as low-substantive final answers, information density, and summary adequacy are review aids, not hard correctness gates. `opencode-concise-final-e181fce3` keeps `"resumed after stop"` exportable.
- **Clean baseline fixture expansion** — add provider-clean baselines after distinct source sessions are available; keep those fixtures minimized and redacted like the current corpus.
