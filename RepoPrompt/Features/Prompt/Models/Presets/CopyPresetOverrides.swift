import Foundation

/// Stores user overrides for built-in copy presets
/// Only non-nil fields represent changes from the base preset
struct CopyPresetOverrides: Codable, Equatable {
    let presetID: UUID
    var includeFiles: Bool?
    var includeUserPrompt: Bool?
    var includeMetaPrompts: Bool?
    var includeFileTree: Bool?
    var xmlFormat: ApplyPromptFormat?
    var fileTreeMode: FileTreeOption?
    var codeMapUsage: CodeMapUsage?
    var gitInclusion: GitInclusion?
    var systemPromptFlavor: SystemPromptFlavor?
    var storedPromptIds: [UUID]?
    var includeMCPMetadata: Bool?
    var updatedAt: Date?
    
    private enum CodingKeys: String, CodingKey {
        case presetID
        case includeFiles
        case includeUserPrompt
        case includeMetaPrompts
        case includeFileTree
        case xmlFormat
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case systemPromptFlavor
        case storedPromptIds
        case includeMCPMetadata
        case updatedAt
    }
    
    /// Returns true if no overrides are set
    var isEmpty: Bool {
        includeFiles == nil &&
        includeUserPrompt == nil &&
        includeMetaPrompts == nil &&
        includeFileTree == nil &&
        xmlFormat == nil &&
        fileTreeMode == nil &&
        codeMapUsage == nil &&
        gitInclusion == nil &&
        systemPromptFlavor == nil &&
        storedPromptIds == nil &&
        includeMCPMetadata == nil
    }
    
    /// Returns a copy with only fields that differ from the base preset
    func trimmed(against base: CopyPreset) -> CopyPresetOverrides {
        var trimmed = self
        
        // Set fields to nil if they match the base
        if trimmed.includeFiles == base.includeFiles {
            trimmed.includeFiles = nil
        }
        if trimmed.includeUserPrompt == base.includeUserPrompt {
            trimmed.includeUserPrompt = nil
        }
        if trimmed.includeMetaPrompts == base.includeMetaPrompts {
            trimmed.includeMetaPrompts = nil
        }
        if trimmed.includeFileTree == base.includeFileTree {
            trimmed.includeFileTree = nil
        }
        if trimmed.xmlFormat == base.xmlFormat {
            trimmed.xmlFormat = nil
        }
        if trimmed.fileTreeMode == base.fileTreeMode {
            trimmed.fileTreeMode = nil
        }
        if trimmed.codeMapUsage == base.codeMapUsage {
            trimmed.codeMapUsage = nil
        }
        if trimmed.gitInclusion == base.gitInclusion {
            trimmed.gitInclusion = nil
        }
        if trimmed.systemPromptFlavor == base.systemPromptFlavor {
            trimmed.systemPromptFlavor = nil
        }
        if trimmed.storedPromptIds == base.storedPromptIds {
            trimmed.storedPromptIds = nil
        }
        if trimmed.includeMCPMetadata == base.includeMCPMetadata {
            trimmed.includeMCPMetadata = nil
        }
        
        return trimmed
    }
    
    /// Creates an empty override for a preset
    static func empty(for presetID: UUID) -> CopyPresetOverrides {
        CopyPresetOverrides(
            presetID: presetID,
            includeFiles: nil,
            includeUserPrompt: nil,
            includeMetaPrompts: nil,
            includeFileTree: nil,
            xmlFormat: nil,
            fileTreeMode: nil,
            codeMapUsage: nil,
            gitInclusion: nil,
            systemPromptFlavor: nil,
            storedPromptIds: nil,
            includeMCPMetadata: nil,
            updatedAt: nil
        )
    }
}