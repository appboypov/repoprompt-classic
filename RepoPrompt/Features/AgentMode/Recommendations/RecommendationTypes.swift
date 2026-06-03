import Foundation

// MARK: - Recommendation Kind

/// Identifies distinct recommendation categories for the auto-recommendation wizard.
enum RecommendationKind: String, Codable, CaseIterable, Sendable {
    case chatModel
    case contextBuilderAgent
    case proEditMode
    case mcpPresetExposure
    case mcpAgentDefaults
}

// MARK: - Recommendation Providers

/// Providers the recommendation wizard can consider when choosing models and agents.
enum RecommendationProviderKind: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case cursor
    case openAI
    case geminiCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .cursor: return "Cursor CLI"
        case .openAI: return "OpenAI API"
        case .geminiCLI: return "Gemini CLI"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .openAI: return "OpenAI"
        case .geminiCLI: return "Gemini CLI"
        }
    }
}

// MARK: - Provider Status

/// Snapshot of provider availability without network calls.
struct ProviderStatusSnapshot: Sendable {
    enum Availability: Sendable, Equatable {
        case notConfigured  // No key/connection present
        case configured     // Key present or CLI installed flag set
        case ready          // Verified key or successful connection test
    }
    
    let claudeCodeCLI: Availability
    let codexCLI: Availability
    let geminiCLI: Availability
    let cursorCLI: Availability
    
    let openAI: Availability
    
    /// Returns true if at least one provider is ready for chat.
    var hasAnyReadyProvider: Bool {
        [claudeCodeCLI, codexCLI, cursorCLI, openAI, geminiCLI].contains(.ready)
    }
    
    /// Returns true if any CLI agent is ready.
    var hasAnyCLIAgentReady: Bool {
        [claudeCodeCLI, codexCLI, geminiCLI, cursorCLI].contains(.ready)
    }

    /// Returns true if any Pro Edit-compatible CLI agent is ready.
    /// Cursor is intentionally excluded because RepoPrompt cannot sandbox Cursor's native tools.
    var hasAnyProEditCLIAgentReady: Bool {
        [claudeCodeCLI, codexCLI, geminiCLI].contains(.ready)
    }

    /// Returns a copy with providers outside the enabled set treated as unavailable.
    func filtered(to enabledProviders: Set<RecommendationProviderKind>) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            claudeCodeCLI: enabledProviders.contains(.claudeCode) ? claudeCodeCLI : .notConfigured,
            codexCLI: enabledProviders.contains(.codex) ? codexCLI : .notConfigured,
            geminiCLI: enabledProviders.contains(.geminiCLI) ? geminiCLI : .notConfigured,
            cursorCLI: enabledProviders.contains(.cursor) ? cursorCLI : .notConfigured,
            openAI: enabledProviders.contains(.openAI) ? openAI : .notConfigured
        )
    }
}

// MARK: - Chat Backend

/// Identifies the backend type for chat model recommendations.
enum ChatBackendKind: String, Codable, Sendable {
    case claudeCode
    case codex
    case openAI
    case gemini
    
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .openAI: return "OpenAI API"
        case .gemini: return "Gemini"
        }
    }
}

/// Represents a selectable chat backend option with its recommended model.
struct ChatBackendOption: Sendable {
    let kind: ChatBackendKind
    let displayName: String
    let modelString: String?
    let description: String
    
    /// Tradeoff points shown in the UI.
    let tradeoffs: [String]
}

// MARK: - Recommendation DTOs

/// Recommendation for which chat model/backend to use.
struct ChatModelRecommendation: Sendable {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false
    
    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false
    
    /// The default backend selection based on priority rules.
    let defaultBackend: ChatBackendKind
    
    /// Option for Codex CLI, if available.
    let codexOption: ChatBackendOption?
    
    /// Option for OpenAI API, if available.
    let openAIOption: ChatBackendOption?
    
    /// Option for Claude Code CLI, if available.
    let claudeCodeOption: ChatBackendOption?
    
    /// Option for Gemini, if available.
    let geminiOption: ChatBackendOption?
    
    /// Priority path used to determine the default (e.g., ["OpenAI API", "Codex CLI"]).
    let priorityPath: [String]
    
