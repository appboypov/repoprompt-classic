# Tree-sitter Attribution Bundle

Repo Prompt Classic links Tree-sitter grammar package products and the `SwiftTreeSitter` wrapper/runtime through its Xcode SwiftPM dependency graph. This directory contains curated license copies for those components.

The newly migrated grammar dependencies below use source-preserving SwiftPM revision pins: the selected upstream snapshots retain generated parser source and their license files. A source-preserving pin improves reproducibility, but package dependencies still require attribution when distributed.

## Newly migrated grammar packages

| Grammar | Upstream repository | Exact revision | SwiftPM product | License copy |
| --- | --- | --- | --- | --- |
| C | <https://github.com/tree-sitter/tree-sitter-c> | `3efee11f784605d44623d7dadd6cd12a0f73ea92` | `TreeSitterC` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| Dart | <https://github.com/UserNobody14/tree-sitter-dart> | `80e23c07b64494f7e21090bb3450223ef0b192f4` | `TreeSitterDart` | [`LICENSE-tree-sitter-dart.txt`](LICENSE-tree-sitter-dart.txt) |
| Go | <https://github.com/tree-sitter/tree-sitter-go> | `c350fa54d38af725c40d061a602ee3205ef1e072` | `TreeSitterGo` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| Java | <https://github.com/tree-sitter/tree-sitter-java> | `e10607b45ff745f5f876bfa3e94fbcc6b44bdc11` | `TreeSitterJava` | [`LICENSE-tree-sitter-java.txt`](LICENSE-tree-sitter-java.txt) |
| JavaScript | <https://github.com/tree-sitter/tree-sitter-javascript> | `39798e26b6d4dbcee8e522b8db83f8b2df33a5ea` | `TreeSitterJavaScript` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| Python | <https://github.com/tree-sitter/tree-sitter-python> | `c5fca1a186e8e528115196178c28eefa8d86b0b0` | `TreeSitterPython` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |
| Rust | <https://github.com/tree-sitter/tree-sitter-rust> | `2eaf126458a4d6a69401089b6ba78c5e5d6c1ced` | `TreeSitterRust` | [`LICENSE-tree-sitter-rust.txt`](LICENSE-tree-sitter-rust.txt) |

The license text for all seven grammars above was copied from the corresponding exact upstream snapshots. The C, Go, and JavaScript snapshots contain identical MIT license text, so they intentionally share one copy.

## Other linked grammar packages

These fixed-revision grammar products were already linked by the app. Their license copies are included here so the packaged Tree-sitter attribution bundle covers the directly linked grammar set.

| Grammar | Upstream repository | Exact revision | SwiftPM product (modules where useful) | License copy |
| --- | --- | --- | --- | --- |
| C# | <https://github.com/tree-sitter/tree-sitter-c-sharp.git> | `b27b091bfdc5f16d0ef76421ea5609c82a57dff0` | `TreeSitterCSharp` | [`LICENSE-tree-sitter-c-sharp.txt`](LICENSE-tree-sitter-c-sharp.txt) |
| C++ | <https://github.com/tree-sitter/tree-sitter-cpp> | `e5cea0ec884c5c3d2d1e41a741a66ce13da4d945` | `TreeSitterCPP` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| PHP | <https://github.com/provencher/tree-sitter-php> | `0a99deca13c4af1fb9adcb03c958bfc9f4c740a9` | `TreeSitterPHP` | [`LICENSE-tree-sitter-php.txt`](LICENSE-tree-sitter-php.txt) |
| Ruby | <https://github.com/tree-sitter/tree-sitter-ruby> | `7a010836b74351855148818d5cb8170dc4df8e6a` | `TreeSitterRuby` | [`LICENSE-tree-sitter-ruby.txt`](LICENSE-tree-sitter-ruby.txt) |
| Swift | <https://github.com/alex-pinkus/tree-sitter-swift> | `9253825dd2570430b53fa128cbb40cb62498e75d` | `TreeSitterSwift` | [`LICENSE-tree-sitter-swift.txt`](LICENSE-tree-sitter-swift.txt) |
| TypeScript / TSX | <https://github.com/tree-sitter/tree-sitter-typescript> | `75b3874edb2dc714fb1fd77a32013d0f8699989f` | `TreeSitterTypeScript` (`TreeSitterTypeScript`, `TreeSitterTSX` modules) | [`LICENSE-tree-sitter-typescript.txt`](LICENSE-tree-sitter-typescript.txt) |

