import Foundation

// SEARCH-HELPER: Sub-agent Permissions, Safe Managed, AgentSubagentPermissionPolicy,
// tri-state policy, migration, rollback compatibility, providerSubagentPolicy

/// Storage shim for sub-agent permission decisions.
///
/// Production `.standard` reads and writes are persisted through
/// `AgentPermissionSecureStore.shared` so sensitive launch-policy state is
/// integrity-protected and legacy UserDefaults mirrors are safe-shadowed only.
/// Custom injected `UserDefaults` suites keep the legacy UserDefaults behavior
/// for deterministic tests and previews.
struct AgentModePermissionPreferences {
	/// Legacy boolean key — kept for rollback compatibility. Missing/true => safe managed;
	/// false => inherit provider settings.
	static let forceSafeSubagentPermissionsKey = "agentMode.subagents.forceSafePermissions"

	/// New tri-state global policy key. Supersedes the legacy boolean from A3 onward.
	static let subagentPermissionPolicyKey = "agentMode.subagents.permissionPolicy"

	/// Legacy prefix for abstract per-provider policies from the first Custom design.
	private static let providerPolicyKeyPrefix = "agentMode.subagents.providerPolicy."

	/// Prefix for concrete provider-native permission levels used by Custom sub-agent policy.
	private static let providerPermissionLevelKeyPrefix = "agentMode.subagents.providerPermissionLevel."

	// MARK: - Legacy boolean (kept for rollback compatibility)

	static func forceSafeSubagentPermissions(
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) -> Bool {
		switch subagentPermissionPolicy(defaults: defaults, secureStore: secureStore) {
		case .safeManaged, .custom:
			return true
		case .inheritProviderSettings:
			return false
		}
	}

	static func setForceSafeSubagentPermissions(
		_ enabled: Bool,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) {
		setSubagentPermissionPolicy(
			enabled ? .safeManaged : .inheritProviderSettings,
			defaults: defaults,
			secureStore: secureStore
		)
	}

	// MARK: - Tri-state global policy

