# Architecture

Repo Prompt Classic is a native macOS application (SwiftUI + AppKit) that builds curated codebase context for LLMs, runs agentic coding sessions across multiple AI providers, and embeds an MCP server so external agents and a bundled CLI can drive the app. This document inventories the system's components, their relationships, and the conventions that bind them, so a spec can be written without reading the source.

The repository contains four targets:

- **RepoPrompt** (`RepoPrompt/`) — the macOS app.
- **repoprompt-mcp** (`repoprompt-mcp/`) — a standalone CLI client that speaks MCP to the running app.
- **RepoPromptTests** / **RepoPromptUITests** — XCTest suites.

## Technology Stack

| Technology | Version | Purpose |
| --- | --- | --- |
| Swift | 5.0 | Implementation language (tab indentation) |
| SwiftUI + AppKit | macOS SDK | UI layer; SwiftUI scenes/views over AppKit `NSViewController`/`NSWindow` for performance-critical surfaces |
| macOS deployment target | 14.0 | `MACOSX_DEPLOYMENT_TARGET`; building from source requires macOS 26 / Xcode 26 (see `README.md`) |
| swift-sdk (MCP) | `cb6a62f7` | Model Context Protocol server/client runtime |
| SwiftAnthropic | `c069979c` | Anthropic API provider |
| SwiftOpenAI | `1211782e` | OpenAI-compatible API providers |
| SwiftTreeSitter + Neon | 0.8.0 / 0.6.0 | Incremental parsing and syntax highlighting |
| tree-sitter grammars | pinned revisions | c, cpp, c-sharp, dart, go, java, javascript, php, python, ruby, rust, swift, typescript |
| Highlightr | 2.2.1 | Fallback syntax highlighting |
| swift-markdown-ui / swift-markdown / swift-cmark | 2.4.1 / 0.6.0 / 0.6.0 | Markdown rendering and AST |
| SwiftyJSON | 5.0.2 | JSON traversal |
| JSONSchema | 1.3.0 | MCP tool schema definition/validation |
| ontology | 0.6.0 | Structured value/entity modeling for MCP |
| swift-nio | 2.100.0 | Networking primitives (sockets, transports) |
| swift-service-lifecycle | 2.8.0 | Service startup/shutdown orchestration |
| swift-async-algorithms / swift-collections / swift-atomics / swift-system | 1.0.4 / 1.2.0 / 1.3.0 / 1.6.4 | Concurrency and data-structure primitives |
| swift-log | 1.6.3 | Logging facade (`RepoPromptFileLogHandler`) |
| KeyboardShortcuts | 2.3.0 | Global keyboard shortcut registration |
| eventsource | 1.4.1 | Server-sent events for streaming providers |
| networkimage | 6.0.1 | Async image loading in markdown |
| rearrange | 1.8.1 | Text range arithmetic (TextKit) |
| UniversalCharsetDetection | 1.0.0 | File encoding detection |
| TPObfuscation | 1.1.1 | String obfuscation for secrets/keys |
| CSwiftPCRE2 (vendored) | bundled | PCRE2 regex engine with JIT (`Infrastructure/Regex/CSwiftPCRE2`, `ThirdParty/SwiftPCRE2`) |
| TreeSitterScannerSupport / wildmatch (vendored C) | bundled | Custom tree-sitter scanners and glob matching (`Support/C`) |

## Project Structure

```
repoprompt-classic/
├── RepoPrompt/                    # macOS app target
│   ├── App/                       # App lifecycle, windows, deep links, global shortcuts, notifications
│   │   ├── Notifications/         # In-app + system notification services
│   │   ├── ViewModels/            # ContentViewModel (per-window root VM)
│   │   └── Views/                 # ContentView root scene
│   ├── Features/                  # Feature modules (MVVM), one folder per domain
│   │   ├── AgentMode/             # Agentic coding sessions (largest feature)
│   │   │   ├── Models/            # Session, transcript, model-selection models
│   │   │   ├── Recommendations/   # Auto-recommendation engine
│   │   │   ├── Runtime/           # Session execution, provider coordinators, runners, usage
│   │   │   ├── ViewModels/        # AgentModeViewModel (+ extensions), UI stores
│   │   │   └── Views/             # Transcript, tool cards, sidebar, titlebar
│   │   ├── AIQuery/               # One-shot AI query/response surface
│   │   ├── Chat/                  # Conversational chat with file diffs
│   │   ├── CodeMap/               # Code structure extraction (signatures/codemaps)
│   │   ├── ContextBuilder/        # Autonomous context-building agent
│   │   ├── Diagnostics/           # Benchmark harness, perf diagnostics, stress tests
│   │   ├── Diff/                  # Diff review UI
│   │   ├── Prompt/                # Prompt assembly, copy presets, token counting
│   │   ├── Search/                # File-tree search
│   │   ├── Settings/              # Settings documents, managers, and views
│   │   ├── WorkspaceFiles/        # File tree, selection, git status UI
│   │   └── Workspaces/            # Workspace/preset management and switching
│   ├── Infrastructure/            # Cross-cutting services and engines
│   │   ├── AI/                    # Providers, model catalog, prompts, agents, ACP
│   │   ├── Concurrency/           # AsyncMutex, AsyncScope, TaskSemaphore
│   │   ├── Diffing/               # Diff parsing/generation/application
│   │   ├── FileSystem/            # File scanning, ignore rules, caching
│   │   ├── MCP/                   # Embedded MCP server, tool services, policies, routing
│   │   ├── Networking/            # HTTP client/decoding
│   │   ├── Persistence/           # Preset file stores, state cleanup
│   │   ├── Process/               # CLI process launching, env, PATH resolution
│   │   ├── Regex/                 # PCRE2 adapter + vendored engine
│   │   ├── Security/              # Keychain, secure storage, signing detection, obfuscation
│   │   ├── SyntaxParsing/         # Tree-sitter queries + highlighter
│   │   ├── UI/                    # Reusable components, markdown, mentions, TextKit fields
│   │   ├── Utilities/             # Extensions, path helpers, collections
│   │   ├── VCS/                   # Git/Jujutsu backends, git diff engine
│   │   └── WorkspaceContext/      # Indexing, path lookup, search, slices, token accounting
│   ├── Shared/                    # MCP constants/messages shared with the CLI target
│   ├── Support/C/                 # Vendored C: tree-sitter scanners, wildmatch, utils
│   └── ThirdParty/SwiftPCRE2/     # Vendored PCRE2 Swift wrapper
├── repoprompt-mcp/                # CLI client target
│   ├── CommandRunner/             # Command parsing, tool grouping, schema rendering
│   ├── Exec/                      # One-shot exec mode
│   ├── Interactive/               # REPL / interactive session
│   └── Transports/                # Bootstrap socket transport
├── RepoPromptTests/               # XCTest unit/integration suites (+ Fixtures, Goldens, Helpers)
└── RepoPromptUITests/             # XCUITest suites
```

