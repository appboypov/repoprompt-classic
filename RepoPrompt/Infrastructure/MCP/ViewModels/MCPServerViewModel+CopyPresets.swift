import Foundation
import MCP

// MARK: - Copy Preset MCP Helpers

extension MCPServerViewModel {
    /// Selector for identifying a copy preset via MCP args
    struct CopyPresetSelector {
        var id: UUID?
        var kind: CopyPresetKind?
        var name: String?
    }

    /// Parses a copy_preset arg value into a selector.
    /// Accepts either a string (UUID, kind, or name) or an object with id/kind/name keys.
    nonisolated func parseCopyPresetSelector(from value: Value?) -> CopyPresetSelector? {
        guard let value else { return nil }

        // Handle string shorthand
        if let str = value.stringValue {
            let trimmed = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // Try UUID first
            if let uuid = UUID(uuidString: trimmed) {
                return CopyPresetSelector(id: uuid, kind: nil, name: nil)
            }

            // Try CopyPresetKind (case-insensitive)
            let lowercased = trimmed.lowercased()
            for kind in CopyPresetKind.allCases {
                if kind.rawValue.lowercased() == lowercased {
                    return CopyPresetSelector(id: nil, kind: kind, name: nil)
                }
            }

            // Fallback to name
            return CopyPresetSelector(id: nil, kind: nil, name: trimmed)
        }

        // Handle object
        if case .object(let obj) = value {
            var selector = CopyPresetSelector()

            if let idStr = obj["id"]?.stringValue, let uuid = UUID(uuidString: idStr) {
                selector.id = uuid
            }

            if let kindStr = obj["kind"]?.stringValue {
                let lowercased = kindStr.lowercased()
                for kind in CopyPresetKind.allCases {
                    if kind.rawValue.lowercased() == lowercased {
                        selector.kind = kind
                        break
                    }
                }
            }

            if let nameStr = obj["name"]?.stringValue {
                selector.name = nameStr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }

            // Return nil if all fields are empty
            if selector.id == nil && selector.kind == nil && (selector.name?.isEmpty ?? true) {
                return nil
            }

            return selector
        }

        return nil
    }

    /// Resolves a preset selector to an actual CopyPreset.
    /// Resolution priority: id → kind → name (case-insensitive).
    @MainActor
    func resolveCopyPreset(from selector: CopyPresetSelector) -> CopyPreset? {
        // Try by ID first
        if let id = selector.id {
            return CopyPresetManager.shared.preset(with: id)
        }

        // Try by kind
        if let kind = selector.kind {
            return CopyPresetManager.shared.builtInPreset(for: kind)
        }

        // Try by name (case-insensitive)
        if let name = selector.name, !name.isEmpty {
            let lowercased = name.lowercased()
            return CopyPresetManager.shared.allPresets.first {
                $0.name.lowercased() == lowercased
            }
        }

        return nil
    }

    // MARK: - DTO Conversion Helpers

    /// Converts a CopyPreset to a compact descriptor DTO
    @MainActor
    func toDescriptorDTO(_ preset: CopyPreset) -> ToolResultDTOs.CopyPresetDescriptorDTO {
        ToolResultDTOs.CopyPresetDescriptorDTO(
            id: preset.id.uuidString,
            name: preset.name,
            kind: preset.builtInKind?.rawValue,
            isBuiltIn: preset.isBuiltIn
        )
    }

    /// Converts a CopyPreset to a full list item DTO with all configuration fields
    @MainActor
    func toListItemDTO(_ preset: CopyPreset) -> ToolResultDTOs.CopyPresetListItemDTO {
        ToolResultDTOs.CopyPresetListItemDTO(
            preset: toDescriptorDTO(preset),
            description: preset.description,
            icon: preset.icon,
            includeFiles: preset.includeFiles,
            includeUserPrompt: preset.includeUserPrompt,
            includeMetaPrompts: preset.includeMetaPrompts,
            includeFileTree: preset.includeFileTree,
            xmlFormat: mapXMLFormat(preset.xmlFormat),
            fileTreeMode: preset.fileTreeMode?.rawValue,
            codeMapUsage: preset.codeMapUsage?.rawValue,
            gitInclusion: preset.gitInclusion?.rawValue,
            systemPromptFlavor: mapSystemPromptFlavor(preset.systemPromptFlavor),
            includeMCPMetadata: preset.includeMCPMetadata
        )
    }

    /// Builds a CopyPresetContextDTO showing active and effective presets
    @MainActor
    func buildCopyPresetContextDTO(
        active: CopyPreset,
        effective: CopyPreset
    ) -> ToolResultDTOs.CopyPresetContextDTO {
        ToolResultDTOs.CopyPresetContextDTO(
            active: toDescriptorDTO(active),
            effective: toDescriptorDTO(effective),
            isOverridden: active.id != effective.id
        )
    }

    /// Builds the full list of available presets as DTOs
    @MainActor
    func buildCopyPresetsListDTO() -> [ToolResultDTOs.CopyPresetListItemDTO] {
        CopyPresetManager.shared.allPresets.map { toListItemDTO($0) }
    }

    // MARK: - String Mapping Helpers

    /// Maps ApplyPromptFormat to its string representation
    nonisolated func mapXMLFormat(_ format: ApplyPromptFormat?) -> String? {
        guard let format else { return nil }
        switch format {
        case .diff: return "diff"
        case .whole: return "whole"
        case .architect: return "architect"
        }
    }

    /// Maps SystemPromptFlavor to its string representation
    nonisolated func mapSystemPromptFlavor(_ flavor: SystemPromptFlavor?) -> String? {
        guard let flavor else { return nil }
        switch flavor {
        case .architectPlan: return "architect_plan"
        case .codeEditDiff: return "code_edit_diff"
        case .codeEditWhole: return "code_edit_whole"
        case .review: return "review"
        case .mcpAgent: return "mcp_agent"
        case .mcpPairProgram: return "mcp_pair_program"
        case .mcpPairPlan: return "mcp_pair_plan"
        case .mcpDiscover: return "mcp_discover"
        case .mcpBuilder: return "mcp_builder"
        }
    }

    // MARK: - Projection Config

    /// Configuration for computing selection projection under a copy preset
    struct CopyPresetProjectionConfig {
        let includeFiles: Bool
        let codeMapUsage: CodeMapUsage
    }

    /// Builds a projection config from a resolved prompt context
    nonisolated func projectionConfig(from resolved: PromptContextResolved) -> CopyPresetProjectionConfig {
        CopyPresetProjectionConfig(
            includeFiles: resolved.includeFiles,
            codeMapUsage: resolved.codeMapUsage
        )
    }
}
