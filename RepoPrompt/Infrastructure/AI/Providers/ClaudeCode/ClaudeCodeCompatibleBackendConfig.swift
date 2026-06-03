import Foundation

enum ClaudeCodeCompatibleBackendID: String, CaseIterable, Codable, Hashable, Sendable {
	case glmZAI
	case kimi
	case custom

	var defaultDisplayName: String {
		switch self {
		case .glmZAI:
			return "CC Zai"
		case .kimi:
			return "CC Moonshot"
		case .custom:
			return "CC Custom"
		}
	}

	var legacyDefaultDisplayNames: Set<String> {
		switch self {
		case .glmZAI:
			return ["Claude Code GLM"]
		case .kimi:
			return ["Kimi Code", "Claude Code Kimi"]
		case .custom:
			return ["Custom Claude-Compatible"]
		}
	}

	var secretIdentifier: String {
		switch self {
		case .glmZAI:
			return AIProviderType.zAI.secureIdentifier
		case .kimi:
			return "ClaudeCompatibleBackend.kimi.apiKey"
		case .custom:
			return "ClaudeCompatibleBackend.custom.apiKey"
		}
	}

	var defaultPreset: ClaudeCodeCompatibleBackendConfig {
		switch self {
		case .glmZAI:
			return ClaudeCodeCompatibleBackendConfig(
				id: self,
				isEnabled: true,
				displayName: defaultDisplayName,
				baseURL: "https://api.z.ai/api/anthropic",
				auth: .anthropicAuthToken,
				modelBehavior: .claudeSlotMapping(
					ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
						haiku: "glm-4.7",
						sonnet: "glm-5-turbo",
						opus: "glm-5.1"
					)
				)
			)
		case .kimi:
			return ClaudeCodeCompatibleBackendConfig(
				id: self,
				isEnabled: true,
				displayName: defaultDisplayName,
				baseURL: "https://api.kimi.com/coding/",
				auth: .anthropicAPIKey,
				modelBehavior: .noModel
			)
		case .custom:
			return ClaudeCodeCompatibleBackendConfig(
				id: self,
				isEnabled: false,
				displayName: defaultDisplayName,
				baseURL: "",
				auth: .anthropicAPIKey,
				modelBehavior: .noModel
			)
		}
	}
}

struct ClaudeCodeCompatibleBackendConfig: Codable, Equatable, Sendable {
	enum Auth: Codable, Equatable, Sendable {
		case anthropicAPIKey
		case anthropicAuthToken

		var environmentVariableName: String {
			switch self {
			case .anthropicAPIKey:
				return "ANTHROPIC_API_KEY"
			case .anthropicAuthToken:
				return "ANTHROPIC_AUTH_TOKEN"
			}
		}
	}

	enum ModelBehavior: Codable, Equatable, Sendable {
		case noModel
		case claudeSlotMapping(ClaudeSlotMapping)
	}

	struct ClaudeSlotMapping: Codable, Equatable, Sendable {
		var haiku: String
		var sonnet: String
		var opus: String

		var normalized: ClaudeSlotMapping {
			ClaudeSlotMapping(
				haiku: haiku.trimmingCharacters(in: .whitespacesAndNewlines),
				sonnet: sonnet.trimmingCharacters(in: .whitespacesAndNewlines),
				opus: opus.trimmingCharacters(in: .whitespacesAndNewlines)
			)
		}

		var isValid: Bool {
			let mapping = normalized
			return !mapping.haiku.isEmpty && !mapping.sonnet.isEmpty && !mapping.opus.isEmpty
		}
	}

	var id: ClaudeCodeCompatibleBackendID
	var isEnabled: Bool
	var displayName: String
	var baseURL: String
	var auth: Auth
	var modelBehavior: ModelBehavior
	var updatedAt: Date?

	var normalizedDisplayName: String {
		let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return id.defaultDisplayName }
		return id.legacyDefaultDisplayNames.contains(trimmed) ? id.defaultDisplayName : trimmed
	}

	var normalizedBaseURL: String? {
		let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty,
			let components = URLComponents(string: trimmed),
			let scheme = components.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			components.host?.isEmpty == false else {
			return nil
		}
		return trimmed
	}

	var normalized: ClaudeCodeCompatibleBackendConfig {
		var copy = self
		copy.displayName = normalizedDisplayName
		copy.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		if case .claudeSlotMapping(let mapping) = modelBehavior {
			copy.modelBehavior = .claudeSlotMapping(mapping.normalized)
		}
		return copy
	}

	var isValid: Bool {
		guard normalizedBaseURL != nil else { return false }
		switch modelBehavior {
		case .noModel:
			return true
		case .claudeSlotMapping(let mapping):
			return mapping.isValid
		}
	}
}
