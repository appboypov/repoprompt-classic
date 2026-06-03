import Foundation
import MCP

// MARK: - Shared MCP Tool Helpers
// SEARCH-HELPER: MCP, Value parsing, normalization, timestamp, agent_run, agent_manage

/// Shared utility functions used by `AgentRunMCPToolService` and `AgentManageMCPToolService`.
/// Extracted to eliminate duplication across the two tool services and the snapshot model.
enum AgentMCPToolHelpers {

	// MARK: - String parsing

	/// Trims whitespace and returns nil for empty strings.
	static func normalizedString(_ value: Value?) -> String? {
		let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return trimmed.isEmpty ? nil : trimmed
	}

	/// Requires a non-empty string value, throwing if absent or blank.
	static func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
		guard let normalized = normalizedString(value), !normalized.isEmpty else {
			throw MCPError.invalidParams("\(name) is required.")
		}
		return normalized
	}

	// MARK: - Bool parsing

	/// Parses a boolean from various Value representations (bool, string, int, double).
	static func parseBool(_ value: Value?) -> Bool? {
		switch value {
		case .bool(let boolValue):
			return boolValue
		case .string(let stringValue):
			switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "true", "1", "yes":
				return true
			case "false", "0", "no":
				return false
			default:
				return nil
			}
		case .int(let intValue):
			return intValue != 0
		case .double(let doubleValue):
			return doubleValue != 0
		case .null, .array, .object:
			return nil
		default:
			return nil
		}
	}

	// MARK: - Timeout parsing

	/// Parses a timeout in seconds from int, double, or string Value representations.
	static func parseTimeoutSeconds(_ value: Value?) throws -> TimeInterval? {
		guard let value else { return nil }
		switch value {
		case .int(let intValue):
			let seconds = TimeInterval(intValue)
			guard seconds >= 0 else {
				throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
			}
			return seconds
		case .double(let doubleValue):
			guard doubleValue.isFinite, doubleValue >= 0 else {
				throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
			}
			return doubleValue
		case .string(let stringValue):
			guard let parsed = Double(stringValue), parsed.isFinite, parsed >= 0 else {
				throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
			}
			return parsed
		case .null:
			return nil
		case .bool, .array, .object:
			throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
		default:
			throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
		}
	}

	// MARK: - Timestamps

	/// Shared ISO 8601 formatter with fractional seconds, used across all agent MCP surfaces.
	static let timestampFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	/// Formats a date as an ISO 8601 string.
	static func timestamp(_ date: Date) -> String {
		timestampFormatter.string(from: date)
	}

	// MARK: - Value helpers

	/// Returns `.string(value)` when non-nil, `.null` otherwise.
	static func stringOrNull(_ value: String?) -> Value {
		guard let value else { return .null }
		return .string(value)
	}
}
