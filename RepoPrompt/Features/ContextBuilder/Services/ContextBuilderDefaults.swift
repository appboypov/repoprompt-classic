import Foundation

/// Controls how the Discover agent handles the user's original prompt
enum PromptEnhancementMode: String, Codable, CaseIterable {
	case fullRewrite  // Agent rewrites prompt from discoveries
	case augment      // Preserve original + add context
	case preserve     // Don't touch the prompt at all
}

/// Centralized default values for the Context Builder / Discovery Agent.
/// Update these values to change defaults across the entire app.
enum ContextBuilderDefaults {
    // MARK: - Token Budgets
    
    /// Default token budget for discovery runs (UI slider default)
    static let discoveryTokenBudget: Int = 160_000
    
    /// Default token budget for plan generation
    static let planTokenBudget: Int = 120_000
    
    // MARK: - Enhancement Mode
    
    /// Default prompt enhancement mode
    static let enhancementMode: PromptEnhancementMode = .fullRewrite
    
    // MARK: - Clarifying Questions
    
    /// Whether clarifying questions are allowed by default (UI-triggered discovery)
    static let allowClarifyingQuestions: Bool = true
    
    /// Whether clarifying questions are allowed for MCP-triggered discovery
    static let allowClarifyingQuestionsForMCP: Bool = false
    
	/// Default timeout (in seconds) for user responses to clarifying questions
	static let questionTimeoutSeconds: TimeInterval = 300
	
    // MARK: - Plan Generation
    
    /// Whether to auto-generate plan after discovery completes
    static let autoGeneratePlan: Bool = false
}