## Architecture Patterns

- **Pattern:** MVVM with feature-module folders. Each feature owns `Models/`, `ViewModels/`, and `Views/`. View models are `@MainActor ObservableObject` classes exposing `@Published` state; views are SwiftUI, with AppKit `NSViewController`/`NSView` representables used where SwiftUI cannot meet performance/behavior needs (file tree, chat transcript, TextKit input fields).
- **Composition root / DI:** Dependency injection is manual, not framework-based. `WindowState` (`App/WindowState.swift`) is the per-window composition root: it constructs and owns every feature view model and window-scoped service (`fileManager`, `promptManager`, `chatViewModel`, `agentModeViewModel`, `mcpServer`, `keyManager`, `aiQueriesService`, `diffParser`, `chatDataService`, `workspaceManager`, …) and wires them together. `ContentViewModel` exposes that graph to the SwiftUI view layer. App-wide singletons (e.g. the shared MCP service, settings managers) are held statically and injected by reference.
- **Multi-window:** `WindowStatesManager` tracks one `WindowState` per window; `windowID` keys window-scoped services and MCP routing. App entry is `RepoPromptApp` (`@main`) with `@NSApplicationDelegateAdaptor(AppDelegate)`.
- **Embedded MCP server:** A single app-wide MCP server (`MCPConnectionManager` / `MCPService`) advertises tools defined by `Service`-conforming tool services and the window-scoped `MCPServerViewModel`. Tools are registered via a `ServiceRegistry`; connections are routed to windows by `WindowRoutingService`/`WindowScopedService`. The `repoprompt-mcp` CLI connects over a Unix bootstrap socket.
- **Provider abstraction:** AI backends sit behind provider protocols built by `AIProviderFactory`. Two families exist: HTTP API providers (Anthropic, OpenAI, Gemini, etc.) and CLI/ACP agent providers (Claude Code, Codex, Cursor, Gemini, OpenCode) that drive external agent binaries via the Agent Client Protocol (ACP) and managed processes.
- **Concurrency:** Swift structured concurrency (`async/await`, actors) throughout; custom primitives (`AsyncMutex`, `AsyncScope`, `TaskSemaphore`, `PerKeyTaskStore`) coordinate serialized/keyed async work. Long-running scans use dedicated actors (`CodeScanActor`, `GitStatusActor`).
- **Persistence:** JSON document stores on disk (`GlobalSettingsFileStore`, `PresetFileStore`, `AgentSessionDataService`), `@AppStorage`/`UserDefaults` for lightweight prefs, and the macOS Keychain (gated on verified Apple-anchored signing) for secrets.

## Component Inventory

### Models / Entities

| Name | Path | Purpose |
| --- | --- | --- |
| AgentChatModels | `Features/AgentMode/Models/AgentChatModels.swift` | Agent chat message/turn model |
| AgentTranscriptModels | `Features/AgentMode/Models/AgentTranscriptModels.swift` | Transcript item domain model |
| AgentLogModels | `Features/AgentMode/Models/AgentLogModels.swift` | Agent run log entries |
| AgentWorkflow | `Features/AgentMode/Models/AgentWorkflow.swift` | Reusable agent workflow definition |
| AgentAttachments | `Features/AgentMode/Models/AgentAttachments.swift` | File/context attachments for a turn |
| CompressedTranscriptItem | `Features/AgentMode/Models/CompressedTranscriptItem.swift` | Collapsed/compressed transcript entry |
| UserInteractionModels | `Features/AgentMode/Models/UserInteractionModels.swift` | Pending user-interaction (ask/approve) models |
| AgentModel / AgentModelOption / AgentModelCatalog | `Features/AgentMode/Models/ModelSelection/` | Agent model identity, options, and catalog |
| ClaudeModelSpecifier | `Features/AgentMode/Models/ModelSelection/ClaudeModelSpecifier.swift` | Claude model selection descriptor |
| AIChatMessage / ContentItem / ChangedFile | `Features/Chat/Models/` | Chat message, content blocks, changed-file model |
| ChatContentParser (+ Staged/Bridge) | `Features/Chat/Models/` | Parse assistant output into content/diff items |
| MessageDiff | `Features/Chat/Models/MessageDiff.swift` | Per-message diff representation |
| ChatPreset | `Features/Chat/Models/ChatPreset.swift` | Saved chat configuration |
| FileAPI | `Features/CodeMap/Models/FileAPI.swift` | Extracted file signature/codemap model |
| PromptFileEntry / PromptAssemblyBuilder / PromptStorage | `Features/Prompt/Models/` | Prompt file entries and assembly model |
| CopyPreset / CopyCustomizations | `Features/Prompt/Models/Copy/` | Copy/export preset definitions |
| FileSystemItems | `Features/WorkspaceFiles/Models/FileSystemItems.swift` | File/folder tree node model |
| WorkspaceModel / WorkspaceSwitchingModels | `Features/Workspaces/` | Workspace identity and switching state |
| GlobalSettingsDocument / SettingsContext | `Features/Settings/Models/` | Persisted settings document and context |
| AIMessage / AIModel | `Infrastructure/AI/` | Provider-agnostic message and model identity |
| AgentMessage | `Infrastructure/AI/Providers/AgentMessage.swift` | Normalized agent provider message |
| ModelPreset (+ ModeSupport) | `Infrastructure/AI/Models/` | User-configured model preset |
| ApplyEditsModels / ApplyEditsResult | `Infrastructure/MCP/ApplyEdits/` | Edit request/result domain models |
| ToolResultDTOs / ToolArgsDTOs | `Infrastructure/MCP/ToolResultDTOs.swift`, `Features/AgentMode/Views/ToolCards/ToolArgsDTOs.swift` | Tool input/output DTOs |
| VCSModels / GitRepoDescriptor | `Infrastructure/VCS/` | Version-control status/repo models |
| GitDiff Models | `Infrastructure/VCS/GitDiff/Models/` | Compare spec, scope, target, fingerprint, manifest |
| DiffChunk | `Infrastructure/Diffing/DiffChunk.swift` | Parsed diff hunk |
| LineRange / SliceRangeMath | `Infrastructure/WorkspaceContext/Slices/` | File slice range models |
| MentionModels / MentionAssets | `Infrastructure/UI/Mentions/` | @-mention suggestion models |