    /// Optional hint to show user how to upgrade to a better setup.
    let upgradeHint: String?
    
    /// Returns all available options.
    var availableOptions: [ChatBackendOption] {
        [openAIOption, codexOption, claudeCodeOption, geminiOption].compactMap { $0 }
    }

    /// Returns the option for a specific backend kind.
    func option(for kind: ChatBackendKind) -> ChatBackendOption? {
        switch kind {
        case .claudeCode: return claudeCodeOption
        case .codex: return codexOption
        case .openAI: return openAIOption
        case .gemini: return geminiOption
        }
    }
    
    init(defaultBackend: ChatBackendKind, codexOption: ChatBackendOption?, openAIOption: ChatBackendOption?, claudeCodeOption: ChatBackendOption?, geminiOption: ChatBackendOption?, priorityPath: [String], upgradeHint: String? = nil) {
        self.defaultBackend = defaultBackend
        self.codexOption = codexOption
        self.openAIOption = openAIOption
        self.claudeCodeOption = claudeCodeOption
        self.geminiOption = geminiOption
        self.priorityPath = priorityPath
        self.upgradeHint = upgradeHint
    }
}

/// Recommendation for context builder agent configuration.
struct ContextBuilderRecommendation: Sendable {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false
    
    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false
    
    let recommendedAgent: DiscoverAgentKind
    let recommendedModel: AgentModel
    let rationale: String
    /// Optional hint to show user how to upgrade to a better setup.
    let upgradeHint: String?
    
    init(recommendedAgent: DiscoverAgentKind, recommendedModel: AgentModel, rationale: String, upgradeHint: String? = nil) {
        self.recommendedAgent = recommendedAgent
        self.recommendedModel = recommendedModel
        self.rationale = rationale
        self.upgradeHint = upgradeHint
    }
}

/// Pro Edit mode types.
enum ProEditModeKind: String, Codable, Sendable {
    /// Use CLI agent (Claude Code, Codex, Gemini) for edits
    case agent
    /// Use model-based editing via API
    case model
    /// Pro Edit not recommended (no providers available)
    case disabled
}

/// Recommendation for pro edit mode configuration.
struct ProEditRecommendation: Sendable {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false
    
    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false
    
    /// Whether Pro Edit should be enabled at all.
    let shouldEnableProEdit: Bool
    
    /// The recommended mode: agent (CLI) or model (API-based).
    let recommendedMode: ProEditModeKind
    
    let rationale: String
    
    /// Recommended agent for pro edit when mode is .agent.
    let recommendedAgent: DiscoverAgentKind?
    
    /// Recommended model for the agent (when mode is .agent).
    let recommendedAgentModel: AgentModel?
    
    /// Upgrade hint to encourage adding CLI providers.
    let upgradeHint: String?
    
    init(
        shouldEnableProEdit: Bool,
        recommendedMode: ProEditModeKind = .disabled,
        rationale: String,
        recommendedAgent: DiscoverAgentKind? = nil,
        recommendedAgentModel: AgentModel? = nil,
        upgradeHint: String? = nil
    ) {
        self.shouldEnableProEdit = shouldEnableProEdit
        self.recommendedMode = recommendedMode
        self.rationale = rationale
        self.recommendedAgent = recommendedAgent
        self.recommendedAgentModel = recommendedAgentModel
        self.upgradeHint = upgradeHint
    }
}

/// Resolved default for a single MCP agent role.
struct MCPAgentRoleDefault: Sendable, Equatable {
    let role: AgentModelCatalog.TaskLabelKind
    let roleLabel: String
    let roleDescription: String
    let agent: DiscoverAgentKind
    let model: AgentModel
    let modelDisplayName: String
    /// Compound selection ID (e.g. "codexExec:gpt-5.4-mini-high").
    let selectionIDRaw: String
}

/// Recommendation for MCP agent role defaults (explore, engineer, pair, design).
struct MCPAgentDefaultsRecommendation: Sendable {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false

    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false

    /// Current effective defaults per role (may include user overrides).
    let currentRoleDefaults: [MCPAgentRoleDefault]

