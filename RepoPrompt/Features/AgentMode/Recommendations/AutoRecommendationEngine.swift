import Foundation

// Import AIModel for type-safe model references

// MARK: - Provider Flags Helper

/// Helper struct to expose provider status from APISettingsViewModel.
struct ProviderFlags: Sendable {
    let hasOpenAIKey: Bool
    let openAIValid: Bool
    let claudeCodeConnected: Bool
    let codexConnected: Bool
    let geminiCLIConnected: Bool
    let cursorConnected: Bool
}

// MARK: - Auto Recommendation Engine

/// Core logic service that detects provider availability and computes recommendations.
/// Does NOT perform network calls - only consults existing flags and settings.
@MainActor
final class AutoRecommendationEngine {
    
    // MARK: - Dependencies
    
    private let settingsStore: GlobalSettingsStore
    private(set) weak var apiSettingsViewModel: APISettingsViewModel?
    
    // MARK: - Constants
    
    /// How long before wizard completion expires (3 days).
    private let completionRecencyInterval: TimeInterval = 3 * 24 * 60 * 60
    
    // MARK: - Initialization
    
    init(settingsStore: GlobalSettingsStore,
         apiSettingsViewModel: APISettingsViewModel) {
        self.settingsStore = settingsStore
        self.apiSettingsViewModel = apiSettingsViewModel
        
        // Ensure schema version is up to date on init
        settingsStore.ensureLatestRecommendationSchema(currentVersion: BestPracticeProfiles.versionCode)
    }
    
    // MARK: - Provider Status
    
    /// Compute provider status snapshot without network calls.
    func computeProviderStatus() -> ProviderStatusSnapshot {
        guard let vm = apiSettingsViewModel else {
            return ProviderStatusSnapshot(
                claudeCodeCLI: .notConfigured,
                codexCLI: .notConfigured,
                geminiCLI: .notConfigured,
                cursorCLI: .notConfigured,
                openAI: .notConfigured
            )
        }
        
        let status = ProviderStatusSnapshot(
            claudeCodeCLI: vm.isClaudeCodeConnected ? .ready : .notConfigured,
            codexCLI: vm.isCodexConnected ? .ready : .notConfigured,
            geminiCLI: vm.isGeminiConnected ? .ready : .notConfigured,
            cursorCLI: vm.isCursorConnected ? .ready : .notConfigured,
            openAI: vm.isOpenAIKeyValid ? .ready : (!vm.openAIApiKey.isEmpty ? .configured : .notConfigured)
        )
        return status
    }
    
    /// Get provider flags from APISettingsViewModel.
    func getProviderFlags() -> ProviderFlags? {
        guard let vm = apiSettingsViewModel else { return nil }
        return ProviderFlags(
            hasOpenAIKey: !vm.openAIApiKey.isEmpty,
            openAIValid: vm.isOpenAIKeyValid,
            claudeCodeConnected: vm.isClaudeCodeConnected,
            codexConnected: vm.isCodexConnected,
            geminiCLIConnected: vm.isGeminiConnected,
            cursorConnected: vm.isCursorConnected
        )
    }
    
    // MARK: - Compute Recommendations
    
    /// Compute all recommendations for a workspace.
    /// Only returns recommendations where current settings differ from the recommended configuration.
    func computeRecommendations(
        for workspaceID: UUID,
        enabledProviders: Set<RecommendationProviderKind> = Set(RecommendationProviderKind.allCases)
    ) -> RecommendationSet {
        let actualStatus = computeProviderStatus()
        let status = actualStatus.filtered(to: enabledProviders)
        let settings = settingsStore.chatSettings(for: workspaceID)
        
        var result = RecommendationSet()
        
        if var chatRec = computeChatModelRecommendation(status: status) {
            chatRec.alreadySatisfied = isChatModelAlreadyConfigured(chatRec)
            result.chatModel = chatRec
        }
        
        if var cbRec = computeContextBuilderRecommendation(status: status, settings: settings) {
            cbRec.alreadySatisfied = isContextBuilderAlreadyConfigured(cbRec, settings: settings)
            result.contextBuilder = cbRec
        }
        
        if var proRec = computeProEditRecommendation(status: status, settings: settings) {
            proRec.alreadySatisfied = isProEditAlreadyConfigured(proRec)
            result.proEdit = proRec
        }
        
        if var mcpRec = computeMCPPresetExposureRecommendation() {
            mcpRec.alreadySatisfied = isMCPPresetExposureAlreadyConfigured(mcpRec)
            result.mcpPresetExposure = mcpRec
        }
        
		if status.hasAnyCLIAgentReady {
			if let agentRec = computeMCPAgentDefaultsRecommendation(
				workspaceID: workspaceID,
				actualStatus: actualStatus,
				recommendedStatus: status
			) {
				result.mcpAgentDefaults = agentRec
			}
		}
		
        return result
    }
    
    // MARK: - Chat Model Recommendation
    