	static func subagentPermissionPolicy(
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) -> AgentSubagentPermissionPolicy {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			return secureStore.subagentPolicy()
		}
		return legacySubagentPermissionPolicy(defaults: defaults)
	}

	static func setSubagentPermissionPolicy(
		_ policy: AgentSubagentPermissionPolicy,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			secureStore.updateSubagentPermissions { document in
				document.globalPolicyRaw = policy.rawValue
			}
			return
		}
		setLegacySubagentPermissionPolicy(policy, defaults: defaults)
	}

	// MARK: - Per-provider overrides (consulted when global policy == `.custom`)

	static func providerSubagentPermissionLevel(
		for providerID: AgentProviderBindingID,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) -> AgentProviderPermissionLevelID {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			return secureStore.providerSubagentPermissionLevel(for: providerID)
		}
		return legacyProviderSubagentPermissionLevel(for: providerID, defaults: defaults)
	}

	static func setProviderSubagentPermissionLevel(
		_ level: AgentProviderPermissionLevelID,
		for providerID: AgentProviderBindingID,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) {
		let normalizedLevel = level.providerID == providerID
			? level
			: AgentProviderPermissionLevelID.subagentDefault(for: providerID)
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			secureStore.updateSubagentPermissions { document in
				var levels = document.providerPermissionLevelsRawByProviderID ?? [:]
				levels[providerID.rawValue] = normalizedLevel.subagentRawValue
				document.providerPermissionLevelsRawByProviderID = levels
				var legacyPolicies = document.providerPoliciesRawByProviderID ?? [:]
				legacyPolicies.removeValue(forKey: providerID.rawValue)
				document.providerPoliciesRawByProviderID = legacyPolicies.isEmpty ? nil : legacyPolicies
			}
			return
		}
		defaults.set(normalizedLevel.subagentRawValue, forKey: providerPermissionLevelKey(for: providerID))
		defaults.removeObject(forKey: providerPolicyKey(for: providerID))
	}

	/// Stable storage key for a given provider's concrete Custom sub-agent mode. Exposed for tests.
	static func providerPermissionLevelKey(for providerID: AgentProviderBindingID) -> String {
		"\(providerPermissionLevelKeyPrefix)\(providerID.rawValue)"
	}

	// MARK: - Legacy per-provider policy APIs

	static func providerSubagentPolicy(
		for providerID: AgentProviderBindingID,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) -> ProviderSubagentPermissionPolicy {
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			return secureStore.providerSubagentPolicy(for: providerID)
		}
		return legacyProviderSubagentPolicy(for: providerID, defaults: defaults)
	}

	static func setProviderSubagentPolicy(
		_ policy: ProviderSubagentPermissionPolicy,
		for providerID: AgentProviderBindingID,
		defaults: UserDefaults = .standard,
		secureStore: AgentPermissionSecureStore? = nil
	) {
		let defaultLevel = AgentProviderPermissionLevelID.subagentDefault(for: providerID)
		if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
			secureStore.updateSubagentPermissions { document in
				var levels = document.providerPermissionLevelsRawByProviderID ?? [:]
				levels[providerID.rawValue] = defaultLevel.subagentRawValue
				document.providerPermissionLevelsRawByProviderID = levels
				var legacyPolicies = document.providerPoliciesRawByProviderID ?? [:]
				legacyPolicies.removeValue(forKey: providerID.rawValue)
				document.providerPoliciesRawByProviderID = legacyPolicies.isEmpty ? nil : legacyPolicies
			}
			return
		}
		defaults.set(defaultLevel.subagentRawValue, forKey: providerPermissionLevelKey(for: providerID))
		defaults.removeObject(forKey: providerPolicyKey(for: providerID))
		_ = policy
	}

	/// Stable storage key for a given provider's override. Exposed for tests.
	static func providerPolicyKey(for providerID: AgentProviderBindingID) -> String {
		"\(providerPolicyKeyPrefix)\(providerID.rawValue)"
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

	private static func legacySubagentPermissionPolicy(defaults: UserDefaults) -> AgentSubagentPermissionPolicy {
		if let raw = defaults.string(forKey: subagentPermissionPolicyKey),
			let value = AgentSubagentPermissionPolicy(rawValue: raw) {
			return value
		}
		// Migration: derive from the legacy boolean so isolated UserDefaults tests and
		// previews keep the historical deterministic behavior.
		if defaults.object(forKey: forceSafeSubagentPermissionsKey) == nil {
			return .safeManaged
		}
		return defaults.bool(forKey: forceSafeSubagentPermissionsKey)
			? .safeManaged
			: .inheritProviderSettings
	}

	private static func setLegacySubagentPermissionPolicy(
		_ policy: AgentSubagentPermissionPolicy,
		defaults: UserDefaults
	) {
		defaults.set(policy.rawValue, forKey: subagentPermissionPolicyKey)
		// Legacy/custom UserDefaults path retains the old dual-write behavior so existing
		// deterministic tests and previews remain unchanged.
		switch policy {
		case .safeManaged, .custom:
			defaults.set(true, forKey: forceSafeSubagentPermissionsKey)
		case .inheritProviderSettings:
			defaults.set(false, forKey: forceSafeSubagentPermissionsKey)
		}
	}

	private static func legacyProviderSubagentPermissionLevel(
		for providerID: AgentProviderBindingID,
		defaults: UserDefaults
	) -> AgentProviderPermissionLevelID {
		if let raw = defaults.string(forKey: providerPermissionLevelKey(for: providerID)),
			let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw) {
			return level
		}
		// Old abstract Custom provider policies intentionally migrate fail-closed to the
		// provider's concrete Safe Managed/default mode instead of inheriting direct-agent prefs.
		if defaults.object(forKey: providerPolicyKey(for: providerID)) != nil {
			return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
		}
		return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
	}

	private static func legacyProviderSubagentPolicy(
		for providerID: AgentProviderBindingID,
		defaults: UserDefaults
	) -> ProviderSubagentPermissionPolicy {
		guard let raw = defaults.string(forKey: providerPolicyKey(for: providerID)),
			let value = ProviderSubagentPermissionPolicy(rawValue: raw) else {
			return .useGlobal
		}
		return value
	}
}

// MARK: - Policy enums

/// Global sub-agent permission policy (A3 tri-state).
enum AgentSubagentPermissionPolicy: String, CaseIterable, Sendable, Hashable {
	/// Sub-agents always run with Safe Managed overrides regardless of provider prefs.
	case safeManaged
	/// Sub-agents inherit the user's provider-configured permission settings.
	case inheritProviderSettings
	/// Per-provider concrete provider-native permission levels apply.
	case custom

	var displayName: String {
		switch self {
		case .safeManaged: return "Safe Managed"
		case .inheritProviderSettings: return "Inherit provider settings"
		case .custom: return "Custom per provider"
		}
	}
}

/// Legacy abstract per-provider override from the first Custom sub-agent policy design.
///
/// Runtime and UI now use concrete `AgentProviderPermissionLevelID` values. These cases
/// are kept only for v1 storage migration and rollback/fallback compatibility.
enum ProviderSubagentPermissionPolicy: String, CaseIterable, Sendable, Hashable {
	case useGlobal
	case safeManaged
	case inheritProviderSettings
	case custom

	var displayName: String {
		switch self {
		case .useGlobal: return "Use Global"
		case .safeManaged: return "Safe Managed"
		case .inheritProviderSettings: return "Inherit provider settings"
		case .custom: return "Custom"
		}
	}
}
