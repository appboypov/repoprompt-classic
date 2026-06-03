# Open-Source and Release Readiness Notes

Current as of 2026-06-01. Repo Prompt Classic is published as an archived educational snapshot intended to inspire forks, not as an actively supported upstream release. This contributor/maintainer inventory documents the snapshot's packaging state and remaining third-party notice follow-ups; it is not legal advice, a substitute for legal review, or a complete third-party dependency audit.

## Xcode project metadata and packaging

Classic builds from [`RepoPrompt.xcodeproj`](../RepoPrompt.xcodeproj) with the `RepoPrompt` scheme. The app target currently carries these maintainer-owned release values:

| Setting | Debug | Release |
| --- | --- | --- |
| Product name | `Repo Prompt` | `Repo Prompt` |
| Marketing version | `2.1.32` | `2.1.32` |
| Build number | `334` | `334` |
| Bundle identifier | `debug.pvncher.repoprompt` | `com.pvncher.repoprompt` |
| Signing mode | Xcode automatic local signing; ad-hoc identity (`-`) | Xcode automatic local signing; ad-hoc identity (`-`) |
| App deployment target | macOS `14.0` | macOS `14.0` |

The project-level and target-level deployment targets consistently advertise macOS `14.0`.

The checked-in project uses Xcode automatic local signing (`CODE_SIGN_STYLE = Automatic`) with no selected development team and blank provisioning profiles for app, test, and MCP executable targets. Its checked-in ad-hoc identity (`CODE_SIGN_IDENTITY = "-"`) retains deterministic zero-account local Sign to Run Locally behavior without requiring a developer-team account or provisioning profile. Treat bundle IDs and release channels as archived maintainer metadata. Forks that need a branded or distributable app should carry their own metadata and signing patch rather than guessing replacement values.

Ad-hoc signing is the portable zero-configuration archive default, not a stable distribution identity. macOS treats each rebuilt ad-hoc app as a version-specific code identity; see Apple's [TN3127: Inside Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). Both checked-in Debug and Release builds therefore use process-local volatile secure storage. API keys, secure permission documents, and bundle-verification cache values written in those launches disappear after relaunch and do not probe existing Keychain records.

Contributors who want privacy permissions to persist across rebuilds can create a local self-signed `Code Signing` certificate in Keychain Access following Apple's [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) guidance and pass its certificate name as a local `CODE_SIGN_IDENTITY` override. Do not commit a workstation-specific certificate name. A local self-signed identity still uses volatile secure storage: only positively verified Apple-anchored team-signed launches retain Classic's Keychain backend. Ad-hoc, local self-signed, missing, malformed, rejected, and uncertain signing evidence fails closed to process-local storage. Public distribution should use an appropriate Apple-issued identity and notarization workflow.

The app target's `Copy Legal Notices` shell build phase declares the canonical root [`LICENSE`](../LICENSE), [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md), and [`ThirdPartyLicenses/`](../ThirdPartyLicenses/) paths as inputs. It copies the root files into `Contents/Resources/Legal` and recursively replace-copies the curated directory into `Contents/Resources/Legal/ThirdPartyLicenses/` in built app bundles. This avoids duplicated source-of-truth content while bypassing the app target's broad Markdown resource exclusion. A normal Xcode build does not by itself create, notarize, staple, or publish a distribution artifact; any release/archive pipeline should verify that the bundled legal files remain present.

## Removed bundled external services

Classic no longer bundles Sparkle update delivery, Sentry remote logging, PostHog analytics/security-event reporting, GitHub OAuth or GitHub Models provider support, or benchmark submission. Local ad-hoc bundle-integrity verification and anti-debugging remain active, user-configured AI-provider networking remains available, and local benchmark execution/history/export/leaderboard behavior remains available.

Startup performs a narrow, idempotent cleanup of obsolete app-authored state plus audited SDK residue. It intentionally preserves generic shared cache parents and local security-hardening state. UserDefaults and filesystem cleanup always run, while deletion of the historical `GitHubToken` Keychain account is deferred in volatile mode and retried by a later positively verified Apple team-signed launch.

## Xcode SwiftPM pins

