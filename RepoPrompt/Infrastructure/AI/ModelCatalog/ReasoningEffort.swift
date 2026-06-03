import Foundation

public enum CodexReasoningEffort: String, CaseIterable, Codable, Sendable {
	case none
	case minimal
	case low
	case medium
	case high
	case xhigh

	static let displayOrder: [CodexReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]

	static func parse(_ raw: String?) -> CodexReasoningEffort? {
		let normalized = raw?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		guard let normalized, !normalized.isEmpty else { return nil }
		switch normalized {
		case "none":
			return CodexReasoningEffort.none
		case "minimal":
			return .minimal
		case "low":
			return .low
		case "medium":
			return .medium
		case "high":
			return .high
		case "xhigh", "x-high":
			return .xhigh
		default:
			return nil
		}
	}

	var displayName: String {
		switch self {
		case .none:
			return "None"
		case .minimal:
			return "Minimal"
		case .low:
			return "Low"
		case .medium:
			return "Medium"
		case .high:
			return "High"
		case .xhigh:
			return "XHigh"
		}
	}
}