### Services / Managers

| Name | Path | Purpose | Type | Key Dependencies |
| --- | --- | --- | --- | --- |
| AgentModeRunService | `Features/AgentMode/Runtime/AgentModeRunService.swift` | Orchestrates an agent run lifecycle | window-scoped | runners, provider bindings, MCP |
| AgentSessionDataService | `Features/AgentMode/Runtime/AgentSessionDataService.swift` | Persist/restore agent sessions | window-scoped | FileSystemService, JSON store |
| AgentAttachmentStore / AgentWorkflowStore | `Features/AgentMode/Runtime/` | Persist attachments and workflows | store | FileSystemService |
| AgentModeProviderBindingService | `Features/AgentMode/Runtime/ProviderBindings/AgentModeProviderBindingService.swift` | Bind sessions to provider configs | service | provider configs, secure store |
| AgentPermissionSecureStore | `Features/AgentMode/Runtime/ProviderBindings/AgentPermissionSecureStore.swift` | Persist agent permission grants | store | SecureKeyService |
| ChatHistoryManager / ChatSession | `Features/Chat/Services/` | Chat history persistence and session state | service | FileSystemService |
| ChatPresetManager / CopyPresetManager | `Features/Chat/ViewModels/Presets/`, `Features/Prompt/ViewModels/Copy/` | Manage chat/copy presets | manager | PresetFileStore |
| CodeMapCacheManager / CodeMapGenerator / CodeMapExtractor | `Features/CodeMap/` | Generate and cache code structure | manager/engine | tree-sitter, language strategies |
| DiscoverAgentService | `Infrastructure/AI/Agents/DiscoverAgentService.swift` | Autonomous context-discovery agent | service | providers, WorkspaceContext |
| AIQueriesService | `Infrastructure/AI/AIQueriesService.swift` | Run one-shot AI queries | window-scoped | AIProviderFactory |
| SystemPromptService | `Infrastructure/AI/SystemPromptService.swift` | Assemble system prompts | service | PromptFactory |
| PromptPackagingService | `Infrastructure/AI/PromptPackagingService.swift` | Package selected context into a prompt | service | WorkspaceContext, CodeMap |
| AgentRunCoordinator / AgentToolTracker | `Infrastructure/AI/Agents/` | Coordinate agent runs and track tool calls | service | providers, MCP |
| FileSystemService | `Infrastructure/FileSystem/FileSystemService.swift` | Scan/watch the file system with ignore rules and caching | service | IgnoreRulesManager, LRUCache |
| IgnoreRulesManager / GitignoreCompiler | `Infrastructure/FileSystem/` | Compile and evaluate ignore rules | manager | HierarchicalIgnoreEvaluator |
| MCPConnectionManager | `Infrastructure/MCP/MCPConnectionManager.swift` | Manage MCP server connections, routing, policies | app-wide | swift-sdk MCP, ServerController |
| MCPService | `Infrastructure/MCP/MCPService.swift` | Top-level MCP service aggregator | app-wide | ServiceRegistry, tool services |
| ServerController | `Infrastructure/MCP/ServerController.swift` | Start/stop the MCP server | service | swift-nio, transports |
| WindowRoutingService | `Infrastructure/MCP/WindowRoutingService.swift` | Route MCP calls to the correct window | service | MCPConnectionManager |
| AppSettingsMCPService | `Infrastructure/MCP/AppSettingsMCPService.swift` | Expose app settings over MCP | MCP tool service | GlobalSettingsManager |
| ApplyEditsService / ApplyEditsEngine | `Infrastructure/MCP/ApplyEdits/` | Apply structured edits to files | service/engine | FileEditHost, Diffing |
| WorkspaceApprovalManager | `Infrastructure/MCP/WorkspaceApproval/WorkspaceApprovalManager.swift` | Gate write access to workspace roots | manager | secure store |
| TokenCalculationService | `Infrastructure/WorkspaceContext/TokenAccounting/TokenCalculationService.swift` | Compute token counts/budgets | service | model catalog |
| GitService / VCSService / GitDiffEngine | `Infrastructure/VCS/` | Git/Jujutsu operations and diff generation | service/engine | GitBackend, JujutsuBackend |
| GitStatusActor | `Infrastructure/VCS/GitStatusActor.swift` | Serialize git status queries | actor | GitBackend |
| KeychainService / SecureKeyService / KeyManager | `Infrastructure/Security/` | Secret storage and key management | service | Keychain, EphemeralSecureKeyValueStore |
| BundleVerificationService / RuntimeCodeSigningDetector | `Infrastructure/Security/` | Verify code-signing identity at runtime | service | Security framework |
| NotificationService | `App/Notifications/NotificationService.swift` | In-app and system notifications | service | UserNotifications |
| GlobalSettingsManager / WindowSettingsManager | `Features/Settings/Models/` | Read/write settings documents | manager | GlobalSettingsFileStore |
| FontScaleManager / AppearanceController | `App/` | Global font scaling and appearance | manager | @AppStorage |
| HTTPClient | `Infrastructure/Networking/HTTPClient.swift` | Shared HTTP client | service | URLSession |
| ProcessLauncher / CLIProcessRunner / ProcessRegistry | `Infrastructure/Process/` | Launch and manage external CLI processes | service | Foundation.Process |
| MentionSuggestionService / AgentFileTagSuggestionService | `Infrastructure/UI/Mentions/` | @-mention and file-tag autocomplete | service | WorkspaceContext |

### AI Providers