The C++ snapshot contains the same MIT license text as the C, Go, and JavaScript snapshots, so it intentionally uses the shared copy.

## JavaScript and Python scanner linker compatibility snapshots

Clean Xcode SwiftPM resolutions compile the exact-pinned upstream JavaScript and Python parser objects but omit their external-scanner objects. Repo Prompt Classic therefore carries a narrow app-integrated `RepoPrompt/Support/C/TreeSitterScannerSupport` C compatibility subtree containing byte-for-byte copies of only the missing upstream scanner implementations and their required helper headers. The upstream package URLs, revisions, and products remain unchanged.

| Classic source path | Exact upstream snapshot source | Applicable license copy |
| --- | --- | --- |
| `RepoPrompt/Support/C/TreeSitterScannerSupport/src/javascript/scanner.c` | `tree-sitter-javascript/src/scanner.c` at `39798e26b6d4dbcee8e522b8db83f8b2df33a5ea` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| `RepoPrompt/Support/C/TreeSitterScannerSupport/src/python/scanner.c` | `tree-sitter-python/src/scanner.c` at `c5fca1a186e8e528115196178c28eefa8d86b0b0` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |
| `RepoPrompt/Support/C/TreeSitterScannerSupport/include/tree_sitter/parser.h` | Byte-identical in both exact snapshots above | Same grammar license copies above |
| `RepoPrompt/Support/C/TreeSitterScannerSupport/include/tree_sitter/array.h` | `tree-sitter-python/src/tree_sitter/array.h` at `c5fca1a186e8e528115196178c28eefa8d86b0b0` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |
| `RepoPrompt/Support/C/TreeSitterScannerSupport/include/tree_sitter/alloc.h` | `tree-sitter-python/src/tree_sitter/alloc.h` at `c5fca1a186e8e528115196178c28eefa8d86b0b0` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |

[`scanner-support.sha256`](scanner-support.sha256) records the copied-file checksums. Remove this compatibility subtree, its checksum file, guardrail test, and documentation exception together only after validated upstream revisions or SwiftPM behavior compile the scanner objects directly from the dependency products in a clean Xcode graph.

## Swift wrapper, embedded runtime, and ICU subset

The `SwiftTreeSitter` package includes the C Tree-sitter runtime as a submodule and compiles its `tree-sitter/lib` target. That runtime snapshot includes a small subset of ICU headers and the corresponding full ICU notice file.

| Component | Source | Resolved revision | License copy |
| --- | --- | --- | --- |
| `SwiftTreeSitter` (`0.8.0`) | <https://github.com/ChimeHQ/SwiftTreeSitter.git> | `2599e95310b3159641469d8a21baf2d3d200e61f` | [`LICENSE-SwiftTreeSitter.txt`](LICENSE-SwiftTreeSitter.txt) |
| Embedded Tree-sitter runtime | <https://github.com/tree-sitter/tree-sitter.git> | `0c49d6745b3fc4822ab02e0018770cd6383a779c` | [`LICENSE-tree-sitter-runtime.txt`](LICENSE-tree-sitter-runtime.txt) |
| ICU subset embedded by that runtime | <https://github.com/unicode-org/icu> | `552b01f61127d30d6589aa4bf99468224979b661` recorded by the runtime's `ICU_SHA` | [`LICENSE-tree-sitter-runtime-ICU.txt`](LICENSE-tree-sitter-runtime-ICU.txt) |

The ICU file is preserved in full because it contains the applicable ICU copyright and permission notice plus additional third-party notices.
