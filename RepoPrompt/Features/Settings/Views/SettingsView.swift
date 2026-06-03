import SwiftUI
import AppKit

/// Sidebar vibrancy wrapper so the Settings search bar area blends with the
/// `List(.sidebar)` material below it instead of dropping onto the default
/// window content background.
private struct SettingsSidebarMaterialView: NSViewRepresentable {
	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.blendingMode = .behindWindow
		view.state = .followsWindowActiveState
		view.material = .sidebar
		return view
	}

	func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SettingsView: View {
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var promptViewModel: PromptViewModel
	@ObservedObject var apiSettingsViewModel: APISettingsViewModel
	let windowState: WindowState
	var onAPIKeyUpdated: (() -> Void)?

	@Binding var selectedTab: SettingsTab
	@State private var searchText: String = ""
	@Environment(\.repoPromptFontScalePreset) private var fontPreset

	// Add a closure to handle closing/dismissing this view.
	var closeAction: (() -> Void)?

	/// Canonical sidebar order. Agent-mode first, then General (app-wide
	/// preferences), MCP, models/providers, workspaces, and the copy-&-chat
	/// workflow. Benchmark is intentionally grouped under Models & Providers
	/// rather than being its own top-level section.
	private static let sidebarSectionOrder: [TabSection] = [
		.agentMode, .general, .mcp, .api, .workspaces, .copyChat
	]

	/// Legacy alias tabs that are kept in the enum for deep-link and
	/// search-tag compatibility but should not appear in the sidebar —
	/// their content is rendered by another tab case.
	private static let legacyAliasTabs: Set<SettingsTab> = [.copyPresets, .chatPresets]

	/// Flat sorted list of tabs that match the current search text. When
	/// `searchText` is empty this is empty — sectioned rendering is used in
	/// that case. Matches the existing `title` + `searchTags` semantics and
	/// sorts by title so search results mirror Xcode / System Settings.
	private var searchResults: [SettingsTab] {
		guard !searchText.isEmpty else { return [] }
		let searchLower = searchText.lowercased()
		return SettingsTab.allCases
			.filter { !Self.legacyAliasTabs.contains($0) }
			.filter { tab in
				if tab.title.lowercased().contains(searchLower) { return true }
				return tab.searchTags.contains { tag in
					tag.lowercased().contains(searchLower)
				}
			}
			.sorted { $0.title < $1.title }
	}

	init(
		fileManager: RepoFileManagerViewModel,
		promptViewModel: PromptViewModel,
		apiSettingsViewModel: APISettingsViewModel,
		windowState: WindowState,
		onAPIKeyUpdated: (() -> Void)?,
		selectedTab: Binding<SettingsTab>,
		closeAction: (() -> Void)? = nil
	) {
		self.fileManager = fileManager
		self.promptViewModel = promptViewModel
		self.apiSettingsViewModel = apiSettingsViewModel
		self.windowState = windowState
		self.onAPIKeyUpdated = onAPIKeyUpdated
		self._selectedTab = selectedTab
		self.closeAction = closeAction
	}

	var body: some View {
		HStack(spacing: 0) {
			// Left sidebar — native sectioned list, Xcode-like rhythm.
			VStack(spacing: 0) {
				sidebarSearchBox
					.padding(.horizontal, fontPreset.scaledClamped(8, max: 12))
					.padding(.top, fontPreset.scaledClamped(8, max: 12))
					.padding(.bottom, fontPreset.scaledClamped(4, max: 8))
					.frame(maxWidth: .infinity)
					.background(SettingsSidebarMaterialView())

				sidebarList
			}
			.frame(
				minWidth: fontPreset.scaledClamped(200, max: 250),
				idealWidth: fontPreset.scaledClamped(215, max: 280),
				maxWidth: fontPreset.scaledClamped(260, max: 330)
			)

			Divider()

			// Right side with content
			VStack(spacing: 0) {
				contentView
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.id(selectedTab)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear {
			Task {
				await apiSettingsViewModel.loadStoredDataIfNeeded()
			}
		}
	}

	// MARK: - Sidebar (native sectioned list)

	/// Native sidebar selection binding. Legacy alias deep-links
	/// (`.copyPresets` / `.chatPresets`) are normalized to `.workflowPresets`
	/// for the sidebar highlight only; the real `selectedTab` remains the
	/// alias so the detail pane keeps rendering the correct scoped content.
	private var sidebarSelection: Binding<SettingsTab?> {
		Binding(
			get: {
				if Self.legacyAliasTabs.contains(selectedTab) { return .workflowPresets }
				return selectedTab
			},
			set: { newValue in
				if let newValue { selectedTab = newValue }
			}
		)
	}

	@ViewBuilder
	private var sidebarList: some View {
		if searchText.isEmpty {
			List(selection: sidebarSelection) {
				ForEach(Self.sidebarSectionOrder, id: \.self) { section in
					Section {
						ForEach(tabs(in: section), id: \.self) { tab in
							sidebarRow(for: tab)
								.tag(Optional(tab))
						}
					} header: {
						Text(section.title)
							.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
							.textCase(.uppercase)
							.tracking(0.8)
							.foregroundColor(.secondary)
					}
				}
			}
			.listStyle(.sidebar)
		} else if searchResults.isEmpty {
			noResultsView
		} else {
			List(selection: sidebarSelection) {
				ForEach(searchResults, id: \.self) { tab in
					sidebarRow(for: tab)
						.tag(Optional(tab))
				}
			}
			.listStyle(.sidebar)
		}
	}

	@ViewBuilder
	private func sidebarRow(for tab: SettingsTab) -> some View {
		HStack(spacing: fontPreset.scaledClamped(6, max: 9)) {
			Label(tab.title, systemImage: tab.iconName)
				.labelStyle(.titleAndIcon)
				.font(fontPreset.swiftUIFont(sizeAtNormal: 13))
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 0)
		}
		.contentShape(Rectangle())
		.help(tab.title)
	}

	private var sidebarSearchBox: some View {
		HStack(spacing: fontPreset.scaledClamped(6, max: 9)) {
			Image(systemName: "magnifyingglass")
				.foregroundColor(Color(NSColor.labelColor).opacity(0.6))
				.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
			TextField("Search Settings", text: $searchText)
				.textFieldStyle(PlainTextFieldStyle())
				.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
				.foregroundColor(Color(NSColor.labelColor))
				.accessibilityLabel("Search settings")
				.onKeyPress(.escape) {
					if !searchText.isEmpty {
						searchText = ""
						return .handled
					}
					return .ignored
				}
			if !searchText.isEmpty {
				Button(action: { searchText = "" }) {
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.secondary)
						.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
				}
				.buttonStyle(PlainButtonStyle())
				.accessibilityLabel("Clear settings search")
			}
		}
		.padding(.horizontal, fontPreset.scaledClamped(7, max: 11))
		.padding(.vertical, fontPreset.scaledClamped(4, max: 7))
		.background(Color.clear)
		.cornerRadius(fontPreset.scaledClamped(14, max: 20))
		.overlay(
			RoundedRectangle(cornerRadius: fontPreset.scaledClamped(14, max: 20))
				.stroke(Color(NSColor.systemGray).opacity(0.75), lineWidth: 0.5)
		)
	}

	private var noResultsView: some View {
		VStack(spacing: fontPreset.scaledClamped(6, max: 10)) {
			Image(systemName: "magnifyingglass")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 20))
				.foregroundColor(.secondary)
			Text("No settings found")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
				.foregroundColor(.secondary)
			Text("Try different search terms")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 11))
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(.vertical, fontPreset.scaledClamped(28, max: 38))
	}

	/// Canonical per-section tab order. Kept here (not on the enum) so display
	/// order is easy to tweak without touching the enum declaration.
	private func tabs(in section: TabSection) -> [SettingsTab] {
		switch section {
		case .agentMode:
			// Overview (formerly "Behavior") is the top-level entry point that
			// deep-links into each of the other Agent Mode settings surfaces, so
			// it sits first in the sidebar.
			return [.agentMode, .cliProviders, .agentModels, .agentPermissions, .agentWorkflows, .contextBuilder]
		case .mcp:
			return [.mcp, .mcpTools, .permissions, .modelPresets]
		case .api:
			return [.apiGeneral, .openRouter, .customProvider, .modelOverrides, .benchmark]
		case .workspaces:
			return [.manageWorkspaces, .managePresets]
		case .general:
			return [.appearance, .keyboardShortcuts, .advanced]
		case .copyChat:
			// `.copyPresets` and `.chatPresets` are intentionally omitted from the
			// sidebar – they now resolve to the unified Workflow Presets surface.
			// The enum cases remain so existing deep-links / search tags still land
			// in a sensible place (see `contentView`).
			return [.chatSettings, .workflowPresets, .proEdit, .promptOrder]
		}
	}

	@ViewBuilder
	private var contentView: some View {
		switch selectedTab {
		case .appearance:
			AppearanceSettingsView(promptViewModel: promptViewModel)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .mcp:
			MCPSettingsView(
                vm: windowState.mcpServer,
                promptVM: promptViewModel,
                windowID: windowState.windowID,
                onNavigate: { tab in selectedTab = tab },
                closeAction: closeAction
            )
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .mcpTools:
			MCPToolsSettingsView(server: windowState.mcpServer)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .permissions:
			PermissionsSettingsView()
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .keyboardShortcuts:
			KeyboardShortcutsSettingsView()
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .advanced:
			AdvancedSettingsView(
				fileManager: fileManager,
				promptViewModel: promptViewModel,
				windowState: windowState
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .chatSettings:
			ChatSettingsView(promptViewModel: promptViewModel, windowID: windowState.windowID, closeAction: closeAction)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .proEdit:
			ScrollView {
				VStack{
					ProEditSettingsView(promptViewModel: promptViewModel)
					Spacer()
				}
				.padding()
			}
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .benchmark:
			BenchmarkSettingsView(
				promptViewModel: promptViewModel,
				apiSettingsViewModel: apiSettingsViewModel
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .apiGeneral:
			APISettingsView(
				viewModel: apiSettingsViewModel,
				windowID: windowState.windowID,
				onAPIKeyUpdated: onAPIKeyUpdated,
				closeAction: closeAction
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .openRouter:
			OpenRouterSettingsView(viewModel: apiSettingsViewModel)
				.padding(.top)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .customProvider:
			CustomProviderSettingsView(viewModel: apiSettingsViewModel)
				.padding(.top)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .modelOverrides:
			ModelOverridesSettingsView(apiSettingsViewModel: apiSettingsViewModel)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .cliProviders:
			CLIProvidersSettingsView(
				viewModel: apiSettingsViewModel,
				promptViewModel: promptViewModel,
				windowID: windowState.windowID,
				providerPermissionsViewModel: { makeAgentProviderPermissionsSettingsViewModel() },
				onAPIKeyUpdated: onAPIKeyUpdated,
				closeAction: closeAction,
				onNavigate: { tab in selectedTab = tab }
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .promptOrder:
			PromptOrderSettingsView(promptViewModel: promptViewModel)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .manageWorkspaces:
			ManageWorkspacesView(isPresented: .constant(true), showCloseButton: false)
				.environmentObject(self.windowState.workspaceManager)
				.environmentObject(WindowStatesManager.shared)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .managePresets:
			if let activeWorkspace = self.windowState.workspaceManager.activeWorkspace {
				ManagePresetsView(
					isPresented: .constant(true),
					showCloseButton: false,
					workspace: activeWorkspace
				)
				.environmentObject(self.windowState.workspaceManager)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
			} else {
				VStack {
					Text("No Active Workspace")
						.font(.headline)
					Text("Please open or create a workspace to manage its presets.")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		case .modelPresets:
			ModelPresetsSettingsView(promptViewModel: promptViewModel)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .workflowPresets:
			WorkflowPresetsSettingsView(promptViewModel: promptViewModel)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .copyPresets:
			// Legacy deep-link target: render the unified Workflow Presets
			// surface with the Copy scope preselected.
			WorkflowPresetsSettingsView(promptViewModel: promptViewModel, initialScope: .copy)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .chatPresets:
			// Legacy deep-link target: render the unified Workflow Presets
			// surface with the Chat scope preselected.
			WorkflowPresetsSettingsView(promptViewModel: promptViewModel, initialScope: .chat)
				.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .contextBuilder:
			ContextBuilderSettingsView(
				discoverVM: windowState.discoverAgentViewModel,
				promptVM: promptViewModel,
				apiSettingsVM: apiSettingsViewModel,
				windowID: windowState.windowID,
				onNavigate: { tab in selectedTab = tab }
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .agentMode:
			AgentModeGeneralSettingsView(
				promptVM: promptViewModel,
				apiSettingsVM: apiSettingsViewModel,
				onNavigate: { tab in selectedTab = tab }
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .agentModels:
			AgentModelsSettingsView(
				promptVM: promptViewModel,
				discoverVM: windowState.discoverAgentViewModel,
				apiSettingsVM: apiSettingsViewModel,
				windowID: windowState.windowID,
				workspaceName: windowState.workspaceManager.activeWorkspace?.name,
				onNavigate: { tab in selectedTab = tab }
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .agentPermissions:
			let shellVMs = makeAgentPermissionsShellViewModels()
			AgentPermissionsSettingsView(
				apiSettingsVM: apiSettingsViewModel,
				providerViewModel: shellVMs.provider,
				subagentViewModel: shellVMs.subagent,
				diagnosticsViewModel: shellVMs.diagnostics,
				onNavigate: { tab in selectedTab = tab }
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		case .agentWorkflows:
			AgentModeWorkflowsSettingsView(
				workflowStore: .shared,
				onNavigate: { tab in selectedTab = tab }
			)
			.transition(.opacity.animation(.easeInOut(duration: 0.15)))
		}
	}

	/// Builds a provider-permissions VM wired to this window's Agent Mode binding
	/// service. Both CLI Providers and Agent Permissions use this path so provider-native
	/// mutations refresh active sessions consistently.
	///
	/// SEARCH-HELPER: Agent Provider Permissions VM, CLI Providers inline permissions,
	/// Direct Agents scope VM, shared storage diagnostics
	@MainActor
	private func makeAgentProviderPermissionsSettingsViewModel() -> AgentProviderPermissionsSettingsViewModel {
		let agentModeVM = windowState.agentModeViewModel
		let bindingService = agentModeVM.providerBindingService
		let securePermissions = bindingService.preferences.securePermissions
			?? AgentPermissionSecureStore.shared
		let diagnostics = AgentPermissionStorageDiagnosticsViewModel(
			securePermissions: securePermissions
		)
		return AgentProviderPermissionsSettingsViewModel(
			bindingService: bindingService,
			securePermissions: securePermissions,
			diagnostics: diagnostics,
			onProviderPreferenceChanged: { [weak agentModeVM] providerID in
				guard let agentModeVM else { return }
				agentModeVM.providerPreferenceDidChange(providerID, bumpProviderBindingRevision: false)
			},
			// Route Claude effort changes through `AgentModeViewModel.setClaudeEffortLevel(_:)`
			// so active sessions pick up the new effort via the same scheduling path that
			// `AgentInputBar` uses.
			onClaudeEffortLevelChanged: { [weak agentModeVM] level in
				agentModeVM?.setClaudeEffortLevel(level)
			}
		)
	}

	/// Builds the focused view models used by `AgentPermissionsSettingsView`'s
	/// scope shell. The provider VM uses the same wiring as CLI Providers, and the
	/// sub-agent VM shares its secure store and diagnostics banner.
	///
	/// SEARCH-HELPER: Agent Permissions shell view models, focused VMs, Direct Agents
	/// scope VM, Sub-Agents scope VM, shared storage diagnostics
	@MainActor
	private func makeAgentPermissionsShellViewModels() -> (
		provider: AgentProviderPermissionsSettingsViewModel,
		subagent: AgentSubagentPermissionsSettingsViewModel,
		diagnostics: AgentPermissionStorageDiagnosticsViewModel
	) {
		let provider = makeAgentProviderPermissionsSettingsViewModel()
		let securePermissions = provider.securePermissions ?? AgentPermissionSecureStore.shared
		let diagnostics = provider.diagnostics
		let subagent = AgentSubagentPermissionsSettingsViewModel(
			securePermissions: securePermissions,
			diagnostics: diagnostics
		)
		return (provider, subagent, diagnostics)
	}

}

enum TabSection: String, Identifiable {
	case agentMode
	case mcp
	case api
	case workspaces
	case general
	case copyChat

	var id: String { rawValue }

	var title: String {
		switch self {
		case .agentMode:   return "Agent Mode"
		case .mcp:         return "MCP Server"
		case .api:         return "Models & Providers"
		case .workspaces:  return "Workspaces"
		case .general:     return "General"
		// Display label intentionally shorter than the enum name so it fits the
		// native sidebar rhythm; enum case `copyChat` is preserved for routing.
		case .copyChat:    return "Prompting"
		}
	}
}

enum SettingsTab: String, CaseIterable {
	case appearance
	case mcp
	case mcpTools
	case permissions    // Workspace approvals (RepoPrompt-mutating operations)
	case keyboardShortcuts
	case advanced
	case chatSettings
	case proEdit
	case benchmark
	case apiGeneral
	case openRouter
	case customProvider
	case modelOverrides
	case cliProviders    // CLI Providers
	case promptOrder
	case manageWorkspaces
	case managePresets
	case modelPresets    // Model presets for MCP
	case workflowPresets // Unified Copy + Chat preset management
	case copyPresets     // Copy presets management (legacy deep-link → workflowPresets with Copy scope)
	case chatPresets     // Chat presets management (legacy deep-link → workflowPresets with Chat scope)
	case contextBuilder  // Context builder settings
	case agentMode       // Agent Mode "Overview" tab (formerly labeled "Agent Mode Behavior")
	case agentModels     // NEW: Unified model config shell (Phase 1 IA scaffolding)
	case agentPermissions // NEW: Unified permissions shell (Phase 1 IA scaffolding)
	case agentWorkflows  // Agent Mode workflow prompts and featured/custom workflows

	var title: String {
		switch self {
		case .appearance:        return "Appearance"
		case .mcp:               return "MCP Server"
		case .mcpTools:          return "Tools"
		case .permissions:       return "Workspace Approvals"
		case .keyboardShortcuts: return "Keyboard Shortcuts"
		case .advanced:          return "Advanced"
		case .chatSettings:      return "Chat Settings"
		case .proEdit:           return "Pro Edit"
		case .benchmark:         return "Benchmark"
		case .apiGeneral:        return "API Providers"
		case .openRouter:        return "OpenRouter"
		case .customProvider:    return "Custom API"
		case .modelOverrides:    return "Model Config"
		case .cliProviders:      return "CLI Providers"
		case .promptOrder:       return "Copy Prompt Order"
		case .manageWorkspaces:  return "Manage Workspaces"
		case .managePresets:     return "Manage Presets"
		case .modelPresets:      return "Model Presets"
		case .workflowPresets:   return "Workflow Presets"
		case .copyPresets:       return "Copy Presets"
		case .chatPresets:       return "Chat Presets"
		case .contextBuilder:    return "Context Builder"
		case .agentMode:         return "Overview"
		case .agentModels:       return "Agent Models"
		case .agentPermissions:  return "Agent Permissions"
		case .agentWorkflows:    return "Agent Workflows"
		}
	}

	var iconName: String {
		switch self {
		case .appearance:        return "paintbrush"
		case .mcp:               return "server.rack"
		case .mcpTools:          return "wrench.and.screwdriver"
		case .permissions:       return "shield.checkered"
		case .keyboardShortcuts: return "keyboard"
		case .advanced:          return "gearshape.2"
		case .chatSettings:      return "message"
		case .proEdit:           return "pencil.and.scribble"
		case .benchmark:         return "gauge"
		case .apiGeneral:        return "key"
		case .openRouter:        return "network"
		case .customProvider:    return "server.rack"
		case .modelOverrides:    return "slider.horizontal.3"
		case .cliProviders:      return "terminal"
		case .promptOrder:       return "list.bullet.indent"
		case .manageWorkspaces:  return "rectangle.stack"
		case .managePresets:     return "list.star"
		case .modelPresets:      return "cpu.fill"
		case .workflowPresets:   return "rectangle.stack.badge.person.crop"
		case .copyPresets:       return "doc.on.clipboard"
		case .chatPresets:       return "bubble.left.and.bubble.right"
		case .contextBuilder:    return "sparkles"
		case .agentMode:         return "brain.head.profile"
		case .agentModels:       return "brain"
		case .agentPermissions:  return "lock.shield"
		case .agentWorkflows:    return "bolt.fill"
		}
	}

	var section: TabSection? {
		switch self {
		// Agent Mode — agent-first section
		case .cliProviders,
				.agentModels,
				.agentPermissions,
				.agentWorkflows,
				.contextBuilder,
				.agentMode:
			return .agentMode

		// MCP Server
		case .mcp, .mcpTools, .permissions, .modelPresets:
			return .mcp

		// Models & Providers (Oracle + API key providers). Benchmark lives here
		// as a pro-gated leaf under Models & Providers rather than its own
		// top-level section.
		case .apiGeneral, .openRouter, .customProvider, .modelOverrides, .benchmark:
			return .api

		// Workspaces
		case .manageWorkspaces, .managePresets:
			return .workspaces

		// General
		case .appearance, .keyboardShortcuts, .advanced:
			return .general

		// Copy & Chat Workflow (IDE-era workflow)
		case .chatSettings, .workflowPresets, .copyPresets, .chatPresets, .proEdit, .promptOrder:
			return .copyChat
		}
	}

	var searchTags: [String] {
		switch self {
		case .appearance:
			return ["appearance", "theme", "dark", "light", "font", "text size", "colors", "look and feel",
					"visual", "display", "window", "interface", "ui", "design", "style"]
		case .keyboardShortcuts:
			return ["keyboard", "shortcut", "shortcuts", "hotkey", "hotkeys", "keybinding", "keybindings",
					"key binding", "global shortcut", "remap", "rebind", "compose tab shortcut", "preset shortcut",
					"command option", "workspace save shortcut", "font size shortcut", "agent shortcut"]
		case .advanced:
			return ["advanced", "advanced settings", "file paths", "path display", "relative paths",
					"absolute paths", "gitignore", "ignore files", "empty folders", "show folders",
					"file system", "refresh", "url scheme", "repoprompt://", "open links",
					"prompt", "instructions", "system prompt", "default prompt", "claude.md",
					"ai behavior", "ai instructions", "custom instructions",
					"model settings", "diff models", "rewrite files", "allow rewrite", "rewrite entire files",
					"datetime", "timestamp", "include datetime", "user instructions",
					"saved prompts", "export prompts", "import prompts", "reset prompts",
					"manage prompts", "prompt templates", "backup prompts",
					"code maps", "codemap", "code map", "code structure", "disable codemaps",
					"global codemap", "get_code_structure"]
		case .chatSettings:
			return ["chat", "messages", "conversation", "chat interface", "chat window", "formatting",
					"markdown", "code blocks", "copy button", "export chat", "clear chat", "chat history",
					"built-in chat"]
		case .proEdit:
			return ["pro edit", "edit mode", "multi-file editing", "bulk changes",
					"search and replace", "find and replace", "workspace editing", "project-wide changes"]
		case .benchmark:
			return ["benchmark", "bench", "score", "ranking", "model benchmark", "run benchmark",
					"benchmark history", "benchmark leaderboard", "seed", "performance test", "model evaluation"]
		case .apiGeneral:
			return ["api", "api key", "api keys", "providers", "add provider", "configure provider",
					"openai", "anthropic", "claude", "gpt", "gpt-4", "gpt-4o", "gpt-3.5",
					"claude-3", "claude-3.5", "sonnet", "opus", "haiku",
					"gemini", "google", "azure", "openrouter", "deepseek", "groq", "grok",
					"fireworks", "ollama", "local", "add api key", "manage keys",
					"oracle", "planning model", "glm", "claude code glm", "z.ai"]
		case .openRouter:
			return ["openrouter", "open router", "add openrouter", "openrouter key", "openrouter models",
					"llama", "mistral", "mixtral", "qwen", "deepseek", "custom models", "model list",
					"openrouter pricing", "openrouter credits", "model marketplace"]
		case .customProvider:
			return ["custom", "custom provider", "custom api", "add custom provider", "api endpoint",
					"custom endpoint", "self-hosted", "local api", "company api", "private api",
					"custom url", "base url", "custom headers"]
		case .modelOverrides:
			return ["model", "model config", "model configuration", "temperature", "creativity",
					"response length", "max tokens", "context window", "model parameters",
					"model settings", "override model", "custom parameters"]
		case .cliProviders:
			return ["cli", "cli providers", "command line", "terminal", "claude code", "codex",
					"claude cli", "codex cli", "claude max", "sourcegraph", "cli tools",
					"local cli", "cli authentication", "claude login", "codex login",
					"test connection", "cli connection", "command line tools", "agent mode",
					"opencode", "cursor", "gemini cli", "glm", "z.ai", "zai", "claude code glm",
					"anthropic glm"]
		case .promptOrder:
			return ["prompt order", "copy prompt order", "prompt priority", "prompt sequence", "reorder prompts",
					"arrange prompts", "prompt organization", "prompt hierarchy", "copy order"]
		case .mcp:
			return ["mcp", "mcp server", "model context protocol", "enable mcp", "disable mcp",
					"mcp connection", "mcp status", "connect mcp", "mcp settings", "mcp configuration"]
		case .mcpTools:
			return ["mcp tools", "tools", "tool availability", "tool toggles", "enable tool", "disable tool",
					"tool access", "tool list", "tool permissions", "mcp tool settings"]
		case .permissions:
			return ["permissions", "workspace permissions", "workspace approvals", "auto approve", "approval",
					"trusted clients", "allow operations", "workspace operations", "create workspace",
					"delete workspace", "add folder", "remove folder", "security", "trust", "authorization"]
		case .modelPresets:
			return ["model presets", "presets", "quick switch", "model templates", "save model",
					"saved models", "favorite models", "model profiles", "quick select",
					"switch models", "model shortcuts", "preset configurations", "oracle model presets"]
		case .manageWorkspaces:
			return ["workspace", "workspaces", "manage workspaces", "add workspace", "delete workspace",
					"rename workspace", "switch workspace", "open workspace", "recent workspaces",
					"workspace settings", "project", "folder", "directory"]
		case .managePresets:
			return ["presets", "manage presets", "workspace presets", "project presets",
					"preset settings", "save preset", "delete preset", "export preset",
					"import preset", "preset templates", "default presets"]
		case .workflowPresets:
			return ["workflow presets", "presets", "copy presets", "chat presets",
					"copy modes", "chat modes", "clipboard presets", "conversation presets",
					"manage presets", "manual mode", "xml mode", "mcp modes",
					"architect mode", "code review mode", "chat plan", "chat edit",
					"manage copy presets", "manage chat presets", "create preset", "edit preset",
					"copy templates", "chat templates", "built-in presets", "custom presets",
					"workflow templates", "copy workflow", "chat workflow"]
		case .copyPresets:
			return ["copy presets", "copy modes", "export presets", "clipboard presets",
					"copy settings", "copy configuration", "copy templates", "manual mode",
					"xml mode", "mcp modes", "architect mode", "code review mode",
					"manage copy presets", "create copy preset", "edit copy preset",
					"workflow presets"]
		case .chatPresets:
			return ["chat presets", "chat modes", "chat settings", "chat configuration",
					"chat templates", "conversation presets", "chat plan", "chat edit",
					"manage chat presets", "create chat preset", "edit chat preset",
					"auto start chat", "chat warnings", "chat context",
					"workflow presets"]
		case .contextBuilder:
			return ["context builder", "discovery", "discover agent", "token budget",
					"clarifying questions", "ui clarifying questions", "mcp clarifying questions",
					"question timeout", "ask_user timeout", "timeout",
					"prompt enhancement", "rewrite", "augment", "preserve",
					"auto plan", "plan generation", "claude code", "codex", "gemini cli",
					"analysis budget", "plan token budget", "custom prompts",
					"custom instructions", "ui runs", "mcp runs"]
		case .agentMode:
			return ["agent mode", "overview", "behavior", "display", "runtime", "agent settings",
					"providers", "connected", "direct agents", "sub-agents", "deep links",
					"built-in workflows", "workflow prompts", "built-in workflow prompts",
					"session cleanup", "session cleanup guidance", "housekeeping",
					"dismiss completed sessions", "cleanup guidance", "cleanup_sessions",
					"investigate workflow", "refactor workflow", "orchestrate workflow"]
		case .agentModels:
			return ["agent models", "oracle model", "planning model", "chat model",
					"context builder agent",
					"sub-agent role defaults", "sub-agent roles", "sub agent roles",
					"subagent role defaults", "subagent roles",
					"agent role defaults", "agent roles", "task labels",
					"explore", "engineer", "pair", "design",
					"recommended models", "apply recommended", "model recommendations",
					"oracle model presets", "model selection", "model destinations"]
		case .agentPermissions:
			return ["agent permissions", "permissions", "safe managed", "sub-agent permissions",
					"force safe", "permission mode", "bash", "claude bash", "codex sandbox",
					"acp session mode", "mcp strict mode", "auto approve", "tool search",
					"permission profile", "provider permissions"]
		case .agentWorkflows:
			return ["agent workflows", "agent mode workflows", "built-in workflows", "featured workflows",
					"custom workflow", "workflow prompts", "cleanup guidance", "hide workflow",
					"clone workflow", "Workflows folder", "session cleanup", "built-in workflow prompts"]
		}
	}
}