| Name | Path | Purpose |
| --- | --- | --- |
| AIProviderFactory | `Infrastructure/AI/Providers/AIProviderFactory.swift` | Construct the correct provider for a model/mode |
| ProviderConfiguration | `Infrastructure/AI/Providers/ProviderConfiguration.swift` | Common provider config |
| AnthropicProvider | `Infrastructure/AI/Providers/AnthropicProvider.swift` | Anthropic API (HTTP) |
| OpenAIProvider / AzureOpenAIProvider | `Infrastructure/AI/Providers/` | OpenAI + Azure OpenAI |
| GeminiProvider | `Infrastructure/AI/Providers/GeminiProvider.swift` | Google Gemini API |
| OpenRouterProvider / GroqProvider / GrokProvider / DeepseekProvider / FireworksProvider / ZAIProvider / OllamaProvider | `Infrastructure/AI/Providers/` | OpenAI-compatible HTTP providers |
| CustomOpenAIProvider | `Infrastructure/AI/Providers/CustomOpenai/` | User-defined OpenAI-compatible endpoint |
| ClaudeCodeProvider / ClaudeCodeAgentProvider | `Infrastructure/AI/Providers/` | Claude Code CLI agent integration |
| ClaudeNativeProcessSessionController | `Infrastructure/AI/Providers/ClaudeCode/SDK/` | Drive Claude Code via native NDJSON protocol |
| CodexCLIProvider / CodexExecAgentProvider | `Infrastructure/AI/Providers/Codex/` | Codex CLI and exec agent integration |
| CodexAppServerClient / CodexNativeSessionController | `Infrastructure/AI/Providers/Codex/AppServer/` | Codex app-server protocol client |
| CursorCLIProvider / CursorACPAgentProvider | `Infrastructure/AI/Providers/Cursor/` | Cursor agent over ACP |
| GeminiCLIProvider / GeminiACPAgentProvider | `Infrastructure/AI/Providers/Gemini/` | Gemini CLI agent over ACP |
| OpenCodeCLIProvider / OpenCodeACPAgentProvider | `Infrastructure/AI/Providers/OpenCode/` | OpenCode agent over ACP |
| HeadlessAgentProvider / ACPHeadlessAgentProviderBridge | `Infrastructure/AI/Providers/` | Headless (no-UI) agent runs |
| DisposableProviderPool | `Infrastructure/AI/Providers/DisposableProviderPool.swift` | Pool short-lived provider instances |
| ACPAgentProvider / ACPAgentSessionController | `Infrastructure/AI/ACP/` | Agent Client Protocol transport and session control |

### MCP Tool Services

| Name | Path | Purpose |
| --- | --- | --- |
| MCPServerViewModel (+ extensions) | `Infrastructure/MCP/ViewModels/` | Window-scoped service exposing the core tool surface (file search, file tree, code structure, read file, selection, token stats, workspace context) |
| AgentExploreMCPToolService | `Infrastructure/MCP/Agent/AgentExploreMCPToolService.swift` | `agent_run` explore-role tool |
| AgentRunMCPToolService | `Infrastructure/MCP/Agent/AgentRunMCPToolService.swift` | Spawn/manage agent runs over MCP |
| AgentManageMCPToolService | `Infrastructure/MCP/Agent/AgentManageMCPToolService.swift` | Manage agents/models over MCP |
| MCPOracleToolService | `Infrastructure/MCP/MCPOracleToolService.swift` | `oracle_send` deep-reasoning tool |
| AppSettingsMCPService | `Infrastructure/MCP/AppSettingsMCPService.swift` | `app_settings` runtime configuration tool |
| ApplyEditsService | `Infrastructure/MCP/ApplyEdits/ApplyEditsService.swift` | `apply_edits` file-editing tool |
| MCPPromptRegistry | `Infrastructure/MCP/MCPPromptRegistry.swift` | Register MCP prompt templates |
| MCPConfigExportService | `Infrastructure/MCP/MCPConfigExportService.swift` | Export MCP client configuration |
| Service / Tool / ServiceRegistry | `Infrastructure/MCP/` | MCP service protocol, tool builder, registry |
| ToolOutputFormatter / ToolResultDTOs | `Infrastructure/MCP/` | Format tool results for transport |
| UnixSocketMCPTransport / BootstrapSocketServer | `Infrastructure/MCP/` | Socket transports for the bundled CLI |

### View Models / UI Stores

| Name | Path | Purpose | Services Used |
| --- | --- | --- | --- |
| ContentViewModel | `App/ViewModels/ContentViewModel.swift` | Root per-window VM exposing the feature graph | all feature VMs via WindowState |
| AgentModeViewModel (+ 16 extensions) | `Features/AgentMode/ViewModels/` | Drive agent-mode UI, composer, transcript, sidebar, provider bindings | AgentModeRunService, AgentSessionDataService, MCP |
| AgentRuntimeSidebarViewModel | `Features/AgentMode/ViewModels/UI/AgentRuntimeSidebarViewModel.swift` | Runtime sidebar state | AgentModeRunService |
| AgentModelsSettingsViewModel | `Features/AgentMode/ViewModels/UI/AgentModelsSettingsViewModel.swift` | Agent model configuration | AgentModelCatalog |
| AgentProviderPermissionsSettingsViewModel / AgentSubagentPermissionsSettingsViewModel | `Features/AgentMode/ViewModels/UI/` | Permission settings | AgentPermissionSecureStore |
| AgentOnboardingWizardViewModel / RecommendationWizardViewModel | `Features/AgentMode/ViewModels/` | Onboarding and recommendation flows | AutoRecommendationEngine |
| Agent UI stores (Composer/Transcript/Sidebar/StatusPills/RunInteraction/RuntimeMetrics) | `Features/AgentMode/ViewModels/UI/Agent*UIStore.swift` | Decomposed UI state stores for agent mode | — |
| AIResponseViewModel | `Features/AIQuery/ViewModels/AIResponseViewModel.swift` | One-shot AI query UI | AIQueriesService |
| ChatViewModel (+ Diffs/MCP) | `Features/Chat/ViewModels/` | Chat conversation UI | ChatHistoryManager, providers, MCP |
| DiscoverAgentViewModel | `Features/ContextBuilder/ViewModels/DiscoverAgentViewModel.swift` | Context-builder agent UI | DiscoverAgentService |
| DiffViewModel | `Features/Diff/ViewModels/DiffViewModel.swift` | Diff review UI | DiffParser, ChangeManager |
| PromptViewModel (+ HeadlessPlan/Snapshot) | `Features/Prompt/ViewModels/` | Prompt assembly UI | PromptPackagingService, WorkspaceContext |
| SelectedFilesPanelViewModel / TokenCountingViewModel | `Features/Prompt/ViewModels/` | Selected files and token count UI | TokenCalculationService |
| SearchFileTreeViewModel | `Features/Search/ViewModels/SearchFileTreeViewModel.swift` | File-tree search UI | FileSystemService, PathSearchIndex |
| RepoFileManagerViewModel | `Features/WorkspaceFiles/ViewModels/RepoFileManagerViewModel.swift` | File tree + selection state | FileSystemService, GitService |
| FileViewModel / FolderViewModel / FileSystemItemViewModel / ExpansionManager | `Features/WorkspaceFiles/ViewModels/` | File tree node state | FileSystemService |
| GitViewModel | `Features/WorkspaceFiles/ViewModels/GitViewModel.swift` | Git status badges | GitService, GitStatusActor |
| WorkspaceManagerViewModel | `Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift` | Workspace/preset management | GlobalSettingsManager, PresetFileStore |
| APISettingsViewModel | `Features/Settings/ViewModels/APISettingsViewModel.swift` | API key/provider settings | KeyManager, SecureKeyService |
| BenchmarkSettingsViewModel | `Features/Diagnostics/Benchmark/ViewModels/BenchmarkSettingsViewModel.swift` | Benchmark harness UI | BenchmarkEngine |
| MCPServerViewModel | `Infrastructure/MCP/ViewModels/MCPServerViewModel.swift` | MCP server status + core tool surface (also an MCP service) | MCPConnectionManager, WorkspaceContext |

