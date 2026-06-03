# Repo Prompt Classic

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Repo Prompt Classic is an archived educational snapshot of the Repo Prompt app currently available to download. This source release is intended to preserve a useful reference and inspire forks.

For ongoing open-source development, see [RepoPrompt CE](https://github.com/repoprompt/repoprompt-ce). RepoPrompt CE removed substantial legacy code, especially around IDE Mode, to remove main-thread bottlenecks and scale many parallel agents. Classic and CE are separate codebases; this archive does not claim feature parity with CE.

## Build and launch

Requirements:

- macOS 26 or later
- Xcode 26 or later

Repo Prompt Classic requires macOS 26 and Xcode 26 to build. Earlier macOS and Xcode releases are not supported.

Build and open the debug app with native Xcode tooling. The checked-in project uses Xcode automatic local signing with no selected development team and retains an ad-hoc identity (`-`) for zero-account local builds, so a developer-team account or provisioning profile is not required:

In Xcode, select the `RepoPrompt` scheme for the normal macOS app build and run. The `repoprompt-mcp` scheme builds the standalone CLI.

```bash
xcodebuild -project RepoPrompt.xcodeproj -scheme RepoPrompt -configuration Debug build
APP_PATH="$(xcodebuild -project RepoPrompt.xcodeproj -scheme RepoPrompt -configuration Debug -showBuildSettings | awk -F ' = ' '/TARGET_BUILD_DIR/ { dir=$2 } /FULL_PRODUCT_NAME/ { name=$2 } END { print dir "/" name }')"
open "$APP_PATH"
```

### Optional stable local signing identity

The checked-in automatic local signing configuration intentionally uses a zero-configuration ad-hoc signature, but macOS treats each rebuilt ad-hoc app as a new code identity, as described in Apple's [TN3127: Inside Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). Both checked-in Debug and Release builds therefore use process-local volatile secure storage. API keys and secure permission changes made in those builds disappear after relaunch.

If you work on Classic regularly and want privacy permissions to remain stable across rebuilds, create a local self-signed code-signing certificate in Keychain Access using Apple's [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) guidance:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Choose **Self Signed Root** as the identity type and **Code Signing** as the certificate type.
3. Build with that local certificate name as an override:

```bash
xcodebuild \
  -project RepoPrompt.xcodeproj \
  -scheme RepoPrompt \
  -configuration Debug \
  CODE_SIGN_IDENTITY="Repo Prompt Local Development" \
  build
```

Do not commit a workstation-specific certificate name. A local self-signed certificate may stabilize macOS privacy permissions, but it does **not** enable persistent secure storage. Classic uses macOS Keychain only when runtime evidence positively verifies a properly Apple-anchored team signature; ad-hoc, local self-signed, missing, malformed, rejected, and uncertain signing evidence remains volatile. For distribution, replace the local signing override with an appropriate Apple-issued signing identity and notarization workflow.

## Archive status

This repository is archived and provided without support. Forks are encouraged; upstream issues and pull requests are not actively reviewed.

## Contributor documentation

- [`AGENTS.md`](AGENTS.md): repository structure, native build commands, validation guidance, and parallel-agent safety
- [`CONTRIBUTING.md`](CONTRIBUTING.md): archive contribution policy
- [`SECURITY.md`](SECURITY.md): security policy for this archived snapshot
- [`docs/open-source-readiness.md`](docs/open-source-readiness.md): packaging and third-party notice inventory

## License

Original Repo Prompt Classic code is licensed under [Apache-2.0](LICENSE). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`ThirdPartyLicenses/`](ThirdPartyLicenses/) for the current partial third-party notice inventory.
