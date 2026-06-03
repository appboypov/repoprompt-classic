import Foundation

struct GeminiAgentToolPreferences {
	enum PermissionLevel: String, CaseIterable, Sendable {
		case `default`
		case fullAccess

		var displayName: String {
			switch self {
			case .default:
				return "Default"
			case .fullAccess:
				return "Full Access"
			}
		}

		var iconName: String {
			switch self {
			case .default:
				return "lock.shield"
			case .fullAccess:
				return "exclamationmark.shield.fill"
			}
		}

		var isWarning: Bool {
			self == .fullAccess
		}

		var sessionModeID: String {
			switch self {
			case .default:
				return "default"
			case .fullAccess:
				return "yolo"
			}
		}

		static func from(sessionModeID: String) -> PermissionLevel {
			switch sessionModeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "yolo":
				return .fullAccess
			default:
				return .default
			}
		}
	}

	private static let sessionModeKey = "geminiACPSessionMode"

	static func sessionModeID(
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) -> String {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			return secureStore.geminiPermissions().normalizedSessionModeID()
		}
		let raw = defaults.string(forKey: sessionModeKey)
		let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
		if let trimmed, !trimmed.isEmpty {
			return trimmed
		}
		return PermissionLevel.default.sessionModeID
	}

	static func setSessionModeID(
		_ mode: String,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) {
		let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalized = trimmed.isEmpty ? PermissionLevel.default.sessionModeID : trimmed
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			secureStore.updateGeminiPermissions { document in
				document.sessionModeID = normalized
			}
			return
		}
		defaults.set(normalized, forKey: sessionModeKey)
	}

	static func permissionLevel(
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) -> PermissionLevel {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			return secureStore.geminiPermissions().permissionLevel()
		}
		return PermissionLevel.from(sessionModeID: sessionModeID(defaults: defaults))
	}

	static func setPermissionLevel(
		_ level: PermissionLevel,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			secureStore.setGeminiPermissionLevel(level)
			return
		}
		setSessionModeID(level.sessionModeID, defaults: defaults)
	}

	private static func resolvedSecureStore(
		defaults: UserDefaults,
		secureStore: AgentPermissionSecureStore?
	) -> AgentPermissionSecureStore? {
		if let secureStore {
			return secureStore
		}
		return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
	}
}
