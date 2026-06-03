import Foundation

/// Chat modes available for chat presets - renamed to avoid conflict with existing ChatMode
enum ChatPresetMode: String, Codable, CaseIterable {
    case chat
    case plan
    case edit
    case proEdit  // Pro Edit capabilities
    case review   // Code review mode with git diff context
    
    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .plan: return "Plan"
        case .edit: return "Edit"
        case .proEdit: return "Pro Edit"
        case .review: return "Review"
        }
    }
    
    var description: String {
        switch self {
        case .chat: return "General discussion and queries"
        case .plan: return "Architecture and implementation planning"
        case .edit: return "Direct code modifications"
        case .proEdit: return "Advanced code modifications using configured edit agents or models"
        case .review: return "Code review with git diff context"
        }
    }
}

/// Chat preset configuration linking chat mode, model preset, and context strategy
struct ChatPreset: Identifiable, Equatable {
    let id: UUID
    let name: String
    let mode: ChatPresetMode
    
    /// Optional model specification - can be AIModel rawValue or model preset name
    /// If set, this model will be used when the preset is active
    var modelPresetName: String?
    
    let description: String?
    let icon: String?
    let isBuiltIn: Bool
    
    /// File tree, code map, and git settings
    var fileTreeMode: FileTreeOption?
    var codeMapUsage: CodeMapUsage?
    var gitInclusion: GitInclusion?
    
    /// Stored prompt IDs for meta-instructions
    var storedPromptIds: [UUID]?

	/// NEW: When true and there is exactly one stored prompt ID available (directly or via override),
	/// that stored prompt will be injected as the <system prompt> instead of as meta.
	var useStoredPromptsAsSystem: Bool?  // default nil -> treated as false
    
    // MARK: - Initializer
    init(
        id: UUID = UUID(),
        name: String,
        mode: ChatPresetMode,
        modelPresetName: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        isBuiltIn: Bool = false,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
		storedPromptIds: [UUID]? = nil,
		useStoredPromptsAsSystem: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.modelPresetName = modelPresetName
        self.description = description
        self.icon = icon
        self.isBuiltIn = isBuiltIn
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.storedPromptIds = storedPromptIds
		self.useStoredPromptsAsSystem = useStoredPromptsAsSystem
    }
}

// MARK: - Codable Conformance

extension ChatPreset: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case modelPresetName
        case description
        case icon
        case isBuiltIn
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case storedPromptIds
		case useStoredPromptsAsSystem
    }
}

// MARK: - Built-in Chat Presets

extension ChatPreset {
    /// Built-in chat presets with stable UUIDs
    struct BuiltIn {
        // Stable UUIDs for built-in chat presets
        private static let manualUUID = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
        private static let chatUUID = UUID(uuidString: "A1111111-1111-1111-1111-111111111111")!
        private static let planUUID = UUID(uuidString: "A2222222-2222-2222-2222-222222222222")!
        private static let editUUID = UUID(uuidString: "A3333333-3333-3333-3333-333333333333")!
        private static let proEditUUID = UUID(uuidString: "A3333334-3334-3334-3334-333333333334")!
		static let reviewUUID = UUID(uuidString: "A4444444-4444-4444-4444-444444444444")!
		private static let architectPromptId = UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!
		private static let reviewPromptId = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!
        private static let mcpAgentUUID = UUID(uuidString: "A5555555-5555-5555-5555-555555555555")!
        private static let mcpPairUUID = UUID(uuidString: "A6666666-6666-6666-6666-666666666666")!
        private static let mcpPlanUUID = UUID(uuidString: "A7777777-7777-7777-7777-777777777777")!
        
        /// Manual preset - Full UI control
        static let manual = ChatPreset(
            id: manualUUID,
            name: "Manual",
            mode: ChatPresetMode.chat,
            description: "Full control - all settings visible",
            icon: "⚙️",
            isBuiltIn: true,
            fileTreeMode: nil,  // nil = use current UI settings
            codeMapUsage: nil,  // nil = use current UI settings
            gitInclusion: nil   // nil = use current UI settings
        )
        
        /// General chat preset
        static let chat = ChatPreset(
            id: chatUUID,
            name: "Chat",
            mode: ChatPresetMode.chat,
            description: "General discussion, Q&A, and code exploration",
            icon: "💬",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none
        )
        
        /// Planning preset
        static let plan = ChatPreset(
            id: planUUID,
            name: "Plan",
            mode: ChatPresetMode.plan,
            description: "Design architecture and plan implementation steps",
            icon: "📋",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
			gitInclusion: GitInclusion.none,
			storedPromptIds: []  // Plan mode uses hardcoded architect system prompt
        )
        
        /// Edit preset
        static let edit = ChatPreset(
            id: editUUID,
            name: "Edit",
            mode: ChatPresetMode.edit,
            description: "Direct code modifications",
            icon: "✏️",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none
        )
        
        /// Pro Edit preset
        static let proEdit = ChatPreset(
            id: proEditUUID,
            name: "Pro Edit",
            mode: ChatPresetMode.proEdit,
            description: "Advanced code modifications using configured edit agents or models",
            icon: "⚡",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
			gitInclusion: GitInclusion.none,
			storedPromptIds: []  // Uses XML system prompt, not stored prompt
        )
        
		/// Code review preset - uses stored [Review] prompt as the system prompt (configured, not hard-coded)
        static let review = ChatPreset(
            id: reviewUUID,
            name: "Review",
            mode: ChatPresetMode.review,
            description: "Review code changes with git diff context",
            icon: "🔍",
            isBuiltIn: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: .selected,  // Include selected git diffs for review
			storedPromptIds: [reviewPromptId],
			useStoredPromptsAsSystem: true
        )
        
        /// All built-in chat presets
        static var all: [ChatPreset] {
            [manual, chat, plan, edit, proEdit, review]
        }
    }
}
