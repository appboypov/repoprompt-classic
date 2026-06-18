---
conversation-id: c1849158-a5c0-4228-aaad-73740245200d
---

# Session: 2026-06-18

**Started:** ~08:00
**Last Updated:** 08:52
**Project:** repoprompt-classic
**Topic:** Recreate the CE local-build/launch/key workflow for the classic repo as `rpc`-prefixed aliases; build, install, and key-seed a separate classic Debug app.

---

## What We Are Building

Self-contained zsh workflow to build the local RepoPrompt **classic** fork from source, run it as a separate app alongside the paid Repo Prompt, and reuse existing API keys. Continuation of prior CE session (CE rejected — no manual prompt composer; classic has it).

Delivered three aliases (`rpc`, `rpcbuild`, `rpcdev`) plus a one-time API-key seed. The classic Debug build runs under its own bundle id (`debug.pvncher.repoprompt`) and app name, but shares settings/workspaces/prompts live with the paid app (user's explicit choice).

---

## What WORKED (with evidence)

- **Classic Debug build, Developer ID signed** — confirmed by: `xcodebuild ... CODE_SIGN_IDENTITY="Developer ID Application: Brian Manuputty (QL45N6CUB5)"` → `** BUILD SUCCEEDED **`, 0 errors; `codesign -dvvv` shows `Authority=Developer ID Application`, `TeamIdentifier=QL45N6CUB5`, `flags=0x10000(runtime)`, not ad-hoc, `Identifier=debug.pvncher.repoprompt`.
- **Persistent keychain eligibility** — confirmed by: `codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "QL45N6CUB5"'` → exit 0 (PASS). Matches `SecureStorageRuntimePolicy.backendKind` requirement → persistent keychain, not ephemeral.
- **Install isolated from paid app** — confirmed by: installed `/Applications/Repo Prompt Classic.app`; `/Applications/Repo Prompt.app` still present.
- **API key seed** — confirmed by: `/tmp/rpc-seed-keys.sh` copied 5 keys, read-back under `debug.pvncher.repoprompt.keychain` returned correct prefixes: AnthropicAPI `sk-ant…`, OpenAIAPI `sk-pro…`, GeminiAPI `AIzaSy…`, DeepSeekAPI `sk-eca…`, GitHubToken `Z2hvX0…`.
- **Classic app launches** — confirmed by: `ps aux` shows `/Applications/Repo Prompt Classic.app/Contents/MacOS/Repo Prompt` running after `open -a`.

## Key facts re-derived for classic (vs CE)

- **Keychain service** = `<bundleId>.keychain` (`KeychainService.swift:20-24`). Debug → `debug.pvncher.repoprompt.keychain` (isolated); Release → `com.pvncher.repoprompt.keychain` (== commercial).
- **API keys are PLAIN UTF-8** — `SecureKeyService.swift:25-31` uses `withIntegrityProtection: false` / `verifyIntegrity: false`. Integrity HMAC (`KeychainService` install-bound secret) only guards license/bundle-verification items, NOT keys → plain `security -w` copy is safe.
- **Settings/workspaces/prompts shared** — app NOT sandboxed (`RepoPrompt/RepoPrompt.entitlements` = allow-jit + app-scope bookmarks only, no app-sandbox; no `~/Library/Containers` dir). Storage hardcoded to `~/Library/Application Support/RepoPrompt/` by name, not bundle id → debug build shares live with paid app. No seed needed.
- **Persistent-keychain gate** (`SecureKeyValueStorageBackend.swift:17-29`, `RuntimeCodeSigningDetector.swift:54-76`): requires valid 10-char Apple team, non-ad-hoc, `anchor apple generic and certificate leaf[subject.OU]==teamID`. NOT a hardcoded team allowlist (unlike CE). Any genuine Apple Development or Developer ID cert qualifies.
- **Provider key identifiers** (`KeyManager.swift:44-67`): 17 `AIProviderType.secureIdentifier` values + GitHubToken/accessToken. User has 5 populated.

---

## What Did NOT Work (and why)

- **Apple Development cert signing** — failed because: `xcodebuild ... CODE_SIGN_IDENTITY="Apple Development: Brian Manuputty (47JV6BCQG7)"` → "No certificate for team '47JV6BCQG7' matching ... found" on every SPM target. Apple Dev certs need the team registered in Xcode provisioning; manual signing couldn't resolve it. Fixed by switching to Developer ID Application (QL45N6CUB5), which needs no provisioning profile and is uniquely named.
- **First background build "exit 0" was misleading** — the wrapper script's `tail` returned 0 while `xcodebuild` itself failed. Check `** BUILD SUCCEEDED/FAILED **` in the log, not the task exit code.

---

## Current State of Files

| File | Status | Notes |
| ---- | ------ | ----- |
| `~/.zshrc` | ✅ Complete | Added `RPC_REPO`/`RPC_APP`/`RPC_SIGN_IDENTITY`/`RPC_TEAM`, `_rpc_product`, `rpc`, `rpcbuild`, `rpcdev` after `rp()`. Backup `~/.zshrc.bak.1781764548`. |
| `/tmp/rpc-seed-keys.sh` | ✅ Complete | One-time key seed (allowlist of 19 plain accounts, `-T` ACL). Throwaway, not an alias. |
| `/Applications/Repo Prompt Classic.app` | ✅ Installed | Classic Debug, Developer ID signed, persistent keychain verified. |
| `debug.pvncher.repoprompt.keychain` (login keychain) | ✅ Seeded | 5 keys copied + verified. |

No classic repo source files modified.

---

## Decisions Made

- **Debug build as separate identity** — reason: own bundle id → isolated keychain; user wants to test before promoting.
- **Developer ID cert (QL45N6CUB5)** — reason: Apple Dev cert failed provisioning; Developer ID needs no profile, satisfies persistent-keychain requirement.
- **Install as `Repo Prompt Classic.app`** — reason: product name "Repo Prompt" collides with paid app; rename on copy avoids clobbering, bundle id stays distinct.
- **No `rpcsync` alias; seed keys once** — user directive: settings/workspaces/prompts already shared, only keys need seeding.
- **Share settings/workspaces/prompts live with paid app** — user explicit choice ("let it share live", "exactly what i want"); accepted concurrent-write risk.
- **`rpc` uses `open -a "$RPC_APP" "repoprompt://open/<path>"`** — targets classic app explicitly since both share the `repoprompt://` scheme.
- **Did NOT touch `~/.codex/config.toml`; kept `rp` intact** — carried from prior session.

---

## Blockers & Open Questions

- **`rpc` deep-link routing unconfirmed** — both apps own `repoprompt://`; folder may open in the paid app instead of classic. Needs visual confirmation; if wrong, force classic instance.
- **Visual confirmation pending** — user to confirm classic build shows the manual prompt composer and that API keys appear populated in settings.
- **Concurrent-run risk** — paid app + classic build share data files; running both simultaneously can clobber workspace/settings. Both currently running from launch test.
- **CE leftovers** — `/Applications/RepoPrompt CE.app` + its Application Support + CE keychain items + self-signed cert still on disk from prior session; wipe pending user approval.

---

## Tools Used This Session

**Skills:**
- `/load`, `/kiss`, `/save` — invoked by user.

**MCP tools:**
- None (RepoPrompt MCP deferred; used Bash grep/find instead).

**CLI tools:**
- `xcodebuild` — build + `-showBuildSettings` product path resolution.
- `codesign` — signature inspection + requirement verification.
- `security` — keychain enumerate/find/add for key seed + `-T` ACL.
- `git`, `grep`, `find`, `awk`, `PlistBuddy` — investigation.

---

## Files Referenced

- `docs/sessions/2026-06-18-02-44-classic-local-build-aliases-session.md` — prior CE session, loaded as entry point.
- `RepoPrompt/Infrastructure/Security/{KeychainService,SecureKeyService,SecureKeyValueStorageBackend,RuntimeCodeSigningDetector,KeyManager}.swift` — keychain service naming, plain-key storage, persistent-keychain gate, provider identifiers.
- `RepoPrompt/RepoPrompt.entitlements` — confirmed no app-sandbox (shared Application Support).
- `RepoPrompt.xcodeproj/project.pbxproj` — bundle ids, default ad-hoc signing.
- `AGENTS.md` — xcodebuild build/launch commands.