    private func computeChatModelRecommendation(status: ProviderStatusSnapshot) -> ChatModelRecommendation? {
        let inAppPlanning = BestPracticeProfiles.bestInAppPlanningReview
        let apiPlanningModelString = AIModel.gpt54Pro.rawValue
        let apiPlanningModelLabel = AIModel.gpt54Pro.displayName

        // Build available options
        var codexOption: ChatBackendOption?
        var openAIOption: ChatBackendOption?
        var claudeCodeOption: ChatBackendOption?
        var geminiOption: ChatBackendOption?
        
        // Codex CLI option - PREFERRED for chat
        if status.codexCLI == .ready {
            codexOption = ChatBackendOption(
                kind: .codex,
                displayName: "Codex CLI (Recommended)",
                modelString: inAppPlanning.modelString,
                description: "\(inAppPlanning.modelLabel) – strong reasoning with practical limits",
                tradeoffs: [
                    "• Strong reasoning without extended wait times",
                    "• Won't exhaust weekly usage limits quickly",
                    "• XHigh available for complex tasks when needed"
                ]
            )
        }
        
        // OpenAI API option - shows reasoning but higher cost; kept separate from Codex CLI GPT-5.5 agent models.
        if status.openAI == .ready {
            openAIOption = ChatBackendOption(
                kind: .openAI,
                displayName: "OpenAI API",
                modelString: apiPlanningModelString,
                description: "\(apiPlanningModelLabel) via API – API-backed planning and review",
                tradeoffs: [
                    "• API-backed GPT-5.5 Pro planning and review when Codex CLI is unavailable",
                    "• Visible reasoning traces",
                    "• Separate from Codex CLI GPT-5.5 agent workflows"
                ]
            )
        }
        
        // Claude Code CLI option - use Opus for chat (great at editing/context)
        if status.claudeCodeCLI == .ready {
            claudeCodeOption = ChatBackendOption(
                kind: .claudeCode,
                displayName: "Claude Code",
                modelString: AIModel.claudeCodeOpus.rawValue, // Opus for chat
                description: "Claude Opus 4.6 – great for editing and context management",
                tradeoffs: [
                    "• Excellent at file editing and code modifications",
                    "• Superior context window management",
                    "• Strong alternative to Codex for agentic tasks"
                ]
            )
        }
        
        // Gemini CLI option - great at design, decent at planning
        if status.geminiCLI == .ready {
            geminiOption = ChatBackendOption(
                kind: .gemini,
                displayName: "Gemini CLI",
                modelString: AIModel.geminiCliPro3p1Preview.rawValue,
                description: "Gemini 3.1 Pro Preview via CLI",
                tradeoffs: [
                    "• Excellent at design and creative discussions",
                    "• Decent at planning tasks",
                    "• Less suited for direct file editing"
                ]
            )
        }
        
        // Determine default backend and upgrade hint
        // Priority for CHAT: Codex CLI > OpenAI API > Claude Code > Gemini CLI
        let defaultBackend: ChatBackendKind
        var priorityPath: [String] = []
        var upgradeHint: String? = nil

        if codexOption != nil {
            defaultBackend = .codex
            priorityPath = ["Codex CLI (\(inAppPlanning.modelLabel))", "OpenAI API", "Claude Code", "Gemini CLI"]
        } else if openAIOption != nil {
            defaultBackend = .openAI
            priorityPath = ["OpenAI API (\(apiPlanningModelLabel))", "Claude Code", "Gemini CLI"]
            upgradeHint = "Connect Codex CLI for \(inAppPlanning.modelLabel) – strong reasoning with practical usage limits (requires OpenAI Plus/Pro)."
        } else if claudeCodeOption != nil {
            defaultBackend = .claudeCode
            priorityPath = ["Claude Code", "Gemini CLI"]
            upgradeHint = "For best chat experience, connect Codex CLI (requires OpenAI Plus/Pro) for \(inAppPlanning.modelLabel) – balances quality with usage limits."
        } else if geminiOption != nil {
            defaultBackend = .gemini
            priorityPath = ["Gemini CLI"]
            upgradeHint = "For best results, connect Codex CLI (OpenAI Plus/Pro) for \(inAppPlanning.modelLabel) – balances quality with usage limits."
        } else {
            return nil
        }
        
        return ChatModelRecommendation(
            defaultBackend: defaultBackend,
            codexOption: codexOption,
            openAIOption: openAIOption,
            claudeCodeOption: claudeCodeOption,
            geminiOption: geminiOption,
            priorityPath: priorityPath,
            upgradeHint: upgradeHint
        )
    }
    
    // MARK: - Context Builder Recommendation
    