### Views / Screens

SwiftUI views are organized per feature under `Features/*/Views/` plus reusable components in `Infrastructure/UI/`. There is no URL-based router; navigation is driven by `ContentViewModel.rootRoute`/`currentView` (`AppRootRoute`, `ViewType`) and window UI mode (`WindowUIMode`).

| Area | Path | Key Views |
| --- | --- | --- |
| Root | `App/Views/ContentView.swift`, `App/ContentView_WithState.swift` | App root scene and split layout |
| Agent Mode | `Features/AgentMode/Views/` | `AgentModeView`, `AgentModeDetailWithSidebarView`, `AgentInputBar`, `AgentMessageBubble`, transcript views, `RuntimeSidebar/`, `ToolCards/` (per-tool result cards) |
| AI Query | `Features/AIQuery/Views/` | `AIQueryView`, `GlassSummaryView`, `FilePreviewView`, `SelectionHUDView` |
| Chat | `Features/Chat/Views/` | `MainChatView`, `ChatMessagesView`, `ChatInputBar`, `Native/` AppKit message controllers |
| Diff | `Features/Diff/Views/` | `DiffView`, `FileCard`, `ChangeItem` |
| Prompt | `Features/Prompt/Views/` | `PromptView`, `TabbedPromptView`, `InstructionsView`, `Components/` preset/tab bars |
| Workspace Files | `Features/WorkspaceFiles/Views/FileTree/` | `FileTreeView`, AppKit `NativeFileTree/` + `NativeSearchFileTree/` controllers and cells |
| Workspaces | `Features/Workspaces/Views/` | `WorkspaceLandingView`, `ManageWorkspacesView`, `WorkspacePickerMenu`, preset views |
| Settings | `Features/Settings/Views/` | `SettingsView`, `SettingsWindowCoordinator`, plus per-section views (API, Agent, MCP, Models, Appearance, Keyboard) |
| Diagnostics | `Features/Diagnostics/` | `BenchmarkSettingsView`, `AgentChatStressHarnessPanel` |

### Widgets / Reusable Components

| Name | Path | Purpose |
| --- | --- | --- |
| UI Components library | `Infrastructure/UI/Components/` | Buttons, checkboxes, code blocks, popovers, MCP status/approval overlays, scroll/resize helpers (~35 components) |
| Markdown rendering | `Infrastructure/UI/Markdown/` | `EnhancedMarkdownView`, `CodeHighlighter`, file-link interaction, TextKit-backed markdown |
| Mentions | `Infrastructure/UI/Mentions/` | @-mention models, assets, suggestion services |
| TextKit input fields | `Infrastructure/UI/TextField/` | `MentionTextView`, `ResizableTextField`, mention overlay/coordinator, layout managers |
| Composer chrome | `Infrastructure/UI/Composer/ComposerChrome.swift` | Shared composer styling |
| Tooltip | `Infrastructure/UI/Tooltip/` | Anchored tooltip overlay controller |
| Agent UI cards | `Infrastructure/UI/Agent/` | Approval card, question card, model options menu, timeout countdown |
| Agent tool cards | `Features/AgentMode/Views/ToolCards/` | Per-tool result rendering (bash, edit, git, read/search, prompt, diff) |

### Engines

| Name | Path | Purpose |
| --- | --- | --- |
| ApplyEditsEngine | `Infrastructure/MCP/ApplyEdits/ApplyEditsEngine.swift` | Core search/replace + rewrite edit engine |
| BenchmarkEngine | `Features/Diagnostics/Benchmark/Core/BenchmarkEngine.swift` | Agent benchmark execution engine |
| GitDiffEngine | `Infrastructure/VCS/GitDiff/GitDiffEngine.swift` | Compute git diffs and snapshots |
| SliceRebaseEngine | `Infrastructure/WorkspaceContext/Slices/SliceRebaseEngine.swift` | Rebase file slices across edits |
| AutoRecommendationEngine | `Features/AgentMode/Recommendations/AutoRecommendationEngine.swift` | Recommend models/workflows |
| MCPServerViewModel+SelectionEngine | `Infrastructure/MCP/ViewModels/MCPServerViewModel+SelectionEngine.swift` | Context selection resolution engine |

### Runners / Coordinators