    /// Recommended defaults per role (no overrides).
    let recommendedRoleDefaults: [MCPAgentRoleDefault]

    /// Upgrade hint when not all CLIs are configured.
    let upgradeHint: String?
}

/// Recommendation for MCP preset exposure.
struct MCPPresetExposureRecommendation: Sendable {
    /// Whether this recommendation is already satisfied by current settings.
    var alreadySatisfied: Bool = false
    
    /// Whether the user has muted this recommendation.
    var isMuted: Bool = false
    
    /// If true, presets should be temporarily hidden to use MCP chat model selector.
    let shouldTemporarilyDisablePresets: Bool
    let rationale: String
}

/// Container for all recommendations for a workspace.
struct RecommendationSet: Sendable {
    var chatModel: ChatModelRecommendation?
    var contextBuilder: ContextBuilderRecommendation?
    var proEdit: ProEditRecommendation?
    var mcpPresetExposure: MCPPresetExposureRecommendation?
    var mcpAgentDefaults: MCPAgentDefaultsRecommendation?
    
    /// Returns true if any recommendation is present.
    var hasAny: Bool {
        chatModel != nil || contextBuilder != nil || proEdit != nil || mcpPresetExposure != nil || mcpAgentDefaults != nil
    }
    
    /// Number of recommendations that need action (not already satisfied and not muted).
    var actionableUnsatisfiedCount: Int {
        var count = 0
        if let chat = chatModel, !chat.alreadySatisfied, !chat.isMuted { count += 1 }
        if let cb = contextBuilder, !cb.alreadySatisfied, !cb.isMuted { count += 1 }
        if let pro = proEdit, !pro.alreadySatisfied, !pro.isMuted { count += 1 }
        if let mcp = mcpPresetExposure, !mcp.alreadySatisfied, !mcp.isMuted { count += 1 }
        if let agentDefaults = mcpAgentDefaults, !agentDefaults.alreadySatisfied, !agentDefaults.isMuted { count += 1 }
        return count
    }

    /// Returns true if any recommendation needs action (not already satisfied and not muted).
    var hasUnsatisfied: Bool {
        actionableUnsatisfiedCount > 0
    }
    
    /// Returns true if any recommendation is muted but differs from recommended.
    var hasMutedDifferences: Bool {
        if let chat = chatModel, chat.isMuted, !chat.alreadySatisfied { return true }
        if let cb = contextBuilder, cb.isMuted, !cb.alreadySatisfied { return true }
        if let pro = proEdit, pro.isMuted, !pro.alreadySatisfied { return true }
        if let mcp = mcpPresetExposure, mcp.isMuted, !mcp.alreadySatisfied { return true }
        if let agentDefaults = mcpAgentDefaults, agentDefaults.isMuted, !agentDefaults.alreadySatisfied { return true }
        return false
    }
}

// MARK: - Best Practice Profiles (May 2026)

/// Canonical best practice recommendations, versioned by date.
/// Update `versionCode` when recommendations change significantly.
struct BestPracticeProfiles {
    /// Bump when the table changes (used for gating mutes/badge).
    /// Format: YYYYMM
    static let versionCode: Int = 202607
    static let tableTitle = "Best Models by Use Case (GPT-5.5)"
    
    struct UseCase: Sendable {
        let id: String
        let title: String
        let modelLabel: String
        let accessLabel: String
        /// Canonical model identifier for direct API where applicable.
        let modelString: String?
        /// Optional Discover agent kind for CLI-style agents.
        let agentKind: DiscoverAgentKind?
        /// Optional Discover agent model.
        let agentModel: AgentModel?
        /// Strengths/reasons for this recommendation.
        let strengths: [String]
    }
    
    // MARK: Use Cases
    
    static let bestAgent = UseCase(
        id: "bestAgent",
        title: "Best Agent",
        modelLabel: "GPT-5.5 Medium",
        accessLabel: "Codex CLI",
        modelString: "gpt-5.5-medium",
        agentKind: .codexExec,
        agentModel: .gpt55CodexMedium,
        strengths: [
            "Balanced default for engineer agents and implementation",
            "Stronger reasoning during agentic tool use than Low",
            "Lower usage burn than GPT-5.5 High",
            "Codex-only GPT-5.5 via Codex CLI"
        ]
    )
    
