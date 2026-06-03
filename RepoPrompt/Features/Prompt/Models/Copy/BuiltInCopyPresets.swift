import Foundation

/// Built-in copy preset definitions with stable UUIDs
enum BuiltInCopyPresets {
    
    // MARK: - Stored Prompt UUIDs (from PromptViewModel)
    // These are the UUIDs of the stored prompts we want to reference
    private static let architectPromptId = UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!
    private static let engineerPromptId = UUID(uuidString: "4798D902-CC16-4B5B-8859-27CCF93151BC")!
    private static let mcpPairProgramPromptId = UUID(uuidString: "A7E8F2C1-3D5B-4E9A-BC6D-8F2A7C9E1D3B")!
    private static let mcpAgentPromptId = UUID(uuidString: "B5F9D8E2-4C6A-5F0B-AD7E-9F3B8D0E2C4A")!
    private static let mcpPlanPromptId = UUID(uuidString: "C6E8A1D3-2B4F-5A9C-BE7D-0F4C9D1E3B5A")!
    private static let reviewPromptId = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!
    
    // MARK: - Stable UUID constants
    // These UUIDs are generated once and kept stable for migration purposes
    private static let standardUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static let planUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let manualUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let editXMLUUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let proEditUUID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let diffFollowUpUUID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let codeReviewUUID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private static let mcpAgentUUID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private static let mcpPairUUID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private static let mcpPlanUUID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private static let mcpBuilderUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    
    // MARK: - Built-in Preset Definitions
    
    /// Standard preset - Default balanced configuration
    static let standard = CopyPreset(
        id: standardUUID,
        name: "Standard",
        builtInKind: .standard,
        description: "Balanced configuration for general use",
        icon: "📄",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false,  // No stored prompts
        includeFileTree: true,
        xmlFormat: nil,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: nil,
        storedPromptIds: []  // No stored prompts
    )
    
    /// Plan preset - Architecture & design
    static let plan = CopyPreset(
        id: planUUID,
        name: "Plan",
        builtInKind: .plan,
        description: "Architecture design and implementation planning",
        icon: "🏗️",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: true,
        includeFileTree: true,
        xmlFormat: nil,  // No XML for planning
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: nil,
        storedPromptIds: [architectPromptId]  // Reference the [Architect] stored prompt
    )
    
    /// Manual preset - Full control (uses current UI state)
    static let manual = CopyPreset(
        id: manualUUID,
        name: "Manual",
        builtInKind: .manual,
        description: "Full control - use current settings",
        icon: "⚙️",
        isBuiltIn: true,
        includeFiles: nil,  // All nil = use current UI state
        includeUserPrompt: nil,
        includeMetaPrompts: nil,
        includeFileTree: nil,
        xmlFormat: nil,
        fileTreeMode: nil,
        codeMapUsage: nil,
        gitInclusion: nil,  // nil = use current UI state
        systemPromptFlavor: nil
    )
    
    /// Edit XML preset - XML diff format for code edits
    static let editXML = CopyPreset(
        id: editXMLUUID,
        name: "XML Edit",
        builtInKind: .editXML,
        description: "Multi-file edits with search-replace XML blocks for reviewable diffs",
        icon: "📝",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false,  // Usually not needed for edits
        includeFileTree: true,
        xmlFormat: .diff,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: .codeEditDiff  // Keep system prompt for XML formatting
    )
    
    /// Pro Edit preset - Parallel architect apply
    static let proEdit = CopyPreset(
        id: proEditUUID,
        name: "XML Pro Edit",
        builtInKind: .proEdit,
        description: "Delegates file edits to configured edit agents or models for efficiency and accuracy",
        icon: "⚡",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false,
        includeFileTree: true,
        xmlFormat: .architect,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: .architectPlan,  // Use architect flavor for Pro Edit XML formatting
        storedPromptIds: []  // System flavor provides the XML formatting instructions
    )
    
    /// Diff Follow-Up preset - Git-only context for follow-up discussions
    static let diffFollowUp = CopyPreset(
        id: diffFollowUpUUID,
        name: "Diff Follow-Up",
        builtInKind: .diffFollowUp,
        description: "Git diff only - discuss recent changes",
        icon: "↪︎",
        isBuiltIn: true,
        includeFiles: false,  // No files
        includeUserPrompt: true,  // Include user instructions
        includeMetaPrompts: false,
        includeFileTree: false,
        xmlFormat: nil,
        fileTreeMode: FileTreeOption.none,
        codeMapUsage: CodeMapUsage.none,
        gitInclusion: .selected,  // Git diff is the focus
        systemPromptFlavor: nil
    )
    