| Name | Path | Purpose |
| --- | --- | --- |
| ClaudeIntegratedAgentModeRunner / CodexIntegratedAgentModeRunner / ACPIntegratedAgentModeRunner / HeadlessAgentModeRunner | `Features/AgentMode/Runtime/Runners/` | Per-provider agent-mode execution runners |
| ClaudeAgentModeCoordinator / CodexAgentModeCoordinator | `Features/AgentMode/Runtime/Claude/`, `Codex/` | Coordinate provider-specific run state |
| AgentRunCoordinator | `Infrastructure/AI/Agents/AgentRunCoordinator.swift` | Cross-provider run coordination |
| SettingsWindowCoordinator | `Features/Settings/Views/SettingsWindowCoordinator.swift` | Manage the settings window |
| WindowCloseCoordinator | `App/WindowCloseCoordinator.swift` | Coordinate window close + persistence |
| GlobalKeyboardShortcutsCoordinator | `App/GlobalKeyboardShortcutsCoordinator.swift` | Register global shortcuts |
| MCPBackgroundModeCoordinator | `App/MCPBackgroundModeCoordinator.swift` | Keep MCP server alive in background |
| MentionCoordinator | `Infrastructure/UI/TextField/MentionCoordinator.swift` | Coordinate mention input/overlay |

### Stores / Registries

| Name | Path | Purpose |
| --- | --- | --- |
| AgentAttachmentStore / AgentWorkflowStore / AgentRunSessionStore | `Features/AgentMode/Runtime/`, `Infrastructure/MCP/Agent/` | Persist agent attachments, workflows, run sessions |
| AgentProviderPreferenceSnapshotStore / AgentPermissionSecureStore | `Features/AgentMode/Runtime/ProviderBindings/` | Provider preference and permission persistence |
| PartitionStore | `Infrastructure/WorkspaceContext/Slices/PartitionStore.swift` | Store file partition/slice state |
| GitDiffSnapshotStore | `Infrastructure/VCS/GitDiff/GitDiffSnapshotStore.swift` | Persist git diff snapshots |
| IgnoreCacheStore / PathComponentsCache / LRUCache / PatternPool | `Infrastructure/FileSystem/` | File-system and pattern caches |
| ToolAvailabilityStore / ApplyEditsApprovalStore | `Infrastructure/MCP/` | MCP tool availability and edit approvals |
| PresetFileStore / GlobalSettingsFileStore | `Infrastructure/Persistence/`, `Features/Settings/Models/` | JSON-backed preset and settings stores |
| AgentACPModelRegistry / AgentCodexModelRegistry / AgentModelCatalog | `Features/AgentMode/Models/ModelSelection/` | Agent model registries/catalog |
| ServiceRegistry / MCPPromptRegistry | `Infrastructure/MCP/` | MCP service and prompt registries |
| ProcessRegistry | `Infrastructure/Process/ProcessRegistry.swift` | Track launched processes |
| AgentTranscriptViewportRegistry | `Features/AgentMode/Views/Transcript/AgentTranscriptViewportRegistry.swift` | Track transcript viewport state |
| WorkspaceSwitchSessionRegistry | `Features/Workspaces/WorkspaceSwitchSessionRegistry.swift` | Track workspace switch sessions |

### Actors / Concurrency Primitives

| Name | Path | Purpose |
| --- | --- | --- |
| AsyncMutex / AsyncScope / TaskSemaphore | `Infrastructure/Concurrency/` | Async locking, scoped tasks, bounded concurrency |
| PerKeyTaskStore | `Features/AgentMode/Runtime/PerKeyTaskStore.swift` | Serialize async work per key |
| CodeScanActor | `Features/CodeMap/CodeScanActor.swift` | Serialize code-structure scanning |
| GitStatusActor | `Infrastructure/VCS/GitStatusActor.swift` | Serialize git status queries |
| DeferredReplayBufferActor / DeltaReplayPreparationActor | `Infrastructure/WorkspaceContext/Indexing/` | Buffer and prepare index replay deltas |
| AgentModeRunLease / HeadlessAgentRunLease / MCPBootstrapLease | `Features/AgentMode/Runtime/`, `Infrastructure/` | Single-owner run/connection leases |

### Strategies / Policies / Interfaces

| Name | Path | Purpose |
| --- | --- | --- |
| SwiftCodeMapStrategy / TypeScriptCodeMapStrategy | `Features/CodeMap/LanguageStrategies/` | Language-specific codemap extraction |
| AgentModeMCPToolPolicy / AgentModeMCPToolAdvertisementPolicy | `Infrastructure/MCP/Policies/` | Gate which tools agents may call/see |
| DelegateEditMCPToolPolicy / DiscoverMCPToolPolicy / MCPPolicyGatedTools / MCPToolCapabilities | `Infrastructure/MCP/Policies/` | Per-purpose tool policy and capability sets |
| AgentTranscriptPolicyPipeline (+ truncation/visibility/persistence policies) | `Features/AgentMode/Runtime/Transcript/` | Transcript shaping policies |
| AgentModeSidebarAutoArchivePolicy / AgentTranscriptAutoFollowRearmPolicy / AgentTranscriptScrollProgressPolicy | `Features/AgentMode/` | Sidebar/scroll behavior policies |
| WorkspacePathPolicy / PathCharPolicy | `Infrastructure/WorkspaceContext/` | Path resolution/validation policies |
| Service / WindowScopedService / MCPServerConnection | `Infrastructure/MCP/` | MCP service and connection protocols |
| VCSBackend / GitBackend / JujutsuBackend | `Infrastructure/VCS/` | Version-control backend protocol + implementations |
| FileEditHost / SandboxFileEditHost / WorkspaceFileEditHost | `Infrastructure/MCP/ApplyEdits/` | Edit-target host abstraction (real vs sandbox) |
| PathMatchingInterfaces / PathMatcher / PathMatchWorker | `Infrastructure/WorkspaceContext/PathLookup/` | Path matching abstraction + workers |
| SecureKeyValueStorageBackend | `Infrastructure/Security/SecureKeyValueStorageBackend.swift` | Pluggable secure storage backend |

### Enums / Constants / Config

| Name | Path | Purpose |
| --- | --- | --- |
| ViewType / AppRootRoute / WorkspaceEntryTab | `Features/Prompt/Views/ViewType.swift`, `App/ViewModels/ContentViewModel.swift` | Top-level navigation state |
| WindowKind / WindowUIMode | `App/WindowState.swift` | Window classification and UI mode |
| AppDeepLinkRoute | `App/AppDeepLinkRoute.swift` | Deep-link route enum |
| ReasoningEffort | `Infrastructure/AI/ModelCatalog/ReasoningEffort.swift` | Model reasoning-effort levels |
| MCPRunPurpose / ContextBuilderResponseType | `Infrastructure/MCP/` | MCP run purpose and response-type enums |
| FontPreset / Changelog | `App/` | Font presets and changelog data |
| MCPConstants / MCPServiceName / MCPFilesystemConstants / MCPNetworkConfig | `Shared/` | MCP wire constants shared with the CLI |
| AppLaunchConfiguration | `App/AppLaunchConfiguration.swift` | Env-driven launch flags (UI test/stress modes) |
| ClaudeCodeCommands | `Infrastructure/AI/Prompts/Workflows/ClaudeCodeCommands.swift` | Built-in Claude Code workflow commands |