    static let bestPlanning = UseCase(
        id: "bestPlanning",
        title: "Best Planning",
        modelLabel: "GPT-5.5 Pro",
        accessLabel: "OpenAI API / ChatGPT Pro export",
        modelString: AIModel.gpt54Pro.rawValue,
        agentKind: nil,
        agentModel: nil,
        strengths: [
            "API-backed planning and review in RepoPrompt",
            "Extended reasoning time produces thorough analysis",
            "Can reason about entire codebases at once",
            "Produces clear, actionable architectural specifications",
            "Catches edge cases and implications other models miss"
        ]
    )
    
    static let bestInAppPlanningReview = UseCase(
        id: "bestInAppPlanningReview",
        title: "Best In‑App Planning/Review",
        modelLabel: "GPT-5.5 High",
        accessLabel: "Codex CLI",
        modelString: AIModel.codexCliGpt55CodexHigh.rawValue,
        agentKind: .codexExec,
        agentModel: .gpt55CodexHigh,
        strengths: [
            "Strong reasoning without extended wait times",
            "Won't exhaust weekly usage limits quickly",
            "Excellent diff generation",
            "XHigh available when maximum reasoning is needed"
        ]
    )
    
    static let bestContextBuilder = UseCase(
        id: "bestContextBuilder",
        title: "Best Context Builder",
        modelLabel: "GPT-5.5 Low",
        accessLabel: "Codex CLI",
        modelString: "gpt-5.5-low",
        agentKind: .codexExec,
        agentModel: .gpt55CodexLow,
        strengths: [
            "Strong codebase understanding",
            "Efficient file exploration and selection",
            "Lower usage burn than higher GPT-5.5 efforts",
            "Practical default for repeated discovery runs"
        ]
    )
    
    static let all: [UseCase] = [
        bestAgent,
        bestPlanning,
        bestInAppPlanningReview,
        bestContextBuilder
    ]
    
    // MARK: Model Strength Summary
    
    static let claudeStrengths = """
        Claude Opus 4.6 remains great for editing-heavy work and careful file modifications. \
        GPT-5.5 Low via Codex CLI is our default recommendation for explore/discovery, and GPT-5.5 Medium is the default for engineer agents and implementation.
        """
    
    static let gpt5HighStrengths = """
        GPT-5.5 Low/Medium/High via Codex CLI provides strong reasoning without extended wait times. \
        Low is recommended for explore and discovery, Medium for engineer/default implementation, and High for Oracle, review, and pair agents. \
        XHigh offers maximum reasoning but can exhaust usage limits quickly.
        """
    
    static let geminiStrengths = """
        Gemini 3.1 Pro excels at design and creative discussions. \
        Gemini 3.0 Flash is the preferred Gemini option for fast exploration.
        """
    
    // MARK: Explanatory Text
    
    static let codexVsOpenAIExplanation = """
        GPT-5.5 is available in RepoPrompt through two separate paths: OpenAI API for GPT-5.5/GPT-5.5 Pro chat, planning, and review; and Codex CLI for GPT-5.5 Low/Medium/High agentic workflows.

        Use GPT‑5.5 Low via Codex CLI for Context Builder discovery and explore, \
        GPT‑5.5 Medium via Codex CLI for engineer/default implementation work, GPT‑5.5 High via Codex CLI for Oracle, review, and pair-agent work, and OpenAI API GPT‑5.5 Pro for API-backed in-app planning and review. OpenRouter support is separate and not implied by this recommendation.
        """
    
    static let contextBuilderRationale = "Codex with GPT-5.5 Low provides the best Context Builder/discovery default – strong codebase exploration with practical usage burn."

    static let contextWindowNote = """
        You can use xhigh for context building, but context windows are finite, \
        and reasoning takes space. Prefer GPT-5.5 Low for prompt and context building, \
        then let GPT-5.5 High reason in full when needed.
        """
    
    static let codexHarnessNote = """
        This works best with the API, as the model served in the Codex harness \
        has capped reasoning time.
        """
}