Xcode package references live in [`RepoPrompt.xcodeproj/project.pbxproj`](../RepoPrompt.xcodeproj/project.pbxproj), and the committed lockfile is [`RepoPrompt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`](../RepoPrompt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). The lockfile currently records 38 direct and transitive resolved pins. Most remote project constraints are version ranges with locked revisions. The following deterministic pins are notable for the archived snapshot:

| Dependency | Current Xcode project form | Current resolved state | Readiness note |
| --- | --- | --- | --- |
| `swift-sdk` | fixed revision at `https://github.com/provencher/swift-sdk.git` | `cb6a62f7c266ed535792b3e9e6e05dc3f0dac8e4` | Portable immutable remote pin; both MCP product dependencies use this package reference. |
| `SwiftTreeSitter` | exact version `0.8.0` | `2599e95310b3159641469d8a21baf2d3d200e61f` | Deterministic exact version; attribution curated. |
| `SwiftAnthropic` | fixed revision | `c069979c681de4434b6611c091c0cab01f141213` | Immutable revision pin. |
| `SwiftOpenAI` | fixed revision | `1211782eb337e7968124448a20d9260df1952012` | Immutable revision pin for the required fork snapshot. |
| `tree-sitter-swift` | fixed revision | `9253825dd2570430b53fa128cbb40cb62498e75d` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-cpp` | fixed revision | `e5cea0ec884c5c3d2d1e41a741a66ce13da4d945` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-c-sharp` | fixed revision | `b27b091bfdc5f16d0ef76421ea5609c82a57dff0` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-typescript` | fixed revision | `75b3874edb2dc714fb1fd77a32013d0f8699989f` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-c` | fixed revision | `3efee11f784605d44623d7dadd6cd12a0f73ea92` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-dart` | fixed revision | `80e23c07b64494f7e21090bb3450223ef0b192f4` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-go` | fixed revision | `c350fa54d38af725c40d061a602ee3205ef1e072` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-java` | fixed revision | `e10607b45ff745f5f876bfa3e94fbcc6b44bdc11` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-javascript` | fixed revision | `39798e26b6d4dbcee8e522b8db83f8b2df33a5ea` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-python` | fixed revision | `c5fca1a186e8e528115196178c28eefa8d86b0b0` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-rust` | fixed revision | `2eaf126458a4d6a69401089b6ba78c5e5d6c1ced` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-php` | fixed revision | `0a99deca13c4af1fb9adcb03c958bfc9f4c740a9` | Immutable from SwiftPM's perspective; attribution curated. |
| `tree-sitter-ruby` | fixed revision | `7a010836b74351855148818d5cb8170dc4df8e6a` | Immutable from SwiftPM's perspective; attribution curated. |

All directly linked Tree-sitter grammar package references now use source-preserving exact revision pins, and `SwiftTreeSitter` uses an exact `0.8.0` constraint. The curated [`ThirdPartyLicenses/tree-sitter/`](../ThirdPartyLicenses/tree-sitter/) bundle maps those pins plus `SwiftTreeSitter`, its embedded runtime, and the runtime ICU subset notice. Keep `Package.resolved` committed so local and CI resolutions match unless maintainers intentionally update dependencies. `TPObfuscation` remains linked only for the local `SecureKeysService` bundle-verification account key; it is not used for an embedded external-service credential. Notice curation must cover direct and transitive packages, not only the project references listed above.

Clean Xcode SwiftPM resolutions compile the exact-pinned upstream JavaScript and Python parser objects but omit their external-scanner objects. Classic therefore carries the narrow app-integrated [`RepoPrompt/Support/C/TreeSitterScannerSupport`](../RepoPrompt/Support/C/TreeSitterScannerSupport/) compatibility subtree: byte-for-byte exact-snapshot copies of only those two upstream scanner implementations and their required helper headers. [`ThirdPartyLicenses/tree-sitter/scanner-support.sha256`](../ThirdPartyLicenses/tree-sitter/scanner-support.sha256) records the copied-file checksums, and `TreeSitterScannerSupportAuditTests` guards the narrow layout. Remove the support subtree, guardrail test, checksums, and documentation exception together only after validated upstream revisions or Xcode SwiftPM behavior compile the scanners directly from the dependency products in a clean graph.

## Third-party license/notice inventory

Contributor-visible license expectations before public distribution:

| Component | Location | Current notice source | Follow-up |
| --- | --- | --- | --- |
| UniversalCharsetDetection / uchardet | Xcode SwiftPM package, resolved to `1.0.0` | Upstream package repository | Include the applicable upstream notices and transitive uchardet attribution in release acknowledgements. |
| PCRE2 | `RepoPrompt/Infrastructure/Regex/CSwiftPCRE2/src` | License headers are present in bundled PCRE2 sources such as `pcre2.h`. | Preserve source headers, record exact upstream provenance, and include PCRE2 notices in release acknowledgements. The checked-in header identifies `10.48-DEV` dated `2025-10-21`, not a stable release tag. |
| SLJIT | `RepoPrompt/Infrastructure/Regex/CSwiftPCRE2/deps/sljit` | `LICENSE` and `README.md` identify the bundled SLJIT license. | Preserve source headers and include SLJIT notices in release acknowledgements. |
| wildmatch / OpenBSD-derived fnmatch material | `RepoPrompt/Support/C/wildmatch/wildmatch.c`, `RepoPrompt/Support/C/wildmatch/wildmatch.h` | Both checked-in files contain BSD-style notice blocks; `wildmatch.h` includes its existing advertising acknowledgement condition. | Source headers remain preserved. Their full checked-in notice text is reproduced in root `THIRD_PARTY_NOTICES.md` and bundled under `Contents/Resources/Legal` during app builds. |
| Tree-sitter grammar packages, `SwiftTreeSitter`, embedded runtime, and runtime ICU subset | `RepoPrompt.xcodeproj/project.pbxproj`, `RepoPrompt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, [`ThirdPartyLicenses/tree-sitter/`](../ThirdPartyLicenses/tree-sitter/) | The curated Tree-sitter README maps exact package/runtime pins to full copied license files, including the embedded ICU subset notice. | Included under `Contents/Resources/Legal/ThirdPartyLicenses/tree-sitter/` during app builds. |
| SwiftPCRE2 wrapper code | `RepoPrompt/ThirdParty/SwiftPCRE2` | Wrapper Swift sources are checked in without a top-level attribution inventory in this checkout. | Verify provenance and whether separate attribution is required. |
| Xcode SwiftPM dependencies | `RepoPrompt.xcodeproj/project.pbxproj`, `RepoPrompt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Upstream packages provide their own license files in their repositories. | Generate or curate a comprehensive third-party notice inventory for direct and transitive dependencies. |

Also verify whether checked-in assets, icons, prompts, fixtures, and other copied or generated sources require separate attribution.

The root [`LICENSE`](../LICENSE) provides the Apache License, Version 2.0 for original Repo Prompt Classic code; it does not relicense third-party material. The app's legal-notices build phase packages that root license alongside the root [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) and curated [`ThirdPartyLicenses/`](../ThirdPartyLicenses/) directory. `THIRD_PARTY_NOTICES.md` is intentionally labeled as a partial inventory: it records the checked-in wildmatch notice material and points to the curated Tree-sitter attribution bundle, while notice curation for the other third-party dependencies listed above remains outstanding before public distribution.

## Contributor validation touchpoints

For Xcode project packaging changes, run:

```bash
xcodebuild -project RepoPrompt.xcodeproj -scheme RepoPrompt -configuration Debug build
APP_PATH="$(xcodebuild -project RepoPrompt.xcodeproj -scheme RepoPrompt -configuration Debug -showBuildSettings | awk -F ' = ' '/TARGET_BUILD_DIR/ { dir=$2 } /FULL_PRODUCT_NAME/ { name=$2 } END { print dir "/" name }')"
```

Then verify the built debug app contains byte-for-byte copies of the canonical root files:

```bash
cmp LICENSE "$APP_PATH/Contents/Resources/Legal/LICENSE"
cmp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/Legal/THIRD_PARTY_NOTICES.md"
diff -r ThirdPartyLicenses "$APP_PATH/Contents/Resources/Legal/ThirdPartyLicenses"
shasum -a 256 -c ThirdPartyLicenses/tree-sitter/scanner-support.sha256
```

When changes touch runtime behavior, MCP behavior, CLI behavior, or dependencies, follow the targeted build/test and live-smoke guidance in [`AGENTS.md`](../AGENTS.md).