### Prompts (data)

| Name | Path | Purpose |
| --- | --- | --- |
| PromptFactory / SystemPromptService | `Infrastructure/AI/Prompts/`, `Infrastructure/AI/` | Assemble system/user prompts |
| AgentModePrompts | `Infrastructure/AI/Prompts/AgentModePrompts.swift` | Agent-mode system prompts |
| Code Examples (per language) | `Infrastructure/AI/Prompts/Code Examples/` | Few-shot code examples for 13 languages |
| Legacy prompts | `Infrastructure/AI/Prompts/Legacy/` | Diff/edit/chat prompt templates |
| RepoPromptMCPInstructions | `Infrastructure/MCP/RepoPromptMCPInstructions.swift` | MCP server instructions exposed to clients |

### Utilities / Helpers / Extensions

| Name | Path | Purpose |
| --- | --- | --- |
| String/Array/Sequence/Error extensions | `Infrastructure/Utilities/` | Core type extensions |
| RelativePath / StandardizedPath / String+Slug | `Infrastructure/Utilities/` | Path normalization helpers |
| JSONDictionaryHelpers / MCPValueExtensions | `Infrastructure/Utilities/`, `Infrastructure/MCP/` | JSON/MCP value conversion |
| BoundedArray | `Infrastructure/Utilities/Collections/BoundedArray.swift` | Fixed-capacity collection |
| RegexToolkit / PCRE2RegexAdapter | `Infrastructure/Regex/` | Regex utilities over PCRE2 |
| SortingUtils | `Features/WorkspaceFiles/Utilities/SortingUtils.swift` | File-tree sorting |
| IncrentalJsonParser | `Infrastructure/AI/IncrentalJsonParser.swift` | Incremental streaming JSON parser |
| SecurityObfuscation | `Infrastructure/Security/SecurityObfuscation.swift` | Obfuscate sensitive strings |

### Syntax Parsing / Code Examples

| Name | Path | Purpose |
| --- | --- | --- |
| SyntaxManager / ComprehensiveHiglighter | `Infrastructure/SyntaxParsing/` | Tree-sitter parsing + highlighting orchestration |
| Tree-sitter query sets | `Infrastructure/SyntaxParsing/Queries/` | Highlight/structure queries for 13 languages |
| QueryResourceLoader | `Infrastructure/SyntaxParsing/QueryResourceLoader.swift` | Load query resources |
| JSTSSignatureExtractor / SwiftSignatureParser / LanguageTypeExtractor | `Features/CodeMap/` | Extract signatures for codemaps |
| Vendored C scanners | `Support/C/TreeSitterScannerSupport/` | Custom tree-sitter external scanners (js/python) |

### CLI (repoprompt-mcp)

| Name | Path | Purpose |
| --- | --- | --- |
| main | `repoprompt-mcp/main.swift` | CLI entry point |
| MCPCommandRunner / MCPCommandParser | `repoprompt-mcp/CommandRunner/` | Parse and dispatch CLI commands to MCP tools |
| ToolGroups / ToolSchemaRenderer / OutputSink | `repoprompt-mcp/CommandRunner/` | Group tools, render schemas, write output |
| ExecMCPService / ExecOptions | `repoprompt-mcp/Exec/` | One-shot `--call` execution mode |
| InteractiveMCPService / InteractiveREPL / REPLInputParser / InteractiveMCPClientSession | `repoprompt-mcp/Interactive/` | Interactive REPL session |
| BootstrapSocketMCPTransport / NonBlockingFDWriter | `repoprompt-mcp/Transports/` | Connect to the app over the bootstrap Unix socket |

## Data Flow

**Context building (prompt assembly):**
1. `FileSystemService` scans workspace roots, applying `IgnoreRulesManager`/`GitignoreCompiler` rules, and feeds `RepoFileManagerViewModel`'s file tree (`Features/WorkspaceFiles`).
2. The user selects files; `SelectedFilesPanelViewModel` and `PromptViewModel` track selection while `CodeMapGenerator` (via `CodeScanActor` + tree-sitter strategies) produces signatures, and `TokenCalculationService` budgets tokens.
3. `PromptPackagingService`/`SystemPromptService` assemble the selected context plus instructions into a prompt; `Features/Prompt/Views` render it and copy/export presets (`CopyPresetManager`) format the output.

**One-shot AI query / chat:**
1. `AIResponseViewModel`/`ChatViewModel` call `AIQueriesService`, which uses `AIProviderFactory` to construct an HTTP provider (`AnthropicProvider`, `OpenAIProvider`, …).
2. Streamed responses (`IncrentalJsonParser`, `eventsource`) flow back as `AIMessage`; `ChatContentParser` splits prose vs. file diffs; `DiffParser`/`ChangeManager` materialize edits for review in `DiffViewModel`.

**Agent mode:**
1. `AgentModeViewModel` starts a run via `AgentModeRunService`, which resolves a provider binding (`AgentModeProviderBindingService`) and selects a runner (`ClaudeIntegratedAgentModeRunner`, `CodexIntegratedAgentModeRunner`, `ACPIntegratedAgentModeRunner`, `HeadlessAgentModeRunner`).
2. Runners launch external agent CLIs through `ProcessLauncher`/`CLIProcessRunner` and speak ACP / native protocols (`ClaudeNativeProcessSessionController`, `CodexAppServerClient`). The agent connects back into the app's embedded MCP server to call tools.
3. `MCPConnectionManager` routes the agent's tool calls (via `WindowRoutingService`) to the originating window's `MCPServerViewModel`, gated by `AgentModeMCPToolPolicy`/`WorkspaceApprovalManager`. Tool results are formatted by `ToolOutputFormatter`.
4. Transcript events pass through `AgentTranscriptPolicyPipeline`, are persisted by `AgentSessionDataService`, and rendered as tool cards in `Features/AgentMode/Views/ToolCards`.

