import Foundation
import MCP

enum ContextBuilderResponseType: String {
	case plan
	case question
	case review
	case clarify
	
	static func parse(from value: Value?) throws -> ContextBuilderResponseType? {
		guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			!raw.isEmpty else { return nil }
		guard let parsed = ContextBuilderResponseType(rawValue: raw.lowercased()) else {
			throw MCPError.invalidParams("Invalid response_type: \(raw)")
		}
		return parsed
	}
	
	var wantsResponse: Bool {
		switch self {
		case .plan, .question, .review:
			return true
		case .clarify:
			return false
		}
	}
	
	var generationLabel: String? {
		switch self {
		case .plan:
			return "plan"
		case .question:
			return "question"
		case .review:
			return "review"
		case .clarify:
			return nil
		}
	}
	
	func supportsPresetMode(_ preset: ModelPreset) -> Bool {
		switch self {
		case .plan:
			return preset.supportedModes?.plan ?? true
		case .review:
			return preset.supportedModes?.review ?? true
		case .question:
			return preset.supportedModes?.chat ?? true
		case .clarify:
			return false
		}
	}
}