    private func computeContextBuilderRecommendation(
        status: ProviderStatusSnapshot,
        settings: ChatGlobalSettings
    ) -> ContextBuilderRecommendation? {
        // Priority: Codex CLI (requires CLI) > Claude Code > Gemini CLI > Cursor CLI
        // Cursor is a fallback only; it does not take priority over existing recommended providers.
        // Note: codexExec agent requires Codex CLI specifically, not just OpenAI API key

        if status.codexCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .codexExec,
                recommendedModel: .gpt55CodexLow,
				rationale: BestPracticeProfiles.contextBuilderRationale
            )
        } else if status.claudeCodeCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .claudeCode,
                recommendedModel: .claudeSonnet,
                rationale: "Claude Code with Sonnet provides strong context building with good balance of speed and quality.",
				upgradeHint: "For best context building, connect Codex CLI with GPT-5.5 Low. Requires OpenAI Plus/Pro subscription."
            )
        } else if status.geminiCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .gemini,
                recommendedModel: .geminiPro3p1Preview,
                rationale: "Gemini 3.1 Pro Preview provides decent context building. Great at design discussions but less suited for file-heavy operations.",
				upgradeHint: "For best results, connect Codex CLI with GPT-5.5 Low or Claude Code with Sonnet."
            )
        } else if status.cursorCLI == .ready {
            return ContextBuilderRecommendation(
                recommendedAgent: .cursor,
                recommendedModel: .cursorComposer2,
                rationale: "Cursor CLI with Composer 2 can handle context building when the preferred Codex, Claude Code, or Gemini CLI providers are not configured.",
				upgradeHint: "For best context building, connect Codex CLI with GPT-5.5 Low or Claude Code with Sonnet."
            )
        }
        
        return nil
    }
    
    // MARK: - Pro Edit Recommendation
    
    /// Computes Pro Edit recommendation with CLI agent priority:
    /// 1. Claude Code CLI → Sonnet (best for file editing)
    /// 2. Codex CLI (no Claude Code) → Codex max medium
    /// 3. Only Gemini CLI → Gemini 3.1 Pro
    /// 4. No CLIs but has OpenAI API → Model mode (auto-configure)
    /// 5. Nothing available → Disabled
    private func computeProEditRecommendation(
        status: ProviderStatusSnapshot,
        settings: ChatGlobalSettings
    ) -> ProEditRecommendation? {
        let hasClaudeCode = status.claudeCodeCLI == .ready
        let hasCodex = status.codexCLI == .ready
        let hasGeminiCLI = status.geminiCLI == .ready
        let hasAnyAPI = status.openAI == .ready
        
        // Priority 1: Claude Code CLI → Sonnet (best for file editing)
        if hasClaudeCode {
            return ProEditRecommendation(
                shouldEnableProEdit: true,
                recommendedMode: .agent,
                rationale: "Pro Edit with Claude Code + Sonnet provides the best agent-powered code modifications. Claude excels at file editing, following complex instructions, and handling multi-step tool sequences.",
                recommendedAgent: .claudeCode,
                recommendedAgentModel: .claudeSonnet
            )
        }
        
		// Priority 2: Codex CLI (no Claude Code) → GPT-5.5 Medium
        if hasCodex {
            return ProEditRecommendation(
                shouldEnableProEdit: true,
                recommendedMode: .agent,
				rationale: "Pro Edit with Codex CLI + GPT-5.5 Medium provides capable code modifications with a balanced reasoning-to-speed profile.",
                recommendedAgent: .codexExec,
                recommendedAgentModel: .gpt55CodexMedium,
                upgradeHint: "For best Pro Edit results, install Claude Code CLI. Claude excels at file editing and multi-step tool sequences."
            )
        }
        
        // Priority 3: Only Gemini CLI → Gemini 3.1 Pro
        if hasGeminiCLI {
            return ProEditRecommendation(
                shouldEnableProEdit: true,
                recommendedMode: .agent,
                rationale: "Pro Edit with Gemini CLI + Gemini 3.1 Pro Preview provides basic code modifications.",
                recommendedAgent: .gemini,
                recommendedAgentModel: .geminiPro3p1Preview,
                upgradeHint: "For better Pro Edit results, install Claude Code CLI (best) or Codex CLI. CLI agents provide superior file editing capabilities."
            )
        }
        
        // Priority 4: No CLI agents but has OpenAI API → Model mode
        if hasAnyAPI {
            return ProEditRecommendation(
                shouldEnableProEdit: true,
                recommendedMode: .model,
                rationale: "Pro Edit in Model mode uses your configured OpenAI API key for code modifications. This works well for straightforward edits.",
                recommendedAgent: nil,
                recommendedAgentModel: nil,
                upgradeHint: "Strongly recommended: Install a CLI agent for Pro Edit. Claude Code CLI provides the best editing experience, followed by Codex CLI (OpenAI Plus/Pro) or Gemini CLI. CLI agents enable agent mode which excels at complex, multi-step edits."
            )
        }
        
        // Priority 5: Nothing available → Disabled but provide upgrade hint
        return ProEditRecommendation(
            shouldEnableProEdit: false,
            recommendedMode: .disabled,
            rationale: "No providers configured for Pro Edit. Configure an API key or install a CLI agent to enable Pro Edit.",
            recommendedAgent: nil,
            recommendedAgentModel: nil,
            upgradeHint: "To enable Pro Edit, either: (1) Add an OpenAI API key for model-based editing, or (2) install a compatible CLI agent (Claude Code recommended) for the best agent-powered editing experience."
        )
    }
    
    // MARK: - MCP Preset Exposure Recommendation
    
    private func computeMCPPresetExposureRecommendation() -> MCPPresetExposureRecommendation? {
		let showModelPresets = settingsStore.mcpShowModelPresets()
		let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()
        
        // If presets toggle is OFF, recommend enabling it (and we'll set temp disable too)
        if !showModelPresets {
            return MCPPresetExposureRecommendation(
                shouldTemporarilyDisablePresets: false,  // false = recommend enabling the whole feature
                rationale: "Enable MCP model presets to use the recommended MCP chat model."
            )
        }
        
        // If presets are ON but temp disable is OFF, recommend enabling temp disable
        // This shows the MCP chat model dropdown directly instead of presets
        if !temporarilyDisabled {
            return MCPPresetExposureRecommendation(
                shouldTemporarilyDisablePresets: true,  // true = recommend showing MCP chat model dropdown
                rationale: "Use the MCP chat model dropdown directly for better control over model selection."
            )
        }
        
        // Both settings are correctly configured - no recommendation needed
        return nil
    }
    
	// MARK: - MCP Agent Defaults Recommendation

	/// Build a connection-aware availability context from provider status.
	private func mcpAgentAvailabilityContext(from status: ProviderStatusSnapshot) -> AgentModelCatalog.AvailabilityContext {
		let backendStore = ClaudeCodeCompatibleBackendStore.shared
		return AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: status.claudeCodeCLI == .ready,
			codexAvailable: status.codexCLI == .ready,
			geminiAvailable: status.geminiCLI == .ready,
			openCodeAvailable: false,
			cursorAvailable: status.cursorCLI == .ready,
			zaiConfigured: backendStore.isConfigured(.glmZAI) && backendStore.config(for: .glmZAI).isEnabled && backendStore.config(for: .glmZAI).isValid,
			kimiConfigured: backendStore.isConfigured(.kimi) && backendStore.config(for: .kimi).isEnabled && backendStore.config(for: .kimi).isValid,
			customClaudeCompatibleConfigured: backendStore.isConfigured(.custom) && backendStore.config(for: .custom).isEnabled && backendStore.config(for: .custom).isValid
		)
	}

	private func computeMCPAgentDefaultsRecommendation(
		workspaceID: UUID,
		actualStatus: ProviderStatusSnapshot,
		recommendedStatus: ProviderStatusSnapshot
	) -> MCPAgentDefaultsRecommendation? {
		let availability = mcpAgentAvailabilityContext(from: actualStatus)
		let recommendedAvailability = mcpAgentAvailabilityContext(from: recommendedStatus)
		let resolutions = MCPAgentRoleDefaultsService.resolutions(
			availability: availability,
			recommendedAvailability: recommendedAvailability,
			settingsStore: settingsStore
		)
		guard !resolutions.isEmpty else { return nil }

		let currentDefaults = resolutions.map { res -> MCPAgentRoleDefault in
			let model = AgentModel.resolvedModel(forRaw: res.effective.modelRaw, agentKind: res.effective.agent)
				?? AgentModel(rawValue: res.effective.modelRaw) ?? .defaultModel
			return MCPAgentRoleDefault(
				role: res.role,
				roleLabel: res.roleLabel,
				roleDescription: res.roleDescription,
				agent: res.effective.agent,
				model: model,
				modelDisplayName: res.effectiveDisplayName,
				selectionIDRaw: res.selectionID.rawValue
			)
		}

		let recommendedDefaults = resolutions.map { res -> MCPAgentRoleDefault in
			let model = AgentModel.resolvedModel(forRaw: res.recommended.modelRaw, agentKind: res.recommended.agent)
				?? AgentModel(rawValue: res.recommended.modelRaw) ?? .defaultModel
			let selID = AgentModelSelectionID(agentRaw: res.recommended.agent.rawValue, modelRaw: res.recommended.modelRaw)
			return MCPAgentRoleDefault(
				role: res.role,
				roleLabel: res.roleLabel,
				roleDescription: res.roleDescription,
				agent: res.recommended.agent,
				model: model,
				modelDisplayName: res.recommendedDisplayName,
				selectionIDRaw: selID.rawValue
			)
		}

		let alreadySatisfied = zip(currentDefaults, recommendedDefaults).allSatisfy {
			$0.selectionIDRaw == $1.selectionIDRaw
		}

		// Suggest upgrade if only some CLIs are available
		let upgradeHint: String? = {
			if recommendedStatus.codexCLI != .ready {
				return "Connect Codex CLI for GPT-5.5 Low (explore/discovery), GPT-5.5 Medium (engineer/default implementation and design fallback), and GPT-5.5 High (pair/Oracle)."
			}
			if recommendedStatus.claudeCodeCLI != .ready {
				return "Connect Claude Code for Claude Opus (design/pair). Best for architecture and creative work."
			}
			return nil
		}()

		var rec = MCPAgentDefaultsRecommendation(
			currentRoleDefaults: currentDefaults,
			recommendedRoleDefaults: recommendedDefaults,
			upgradeHint: upgradeHint
		)
		rec.alreadySatisfied = alreadySatisfied
		return rec
	}

	/// Apply MCP agent defaults by clearing all global overrides (revert to recommended).
	func applyMCPAgentDefaultsRecommendation(_ rec: MCPAgentDefaultsRecommendation, workspaceID: UUID) {
		MCPAgentRoleDefaultsService.clearAllOverrides(settingsStore: settingsStore)
	}
	
	    // MARK: - Apply Recommendations

	    /// Returns equivalent Codex model IDs for a recommended model raw string.
	    /// Example: gpt-5.2-codex-medium -> gpt-5.2-codex.
	    private func codexEquivalentModelCandidates(for rawModel: String) -> [String] {
	        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
	        guard !trimmed.isEmpty else { return [] }

	        var candidates: [String] = []
	        var seen = Set<String>()
	        func appendUnique(_ value: String) {
	            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
	            guard !normalized.isEmpty else { return }
	            let key = normalized.lowercased()
	            guard seen.insert(key).inserted else { return }
	            candidates.append(normalized)
	        }

	        appendUnique(trimmed)
	        let specifier = CodexModelSpecifier(raw: trimmed)
	        if let base = specifier.baseModel {
	            appendUnique(base)
	            if specifier.reasoningEffort == nil {
	                for effort in CodexReasoningEffort.displayOrder {
	                    appendUnique("\(base)-\(effort.rawValue)")
	                }
	            }
	        }
	        return candidates
	    }

	    /// Keeps recommendations hardcoded while resolving to an equivalent Codex dynamic model
	    /// when model/list data is available.
	    private func resolveContextBuilderRecommendedModelRaw(_ rec: ContextBuilderRecommendation) -> String {
	        let fallback = rec.recommendedModel.rawValue
	        guard rec.recommendedAgent == .codexExec else { return fallback }

	        let options = CodexDynamicModelStore.modelOptions()
	        guard !options.isEmpty else { return fallback }

	        var dynamicIDByLower: [String: String] = [:]
	        for option in options {
	            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
	            guard !id.isEmpty else { continue }
	            let key = id.lowercased()
	            if dynamicIDByLower[key] == nil {
	                dynamicIDByLower[key] = id
	            }
	        }

	        let fallbackSpecifier = CodexModelSpecifier(raw: fallback)
	        for candidate in codexEquivalentModelCandidates(for: fallback) {
	            guard let matched = dynamicIDByLower[candidate.lowercased()] else { continue }
	            let matchedSpecifier = CodexModelSpecifier(raw: matched)
	            // Preserve the recommended effort if it is explicit. Some app-server lists expose
	            // base IDs only (for example `gpt-5.3-codex`), which otherwise degrades UI mapping.
	            if fallbackSpecifier.reasoningEffort != nil && matchedSpecifier.reasoningEffort == nil {
	                continue
	            }
	            return matched
	        }

	        return fallback
	    }
	    
	    /// Apply chat model recommendation for a workspace.
	    /// Configures both built-in chat model and MCP planning model.
	    func applyChatModelRecommendation(_ rec: ChatModelRecommendation, backend: ChatBackendKind, workspaceID: UUID) {
        // Determine the model string based on backend choice
        // For CLI-driven backends (Claude Code), we use a reasonable default model
        let modelString: String
        
        switch backend {
        case .claudeCode:
            // Claude Code - Opus for chat
            modelString = rec.claudeCodeOption?.modelString ?? AIModel.claudeCodeOpus.rawValue
        case .codex:
            modelString = rec.codexOption?.modelString ?? AIModel.codexCliGpt55CodexHigh.rawValue
        case .openAI:
            modelString = rec.openAIOption?.modelString ?? AIModel.gpt54Pro.rawValue
        case .gemini:
            modelString = rec.geminiOption?.modelString ?? AIModel.geminiCliPro3p1Preview.rawValue
        }
        
		let reasonPrefix = "recommendations.chat_model.\(backend.rawValue)"
		if settingsStore.syncChatModelWithOracle() {
			settingsStore.setPlanningModelRaw(
				modelString,
				reason: "\(reasonPrefix).planning",
				honorSync: true
			)
		} else {
			// Set for built-in UI chat (preferredComposeModel)
			settingsStore.setPreferredComposeModelRaw(
				modelString,
				reason: "\(reasonPrefix).preferred_compose"
			)
			// Set for MCP default model (planningModel) - used when presets are off, hidden, or empty
			settingsStore.setPlanningModelRaw(
				modelString,
				reason: "\(reasonPrefix).planning"
			)
		}
        
        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }
    
    /// Apply context builder recommendation.
    /// Configures the Context Builder agent/model through global discovery settings only.
    func applyContextBuilderRecommendation(_ rec: ContextBuilderRecommendation, workspaceID _: UUID) {
        let resolvedModelRaw = resolveContextBuilderRecommendedModelRaw(rec)

        settingsStore.setGlobalDiscoverAgentSelection(
            agentRaw: rec.recommendedAgent.rawValue,
            modelRaw: resolvedModelRaw,
            markUserDefined: true  // Recommendations count as user-defined to prevent re-apply
        )
        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }
    
    /// Apply Pro Edit recommendation for a workspace.
	/// Configures Pro Edit mode (agent or model), agent kind, and model via GlobalSettingsStore.
    /// Users still control the proFileEdits toggle separately.
    func applyProEditRecommendation(_ rec: ProEditRecommendation, workspaceID: UUID) {
        switch rec.recommendedMode {
        case .agent:
            // Agent mode: use CLI agent for edits
            guard let agent = rec.recommendedAgent else {
                return
            }
            let model = rec.recommendedAgentModel ?? defaultProEditModel(for: agent)
			settingsStore.updateProEditSettings { snapshot in
				snapshot.agentMode = true
				snapshot.agentKindRaw = agent.rawValue
				snapshot.agentModelRaw = model?.rawValue
				// Mark migration as done so PromptVM's migrateToAgentModeIfNeeded won't re-run
				snapshot.agentModeMigrated = true
            }
            
        case .model:
            // Model mode: use API-based model editing (no CLI agent)
			settingsStore.updateProEditSettings { snapshot in
				snapshot.agentMode = false
				// Mark migration as done to prevent auto-migration to agent mode later
				snapshot.agentModeMigrated = true
			}
            
        case .disabled:
            // Nothing to configure - this is informational only
            // The wizard UI will guide users to set up providers
            return
        }
        
        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }
    
    /// Returns the default Pro Edit model for a given agent kind.
    /// Used as fallback when recommendedAgentModel is not set.
    private func defaultProEditModel(for agent: DiscoverAgentKind) -> AgentModel? {
        switch agent {
        case .claudeCode:
            return .claudeSonnet
		case .claudeCodeGLM:
			return .claudeSonnet
		case .kimiCode:
			return .kimiCode
		case .customClaudeCompatible:
			return .customClaudeCompatible
        case .codexExec:
			return .gpt55CodexMedium
        case .gemini:
            return .geminiPro3p1Preview
		case .openCode:
			return .defaultModel
		case .cursor:
			return .cursorAuto
        }
    }
    
	/// Apply every model-family recommendation in one pass.
	///
	/// Composes `applyChatModelRecommendation` + `applyContextBuilderRecommendation`
	/// + `applyMCPAgentDefaultsRecommendation` (and optionally `applyMCPPresetExposure`),
	/// then posts `.recommendationsDidApply` so listeners refresh. Intended for the
	/// "Apply Recommended Setup" button on the Agent Models settings page; callers
	/// that want row-level control should keep using the individual apply methods.
	///
	/// SEARCH-HELPER: Agent Models, Apply Recommended Setup, bulk apply
	func applyModelRecommendations(
		_ rec: RecommendationSet,
		workspaceID: UUID,
		includePresetExposure: Bool = false
	) {
		if let chat = rec.chatModel {
			applyChatModelRecommendation(chat, backend: chat.defaultBackend, workspaceID: workspaceID)
		}
		if let cb = rec.contextBuilder {
			applyContextBuilderRecommendation(cb, workspaceID: workspaceID)
		}
		if let agentDefaults = rec.mcpAgentDefaults {
			applyMCPAgentDefaultsRecommendation(agentDefaults, workspaceID: workspaceID)
		}
		if includePresetExposure, let presetExposure = rec.mcpPresetExposure {
			applyMCPPresetExposure(presetExposure)
		}

		NotificationCenter.default.post(
			name: .recommendationsDidApply,
			object: nil,
			userInfo: ["workspaceID": workspaceID]
		)
	}

    /// Apply MCP preset exposure recommendation.
    func applyMCPPresetExposure(_ rec: MCPPresetExposureRecommendation) {
        if rec.shouldTemporarilyDisablePresets {
            // Temporarily disable presets
			settingsStore.setMCPTemporarilyDisablePresets(true)
        } else {
            // Enable the preset feature section (turn on the main toggle)
			settingsStore.setMCPShowModelPresets(true)
            // Temporarily disable presets to show the MCP chat model dropdown directly
            // This guides users to use the recommended MCP chat model instead of arbitrary chat models
			settingsStore.setMCPTemporarilyDisablePresets(true)
        }
        
        // Note: Notification is posted by the caller (wizard) after all recommendations are applied
    }
    
    // MARK: - Auto-Apply for New Workspaces

    /// Auto-applies recommended defaults when global settings are not yet configured.
    /// Since discover agent/model are now GLOBAL (not per-workspace), this checks global settings.
    /// Returns true if any mutations were applied.
    @discardableResult
    func autoApplyRecommendationsIfEligible(for workspaceID: UUID) -> Bool {
        // Check GLOBAL settings for whether user has already configured discover agent
        // If global is already configured, don't auto-apply
        if settingsStore.hasUserSetGlobalDiscoverDefaults {
            return false
        }

        // Compute recommendations
        let recs = computeRecommendations(for: workspaceID)
        var didApply = false

        // Apply Context Builder recommendation if global not already configured
        if let cbRec = recs.contextBuilder,
           !cbRec.alreadySatisfied {
            applyContextBuilderRecommendation(cbRec, workspaceID: workspaceID)
            didApply = true
        }

        return didApply
    }

    // MARK: - Mute Management

    /// Check if a recommendation is muted for this workspace.
    func isMuted(_ kind: RecommendationKind, workspaceID: UUID) -> Bool {
        let settings = settingsStore.chatSettings(for: workspaceID)
        return settings.mutedRecommendationIDs?.contains(kind.rawValue) ?? false
    }
    
    /// Mute a recommendation for this workspace.
    func mute(_ kind: RecommendationKind, workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        var set = settings.mutedRecommendationIDs ?? []
        set.insert(kind.rawValue)
        settings.mutedRecommendationIDs = set
        settingsStore.updateChatSettings(settings, commit: true)
    }
    
    /// Unmute a recommendation for this workspace.
    func unmute(_ kind: RecommendationKind, workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.mutedRecommendationIDs?.remove(kind.rawValue)
        settingsStore.updateChatSettings(settings, commit: true)
    }

    /// Clear wizard dismissals and recent-completion state for this workspace.
    func resetWizardState(workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.mutedRecommendationIDs = nil
        settings.lastRecommendationWizardCompletedAt = nil
        settingsStore.updateChatSettings(settings, commit: true)
    }
    
    // MARK: - Completion Tracking
    
    /// Check if wizard was completed recently for this workspace.
    func hasCompletedRecently(workspaceID: UUID) -> Bool {
        let settings = settingsStore.chatSettings(for: workspaceID)
        guard let last = settings.lastRecommendationWizardCompletedAt else { return false }
        return Date().timeIntervalSince(last) < completionRecencyInterval
    }
    
    /// Mark wizard as completed for this workspace.
    func markWizardCompleted(workspaceID: UUID) {
        var settings = settingsStore.chatSettings(for: workspaceID)
        settings.lastRecommendationWizardCompletedAt = Date()
        settingsStore.updateChatSettings(settings, commit: true)
    }
    
    /// Filter out muted recommendations from a set.
    /// Mark muted recommendations with their isMuted flag (instead of filtering them out).
    func applyMutedFlags(_ set: RecommendationSet, workspaceID: UUID) -> RecommendationSet {
        var result = set
        
        if isMuted(.chatModel, workspaceID: workspaceID) {
            result.chatModel?.isMuted = true
        }
        if isMuted(.contextBuilderAgent, workspaceID: workspaceID) {
            result.contextBuilder?.isMuted = true
        }
        if isMuted(.proEditMode, workspaceID: workspaceID) {
            result.proEdit?.isMuted = true
        }
        if isMuted(.mcpPresetExposure, workspaceID: workspaceID) {
            result.mcpPresetExposure?.isMuted = true
        }
		if isMuted(.mcpAgentDefaults, workspaceID: workspaceID) {
			result.mcpAgentDefaults?.isMuted = true
		}
        
        return result
    }
    
    // MARK: - Satisfaction Checks

	private struct CodexChatModelIdentity {
		let baseModel: String
		let effort: CodexReasoningEffort
	}

	private func codexChatModelIdentity(for rawValue: String) -> CodexChatModelIdentity? {
		let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, let model = AIModel.fromModelName(trimmed), model.providerType == .codex else {
			return nil
		}

		let modelSpecifier = CodexModelSpecifier(raw: model.modelName)
		let rawSpecifier = CodexModelSpecifier(raw: trimmed)
		let unprefixedRawSpecifier: CodexModelSpecifier? = trimmed.hasPrefix("codex_cli_")
			? CodexModelSpecifier(raw: String(trimmed.dropFirst("codex_cli_".count)))
			: nil
		guard let baseModel = (modelSpecifier.baseModel ?? rawSpecifier.baseModel ?? unprefixedRawSpecifier?.baseModel)?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!baseModel.isEmpty
		else {
			return nil
		}
		guard let effort = CodexReasoningEffort.parse(model.defaultReasoningEffort)
			?? rawSpecifier.reasoningEffort
			?? unprefixedRawSpecifier?.reasoningEffort
			?? modelSpecifier.reasoningEffort
		else {
			return nil
		}
		return CodexChatModelIdentity(baseModel: baseModel.lowercased(), effort: effort)
	}

	private func effortRank(_ effort: CodexReasoningEffort) -> Int {
		CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? 0
	}

	private func chatModelSelection(_ currentRaw: String, satisfiesRecommended recommendedRaw: String) -> Bool {
		let current = currentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
		let recommended = recommendedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !current.isEmpty, !recommended.isEmpty else { return false }
		if current.caseInsensitiveCompare(recommended) == .orderedSame { return true }
		guard let currentCodex = codexChatModelIdentity(for: current),
			let recommendedCodex = codexChatModelIdentity(for: recommended),
			currentCodex.baseModel == recommendedCodex.baseModel
		else {
			return false
		}
		return effortRank(currentCodex.effort) >= effortRank(recommendedCodex.effort)
	}
    
	/// Check if chat model is already configured to match the current default recommendation.
	/// Lower-priority available backends do not satisfy this check, so newly connected
	/// higher-priority providers surface as recommendation upgrades.
    /// Checks both preferredComposeModel (UI chat) and planningModel (MCP default).
    private func isChatModelAlreadyConfigured(_ rec: ChatModelRecommendation) -> Bool {
		guard let recommendedModel = rec.option(for: rec.defaultBackend)?.modelString,
			!recommendedModel.isEmpty else {
			return false
		}

		let currentCompose = settingsStore.preferredComposeModelRaw() ?? ""
		let currentPlanning = settingsStore.planningModelRaw() ?? ""

		return chatModelSelection(currentCompose, satisfiesRecommended: recommendedModel)
			&& chatModelSelection(currentPlanning, satisfiesRecommended: recommendedModel)
    }
    
	/// Infer which chat backend is currently configured based on the stored model string.
    /// Returns nil if the current model doesn't match any of the available options.
    /// Prefers planningModel (MCP default) over preferredComposeModel for inference.
    func inferCurrentChatBackend(from rec: ChatModelRecommendation) -> ChatBackendKind? {
		let currentModel = settingsStore.planningModelRaw() ?? settingsStore.preferredComposeModelRaw()
        
        guard let current = currentModel, !current.isEmpty else { return nil }
        
		return rec.availableOptions.first(where: { option in
			guard let modelString = option.modelString else { return false }
			return chatModelSelection(current, satisfiesRecommended: modelString)
		})?.kind
    }
    
    /// Check if context builder is already configured to match the recommendation.
    /// Uses GLOBAL settings (not per-workspace) since discover agent/model are now global.
	    private func isContextBuilderAlreadyConfigured(
	        _ rec: ContextBuilderRecommendation,
	        settings: ChatGlobalSettings  // Parameter kept for API compatibility but not used
	    ) -> Bool {
	        let (globalAgentRaw, globalModelRaw) = settingsStore.globalDiscoverAgentSelection()
	        let agentMatch = globalAgentRaw == rec.recommendedAgent.rawValue
	        let modelMatch: Bool = {
	            guard let globalModelRaw else { return false }
	            if rec.recommendedAgent != .codexExec {
	                return globalModelRaw == rec.recommendedModel.rawValue
	            }

	            let globalNormalized = globalModelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	            guard !globalNormalized.isEmpty else { return false }

	            var accepted = Set(codexEquivalentModelCandidates(for: rec.recommendedModel.rawValue).map { $0.lowercased() })
	            accepted.insert(resolveContextBuilderRecommendedModelRaw(rec).lowercased())
	            return accepted.contains(globalNormalized)
	        }()
	        let satisfied = agentMatch && modelMatch
	        return satisfied
	    }
    
    /// Check if Pro Edit is already configured to match the recommendation.
    private func isProEditAlreadyConfigured(_ rec: ProEditRecommendation) -> Bool {
		let proEditSettings = settingsStore.proEditSettings()
		let agentMode = proEditSettings.agentMode
        
        switch rec.recommendedMode {
        case .agent:
            // Recommendation is agent mode with specific agent
            guard let expectedAgent = rec.recommendedAgent else {
                return false
            }
            
			let agentKindRaw = proEditSettings.agentKindRaw ?? ""
            let satisfied = agentMode && agentKindRaw == expectedAgent.rawValue
            return satisfied
            
        case .model:
            // Recommendation is model mode (API-based) - satisfied if agent mode is OFF
            let satisfied = !agentMode
            return satisfied
            
        case .disabled:
            // Recommendation is disabled - this is informational, always consider it "satisfied"
            // since there's nothing to configure
            return true
        }
    }
    
    /// Check if MCP preset exposure is already configured to match the recommendation.
    private func isMCPPresetExposureAlreadyConfigured(_ rec: MCPPresetExposureRecommendation) -> Bool {
		let showModelPresets = settingsStore.mcpShowModelPresets()
		let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()
        
        // If recommendation is to enable the whole feature (shouldTemporarilyDisablePresets = false),
        // check if both showModelPresets AND temporarilyDisabled are true
        // (we enable presets but show MCP chat model dropdown directly)
        if !rec.shouldTemporarilyDisablePresets {
            let satisfied = showModelPresets && temporarilyDisabled
            return satisfied
        }
        
        // If recommendation is to just enable temp disable (shouldTemporarilyDisablePresets = true),
        // presets toggle is already on, just check if temp disable is on
        let satisfied = temporarilyDisabled
        return satisfied
    }
}