    /// Code Review preset - Review with git diff
    static let codeReview = CopyPreset(
        id: codeReviewUUID,
        name: "Review",
        builtInKind: .codeReview,
        description: "Thorough code review focusing on quality and regressions",
        icon: "🔍",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: true,
        includeFileTree: true,
        xmlFormat: nil,
        fileTreeMode: .auto,
        codeMapUsage: .auto,
        gitInclusion: .selected,  // Include git diff for review
        systemPromptFlavor: nil,
        storedPromptIds: [reviewPromptId]  // Reference the [Review] stored prompt
    )
    
    /// MCP Agent preset - Agent + codemaps
    static let mcpAgent = CopyPreset(
        id: mcpAgentUUID,
        name: "MCP Agent",
        builtInKind: .mcpAgent,
        description: "Codemaps only (compressed file structure) to minimize tokens",
        icon: "🤖",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: true,  // MCP directives
        includeFileTree: true,
        xmlFormat: nil,
        fileTreeMode: .selected,  // Show selected files
        codeMapUsage: .selected,  // Compress to codemaps
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: .mcpAgent,  // Built-in immutable system prompt
        storedPromptIds: []  // Use built-in system prompt instead of stored prompt
    )
    
    /// MCP Pair preset - Pair programming
    static let mcpPair = CopyPreset(
        id: mcpPairUUID,
        name: "MCP Pair",
        builtInKind: .mcpPair,
        description: "Chat pair programming with codemaps instead of file content",
        icon: "👥",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: true,  // MCP directives
        includeFileTree: true,
        xmlFormat: nil,
        fileTreeMode: .selected,
        codeMapUsage: .selected,  // Compress to codemaps
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: .mcpPairProgram,  // Built-in immutable system prompt
        storedPromptIds: []  // System flavor provides the full prompt
    )
    
    /// MCP Discover preset - Discovery and documentation
    static let mcpPlan = CopyPreset(
        id: mcpPlanUUID,
        name: "MCP Discover",
        builtInKind: .mcpPlan,
        description: "Planning docs using codemaps - agent explores files directly",
        icon: "🗺️",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false, // Do not allow additional stored prompts with Discover
        includeFileTree: true,
        xmlFormat: nil,
        fileTreeMode: .selected,
        codeMapUsage: .selected,  // Compress to codemaps
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: .mcpDiscover,
        storedPromptIds: []  // System flavor provides the full prompt
    )
    
    /// MCP Builder preset - Context builder-driven implementation workflow
    static let mcpBuilder = CopyPreset(
        id: mcpBuilderUUID,
        name: "MCP Builder",
        builtInKind: .mcpBuilder,
        description: "Deep context + plan via context_builder, implement directly",
        icon: "🔨",
        isBuiltIn: true,
        includeFiles: true,
        includeUserPrompt: true,
        includeMetaPrompts: false, // System prompt provides full guidance
        includeFileTree: true,
        xmlFormat: nil,
        fileTreeMode: .auto,      // Auto tree for broad codebase visibility in quick scan
        codeMapUsage: .selected,  // Compress to codemaps for initial context
        gitInclusion: GitInclusion.none,
        systemPromptFlavor: .mcpBuilder,
        storedPromptIds: [],  // System flavor provides the full prompt
        includeMCPMetadata: true  // Include MCP metadata for tool access
    )
    
    // MARK: - Collection of all built-in presets
    
    /// All built-in presets in a logical order
    static var all: [CopyPreset] {
        [standard, plan, diffFollowUp, codeReview, editXML, proEdit, mcpAgent, mcpPair, mcpPlan, mcpBuilder, manual]
    }
    
    /// Find a built-in preset by its kind
    static func preset(for kind: CopyPresetKind) -> CopyPreset? {
        all.first { $0.builtInKind == kind }
    }
    
    /// Find a built-in preset by ID
    static func preset(with id: UUID) -> CopyPreset? {
        all.first { $0.id == id }
    }
}