**External MCP client / CLI:**
- `repoprompt-mcp` connects over `BootstrapSocketMCPTransport` to `BootstrapSocketServer`; calls are dispatched through `MCPConnectionManager` to the same window-scoped tool services the in-app agents use.

## Dependency Graph

**Composition (ownership):**
- `RepoPromptApp` → `AppDelegate`, `WindowStatesManager` → one `WindowState` per window.
- `WindowState` constructs and owns: `RepoFileManagerViewModel`, `PromptViewModel`, `AIResponseViewModel`, `DiffViewModel`, `ChatViewModel`, `AgentModeViewModel`, `DiscoverAgentViewModel`, `SearchFileTreeViewModel`, `WorkspaceManagerViewModel`, `APISettingsViewModel`, `MCPServerViewModel`, plus `KeyManager`, `AIQueriesService`, `DiffParser`, `ChatDataService`, `WindowSettingsManager`, `WindowCloseCoordinator`. `ContentViewModel` mirrors this graph to the views.
- The MCP server is app-wide (`WindowState.sharedMCPService`) but routes per-window.

**View model → service:**
- `AgentModeViewModel` → `AgentModeRunService`, `AgentSessionDataService`, `AgentModeProviderBindingService`, MCP routing.
- `ChatViewModel` / `AIResponseViewModel` → `AIQueriesService` → `AIProviderFactory` → concrete providers.
- `RepoFileManagerViewModel` → `FileSystemService`, `IgnoreRulesManager`, `GitService`/`GitStatusActor`.
- `PromptViewModel` → `PromptPackagingService`, `CodeMapGenerator`, `TokenCalculationService`, WorkspaceContext.
- `MCPServerViewModel` → `MCPConnectionManager`, WorkspaceContext (selection/search/slices), `ApplyEditsService`.

**Service → backend:**
- Providers → `HTTPClient` (API providers) or `ProcessLauncher`/`CLIProcessRunner` + ACP controllers (agent providers).
- `GitService` → `GitBackend`/`JujutsuBackend` (VCS abstraction).
- `KeyManager`/`SecureKeyService` → `KeychainService` or `EphemeralSecureKeyValueStore`, selected by `RuntimeCodeSigningDetector`/`BundleVerificationService`.
- `FileSystemService` → `LRUCache`, `PathComponentsCache`, `IgnoreCacheStore`; search → `PathSearchIndex`, `RepoSearchBatchScorer`.

**Cross-cutting:**
- `ServiceRegistry` aggregates `Service`-conforming MCP tool services; `MCPConnectionManager` advertises them under per-connection `MCPToolCapabilities`/policies.
- Tree-sitter (`SyntaxManager`, language queries) underpins both `CodeMap` extraction and `Infrastructure/UI/Markdown` highlighting.

## Configuration

- **Bundle identifier:** `com.pvncher.repoprompt` (Release), `debug.pvncher.repoprompt` (Debug). Marketing version `2.1.32`.
- **URL scheme:** `repoprompt://` (`Info.plist` → `CFBundleURLTypes`), handled by `AppDeepLinkRouter`/`AppDeepLinkRoute` and `WindowState.handleIncomingURL`.
- **Document type:** `com.pvncher.repoprompt.document` (UTI), viewer role.
- **Entitlements** (`RepoPrompt/RepoPrompt.entitlements`): `com.apple.security.cs.allow-jit` (PCRE2/tree-sitter JIT) and `com.apple.security.files.bookmarks.app-scope` (security-scoped bookmarks for workspace roots). The app is **not** sandboxed.
- **Signing-gated secrets:** Secure storage uses the Keychain only when runtime evidence verifies an Apple-anchored team signature (`RuntimeCodeSigningDetector`); ad-hoc/self-signed/Debug builds fall back to process-local volatile storage (`EphemeralSecureKeyValueStore`).
- **Settings storage:** `GlobalSettingsManager`/`GlobalSettingsFileStore` (JSON documents), `WindowSettingsManager` (per-window), `@AppStorage`/`UserDefaults` for lightweight flags (e.g. `mcpAutoStart`).
- **Launch flags / diagnostics:** `AppLaunchConfiguration.current` reads environment variables to enable UI-test, window-restore-suppression, and agent-chat stress modes. DEBUG-only diagnostics (raw event logging, perf diagnostics) are toggled at runtime through the `app_settings` MCP surface — see `AGENTS.md`. Logging routes through `RepoPromptFileLogHandler` (swift-log).
- **Repo scoping:** `.repo_ignore` controls which files RepoPrompt's own tools index; `.gitleaks.toml` configures secret scanning.

## Testing Structure

- **Targets:** `RepoPromptTests` (296 Swift files, unit + integration) and `RepoPromptUITests` (XCUITest). Test plan: `RepoPrompt.xctestplan` (skips `ChangedFileAndParserTests`; sets `OS_ACTIVITY_MODE=disable`).
- **Naming:** Tests mirror the type under test (`PathMatcherTests.swift`, `ApplyEditsCoreTests.swift`); selectors are target-prefixed (`RepoPromptTests/ApplyEditsCoreTests/testExactMatch`).
- **Organization:** Mostly flat under `RepoPromptTests/`, with grouped subfolders: `AgentMode/` (+ `HistoricalAudit`), `Benchmark/`, `CodeMap/` (`Fixtures/`, `Goldens/`, `Helpers/` per language), `MCP/ApplyEdits/`, `PathMatching/`, `Process/`, `Security/`, `Services/`, `Settings/`.
- **Fixtures:** `RepoPromptTests/Fixtures/` (agent/Claude/Codex session fixtures), `CodeMap/Fixtures` + `CodeMap/Goldens` (golden-file codemap parity across 13 languages). `Infrastructure/FileSystem/TestSupport/TestFS.swift` provides an in-memory file system for service tests.
- **Patterns:** Heavy use of deterministic golden tests (codemaps, tool output formatting), fuzz tests (`DiffParserFuzzTests`, `IndentCorrectionUtilityFuzzTests`), and "optimization loop" regression tests for search/replay performance. Logic is isolated into small services/actors to test without mocks.
- **Conventions (`AGENTS.md`):** Never run the full suite or full UI target; prefer the smallest target-prefixed `RepoPromptTests/` selector, escalating to a `RepoPromptUITests/` selector only when UI/integration is the most relevant validation path.
```
