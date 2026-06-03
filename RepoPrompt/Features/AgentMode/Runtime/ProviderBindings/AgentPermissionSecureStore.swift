import Foundation

// SEARCH-HELPER: Secure Agent Permission Storage, Keychain-backed permission documents, fail-closed permissions

/// Permission storage domains persisted as plain JSON Keychain documents.
enum AgentPermissionSecureDomain: String, CaseIterable, Hashable, Sendable {
	case subagent
	case codex
	case claude
	case gemini
	case openCode
	case cursor

	var storageKey: String {
		switch self {
		case .subagent:
			return SecurityObfuscation.decode(SecurityObfuscation.agentPermissionSubagentDocumentKeyEncoded)
		case .codex:
			return SecurityObfuscation.decode(SecurityObfuscation.agentPermissionCodexDocumentKeyEncoded)
		case .claude:
			return SecurityObfuscation.decode(SecurityObfuscation.agentPermissionClaudeDocumentKeyEncoded)
		case .gemini:
			return SecurityObfuscation.decode(SecurityObfuscation.agentPermissionGeminiDocumentKeyEncoded)
		case .openCode:
			return SecurityObfuscation.decode(SecurityObfuscation.agentPermissionOpenCodeDocumentKeyEncoded)
		case .cursor:
			return SecurityObfuscation.decode(SecurityObfuscation.agentPermissionCursorDocumentKeyEncoded)
		}
	}
}

struct AgentPermissionStorageDiagnostic: Equatable, Sendable {
	enum Kind: Equatable, Sendable {
		case keychainReadFailed
		case keychainWriteFailed
		case decodeFailed
		case integrityCheckFailed
		case unsupportedFutureSchema
		case migratedFromLegacy
		case legacyScrubFailed
	}

	let domain: AgentPermissionSecureDomain
	let kind: Kind
	let message: String
	let occurredAt: Date
}

struct AgentPermissionStorageResetResult: Equatable, Sendable {
	let succeededDomains: [AgentPermissionSecureDomain]
	let failedDomains: [AgentPermissionSecureDomain]

	var succeeded: Bool {
		failedDomains.isEmpty
	}
}

extension Notification.Name {
	static let agentPermissionSecureStoreDidChange = Notification.Name("RepoPrompt.agentPermissionSecureStoreDidChange")
}

enum AgentPermissionSecureStoreNotificationKey {
	static let domain = "domain"
	static let writeSucceeded = "writeSucceeded"
}

struct SecureSubagentPermissionDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 2

	var schemaVersion: Int
	var updatedAt: Date
	var globalPolicyRaw: String?
	var providerPermissionLevelsRawByProviderID: [String: String]?
	/// Legacy v1 field. Decoded for migration/back-compat only; v2 normalization clears it.
	var providerPoliciesRawByProviderID: [String: String]?
	var migratedFromLegacyAt: Date?

	init(
		schemaVersion: Int = currentSchemaVersion,
		updatedAt: Date = Date(),
		globalPolicyRaw: String? = AgentSubagentPermissionPolicy.safeManaged.rawValue,
		providerPermissionLevelsRawByProviderID: [String: String]? = nil,
		providerPoliciesRawByProviderID: [String: String]? = nil,
		migratedFromLegacyAt: Date? = nil
	) {
		self.schemaVersion = schemaVersion
		self.updatedAt = updatedAt
		self.globalPolicyRaw = globalPolicyRaw
		self.providerPermissionLevelsRawByProviderID = providerPermissionLevelsRawByProviderID
		self.providerPoliciesRawByProviderID = providerPoliciesRawByProviderID
		self.migratedFromLegacyAt = migratedFromLegacyAt
	}

	static func defaultDocument(now: Date = Date()) -> SecureSubagentPermissionDocument {
		SecureSubagentPermissionDocument(updatedAt: now)
	}

	static func failClosedDocument(now: Date = Date()) -> SecureSubagentPermissionDocument {
		SecureSubagentPermissionDocument(updatedAt: now)
	}

	func globalPolicy() -> AgentSubagentPermissionPolicy {
		AgentSubagentPermissionPolicy(rawValue: globalPolicyRaw ?? "") ?? .safeManaged
	}

	func providerPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
		guard let raw = providerPermissionLevelsRawByProviderID?[providerID.rawValue],
			let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw) else {
			return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
		}
		return level
	}

	func providerPolicy(for providerID: AgentProviderBindingID) -> ProviderSubagentPermissionPolicy {
		let raw = providerPoliciesRawByProviderID?[providerID.rawValue]
		return ProviderSubagentPermissionPolicy(rawValue: raw ?? "") ?? .useGlobal
	}
}

struct SecureCodexPermissionDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	var schemaVersion: Int
	var updatedAt: Date
	var approvalPolicyRaw: String?
	var sandboxModeRaw: String?
	var approvalReviewerRaw: String?
	var bashToolEnabled: Bool?
	var mcpServerTogglesByNormalizedName: [String: Bool]?
	var migratedFromLegacyAt: Date?

	init(
		schemaVersion: Int = currentSchemaVersion,
		updatedAt: Date = Date(),
		approvalPolicyRaw: String? = CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue,
		sandboxModeRaw: String? = CodexAgentToolPreferences.SandboxMode.workspaceWrite.persistedValue,
		approvalReviewerRaw: String? = CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
		bashToolEnabled: Bool? = true,
		mcpServerTogglesByNormalizedName: [String: Bool]? = nil,
		migratedFromLegacyAt: Date? = nil
	) {
		self.schemaVersion = schemaVersion
		self.updatedAt = updatedAt
		self.approvalPolicyRaw = approvalPolicyRaw
		self.sandboxModeRaw = sandboxModeRaw
		self.approvalReviewerRaw = approvalReviewerRaw
		self.bashToolEnabled = bashToolEnabled
		self.mcpServerTogglesByNormalizedName = mcpServerTogglesByNormalizedName
		self.migratedFromLegacyAt = migratedFromLegacyAt
	}

	static func defaultDocument(now: Date = Date()) -> SecureCodexPermissionDocument {
		SecureCodexPermissionDocument(updatedAt: now)
	}

	static func failClosedDocument(now: Date = Date()) -> SecureCodexPermissionDocument {
		SecureCodexPermissionDocument(updatedAt: now, bashToolEnabled: false)
	}

	func approvalPolicy() -> CodexAgentToolPreferences.ApprovalPolicy {
		CodexAgentToolPreferences.ApprovalPolicy(storedValue: approvalPolicyRaw ?? "") ?? .onRequest
	}

	func sandboxMode() -> CodexAgentToolPreferences.SandboxMode {
		CodexAgentToolPreferences.SandboxMode(storedValue: sandboxModeRaw ?? "") ?? .workspaceWrite
	}

	func approvalReviewer() -> CodexAgentToolPreferences.ApprovalReviewer {
		CodexAgentToolPreferences.ApprovalReviewer(storedValue: approvalReviewerRaw ?? "") ?? .user
	}

	func permissionLevel() -> CodexAgentToolPreferences.PermissionLevel {
		CodexAgentToolPreferences.PermissionLevel.from(
			sandbox: sandboxMode(),
			approvalReviewer: approvalReviewer()
		)
	}

	func mcpServerEnabled(normalizedName: String) -> Bool {
		let key = Self.normalizedMCPServerKey(normalizedName)
		return mcpServerTogglesByNormalizedName?[key] ?? false
	}

	static func normalizedMCPServerKey(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}
}

struct SecureClaudePermissionDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	var schemaVersion: Int
	var updatedAt: Date
	var permissionModeRaw: String?
	var bashToolEnabled: Bool?
	var mcpStrictModeEnabled: Bool?
	var migratedFromLegacyAt: Date?

	init(
		schemaVersion: Int = currentSchemaVersion,
		updatedAt: Date = Date(),
		permissionModeRaw: String? = ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode,
		bashToolEnabled: Bool? = true,
		mcpStrictModeEnabled: Bool? = true,
		migratedFromLegacyAt: Date? = nil
	) {
		self.schemaVersion = schemaVersion
		self.updatedAt = updatedAt
		self.permissionModeRaw = permissionModeRaw
		self.bashToolEnabled = bashToolEnabled
		self.mcpStrictModeEnabled = mcpStrictModeEnabled
		self.migratedFromLegacyAt = migratedFromLegacyAt
	}

	static func defaultDocument(now: Date = Date()) -> SecureClaudePermissionDocument {
		SecureClaudePermissionDocument(updatedAt: now)
	}

	static func failClosedDocument(now: Date = Date()) -> SecureClaudePermissionDocument {
		SecureClaudePermissionDocument(updatedAt: now, bashToolEnabled: false, mcpStrictModeEnabled: true)
	}

	func permissionMode() -> String {
		Self.normalizedPermissionMode(permissionModeRaw, preserveUnknown: true)
	}

	func permissionLevel() -> ClaudeAgentToolPreferences.PermissionLevel {
		ClaudeAgentToolPreferences.PermissionLevel.from(permissionMode: permissionMode())
	}

	static func normalizedPermissionMode(_ raw: String?, preserveUnknown: Bool) -> String {
		let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		switch trimmed.lowercased() {
		case "acceptedits":
			return ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
		case "auto":
			return ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode
		case "bypasspermissions":
			return ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode
		case "default":
			return ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
		default:
			return preserveUnknown && !trimmed.isEmpty
				? trimmed
				: ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
		}
	}
}

struct SecureGeminiPermissionDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	var schemaVersion: Int
	var updatedAt: Date
	var sessionModeID: String?
	var migratedFromLegacyAt: Date?

	init(
		schemaVersion: Int = currentSchemaVersion,
		updatedAt: Date = Date(),
		sessionModeID: String? = GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID,
		migratedFromLegacyAt: Date? = nil
	) {
		self.schemaVersion = schemaVersion
		self.updatedAt = updatedAt
		self.sessionModeID = sessionModeID
		self.migratedFromLegacyAt = migratedFromLegacyAt
	}

	static func defaultDocument(now: Date = Date()) -> SecureGeminiPermissionDocument {
		SecureGeminiPermissionDocument(updatedAt: now)
	}

	static func failClosedDocument(now: Date = Date()) -> SecureGeminiPermissionDocument {
		SecureGeminiPermissionDocument(updatedAt: now)
	}

	func normalizedSessionModeID() -> String {
		let trimmed = sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return trimmed.isEmpty ? GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID : trimmed
	}

	func permissionLevel() -> GeminiAgentToolPreferences.PermissionLevel {
		GeminiAgentToolPreferences.PermissionLevel.from(sessionModeID: normalizedSessionModeID())
	}
}

struct SecureOpenCodePermissionDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	var schemaVersion: Int
	var updatedAt: Date
	var permissionLevelRaw: String?
	var migratedFromLegacyAt: Date?

	init(
		schemaVersion: Int = currentSchemaVersion,
		updatedAt: Date = Date(),
		permissionLevelRaw: String? = OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.rawValue,
		migratedFromLegacyAt: Date? = nil
	) {
		self.schemaVersion = schemaVersion
		self.updatedAt = updatedAt
		self.permissionLevelRaw = permissionLevelRaw
		self.migratedFromLegacyAt = migratedFromLegacyAt
	}

	static func defaultDocument(now: Date = Date()) -> SecureOpenCodePermissionDocument {
		SecureOpenCodePermissionDocument(updatedAt: now)
	}

	static func failClosedDocument(now: Date = Date()) -> SecureOpenCodePermissionDocument {
		SecureOpenCodePermissionDocument(updatedAt: now)
	}

	func permissionLevel() -> OpenCodeAgentToolPreferences.PermissionLevel {
		OpenCodeAgentToolPreferences.PermissionLevel(rawValue: permissionLevelRaw ?? "") ?? .managedDefault
	}

	func sessionModeID() -> String {
		permissionLevel().sessionModeID
	}
}

struct SecureCursorPermissionDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	var schemaVersion: Int
	var updatedAt: Date
	var permissionLevelRaw: String?
	var migratedFromLegacyAt: Date?

	init(
		schemaVersion: Int = currentSchemaVersion,
		updatedAt: Date = Date(),
		permissionLevelRaw: String? = CursorAgentToolPreferences.PermissionLevel.managedDefault.rawValue,
		migratedFromLegacyAt: Date? = nil
	) {
		self.schemaVersion = schemaVersion
		self.updatedAt = updatedAt
		self.permissionLevelRaw = permissionLevelRaw
		self.migratedFromLegacyAt = migratedFromLegacyAt
	}

	static func defaultDocument(now: Date = Date()) -> SecureCursorPermissionDocument {
		SecureCursorPermissionDocument(updatedAt: now)
	}

	static func failClosedDocument(now: Date = Date()) -> SecureCursorPermissionDocument {
		SecureCursorPermissionDocument(updatedAt: now)
	}

	func permissionLevel() -> CursorAgentToolPreferences.PermissionLevel {
		CursorAgentToolPreferences.PermissionLevel.from(rawValue: permissionLevelRaw)
	}
}

final class AgentPermissionSecureStore {
	static let shared = AgentPermissionSecureStore(secureStrings: SecureKeysService(), legacyDefaults: .standard)

	private let secureStrings: SecureIntegrityStringStoring
	private let legacyDefaults: UserDefaults
	private let lock = NSRecursiveLock()
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()
	private let now: () -> Date
	private let notificationCenter: NotificationCenter

	private var subagentCache: SecureSubagentPermissionDocument?
	private var codexCache: SecureCodexPermissionDocument?
	private var claudeCache: SecureClaudePermissionDocument?
	private var geminiCache: SecureGeminiPermissionDocument?
	private var openCodeCache: SecureOpenCodePermissionDocument?
	private var cursorCache: SecureCursorPermissionDocument?
	private var diagnosticsByDomain: [AgentPermissionSecureDomain: AgentPermissionStorageDiagnostic] = [:]

	private struct DeferredSideEffects {
		private var requestedSafeShadowDomains: Set<AgentPermissionSecureDomain> = []
		var safeShadowDomains: [AgentPermissionSecureDomain] = []
		var changeNotifications: [(domain: AgentPermissionSecureDomain, writeSucceeded: Bool)] = []

		mutating func requestSafeShadow(for domain: AgentPermissionSecureDomain) {
			if requestedSafeShadowDomains.insert(domain).inserted {
				safeShadowDomains.append(domain)
			}
		}

		mutating func requestChangeNotification(domain: AgentPermissionSecureDomain, writeSucceeded: Bool) {
			changeNotifications.append((domain, writeSucceeded))
		}
	}

	init(
		secureStrings: SecureIntegrityStringStoring,
		legacyDefaults: UserDefaults = .standard,
		notificationCenter: NotificationCenter = .default,
		now: @escaping () -> Date = Date.init
	) {
		self.secureStrings = secureStrings
		self.legacyDefaults = legacyDefaults
		self.notificationCenter = notificationCenter
		self.now = now
		encoder.outputFormatting = [.sortedKeys]
	}

	// MARK: - Diagnostics

	func diagnostics() -> [AgentPermissionStorageDiagnostic] {
		withLock { diagnosticsByDomain.values.sorted { $0.domain.rawValue < $1.domain.rawValue } }
	}

	func diagnostic(for domain: AgentPermissionSecureDomain) -> AgentPermissionStorageDiagnostic? {
		withLock { diagnosticsByDomain[domain] }
	}

	func clearCachedDocuments() {
		withLock {
			subagentCache = nil
			codexCache = nil
			claudeCache = nil
			geminiCache = nil
			openCodeCache = nil
			cursorCache = nil
		}
	}

	@discardableResult
	func resetAgentPermissionsToSafeDefaults() -> AgentPermissionStorageResetResult {
		withLockAndDeferredSideEffects { effects in
			var succeededDomains: [AgentPermissionSecureDomain] = []
			var failedDomains: [AgentPermissionSecureDomain] = []
			let resetDate = now()

			func record(_ domain: AgentPermissionSecureDomain, _ succeeded: Bool) {
				if succeeded {
					succeededDomains.append(domain)
				} else {
					failedDomains.append(domain)
				}
			}

			var subagent = SecureSubagentPermissionDocument.failClosedDocument(now: resetDate)
			_ = normalizeSubagent(&subagent, fallback: .failClosed)
			record(.subagent, resetLocked(subagent, domain: .subagent, cache: &subagentCache, deferred: &effects))

			var codex = SecureCodexPermissionDocument.failClosedDocument(now: resetDate)
			_ = normalizeCodex(&codex, fallback: .failClosed)
			record(.codex, resetLocked(codex, domain: .codex, cache: &codexCache, deferred: &effects))

			var claude = SecureClaudePermissionDocument.failClosedDocument(now: resetDate)
			_ = normalizeClaude(&claude, fallback: .failClosed)
			record(.claude, resetLocked(claude, domain: .claude, cache: &claudeCache, deferred: &effects))

			var gemini = SecureGeminiPermissionDocument.failClosedDocument(now: resetDate)
			_ = normalizeGemini(&gemini)
			record(.gemini, resetLocked(gemini, domain: .gemini, cache: &geminiCache, deferred: &effects))

			var openCode = SecureOpenCodePermissionDocument.failClosedDocument(now: resetDate)
			_ = normalizeOpenCode(&openCode)
			record(.openCode, resetLocked(openCode, domain: .openCode, cache: &openCodeCache, deferred: &effects))

			var cursor = SecureCursorPermissionDocument.failClosedDocument(now: resetDate)
			_ = normalizeCursor(&cursor)
			record(.cursor, resetLocked(cursor, domain: .cursor, cache: &cursorCache, deferred: &effects))

			return AgentPermissionStorageResetResult(
				succeededDomains: succeededDomains,
				failedDomains: failedDomains
			)
		}
	}

	// MARK: - Public reads

	func subagentPermissions() -> SecureSubagentPermissionDocument {
		withLockAndDeferredSideEffects { effects in
			loadSubagentPermissionsLocked(deferred: &effects)
		}
	}

	func subagentPolicy() -> AgentSubagentPermissionPolicy {
		subagentPermissions().globalPolicy()
	}

	func providerSubagentPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
		subagentPermissions().providerPermissionLevel(for: providerID)
	}

	func providerSubagentPolicy(for providerID: AgentProviderBindingID) -> ProviderSubagentPermissionPolicy {
		subagentPermissions().providerPolicy(for: providerID)
	}

	func codexPermissions() -> SecureCodexPermissionDocument {
		withLockAndDeferredSideEffects { effects in
			loadCodexPermissionsLocked(deferred: &effects)
		}
	}

	func claudePermissions() -> SecureClaudePermissionDocument {
		withLockAndDeferredSideEffects { effects in
			loadClaudePermissionsLocked(deferred: &effects)
		}
	}

	func geminiPermissions() -> SecureGeminiPermissionDocument {
		withLockAndDeferredSideEffects { effects in
			loadGeminiPermissionsLocked(deferred: &effects)
		}
	}

	func openCodePermissions() -> SecureOpenCodePermissionDocument {
		withLockAndDeferredSideEffects { effects in
			loadOpenCodePermissionsLocked(deferred: &effects)
		}
	}

	func cursorPermissions() -> SecureCursorPermissionDocument {
		withLockAndDeferredSideEffects { effects in
			loadCursorPermissionsLocked(deferred: &effects)
		}
	}

	// MARK: - Public writes

	@discardableResult
	func updateSubagentPermissions(_ mutation: (inout SecureSubagentPermissionDocument) -> Void) -> Bool {
		withLockAndDeferredSideEffects { effects in
			var document = loadSubagentPermissionsLocked(deferred: &effects)
			mutation(&document)
			normalizeSubagent(&document, fallback: .failClosed)
			document.updatedAt = now()
			return saveLocked(document, domain: .subagent, cache: &subagentCache, deferred: &effects)
		}
	}

	@discardableResult
	func updateCodexPermissions(_ mutation: (inout SecureCodexPermissionDocument) -> Void) -> Bool {
		withLockAndDeferredSideEffects { effects in
			var document = loadCodexPermissionsLocked(deferred: &effects)
			mutation(&document)
			normalizeCodex(&document, fallback: .failClosed)
			document.updatedAt = now()
			return saveLocked(document, domain: .codex, cache: &codexCache, deferred: &effects)
		}
	}

	@discardableResult
	func updateClaudePermissions(_ mutation: (inout SecureClaudePermissionDocument) -> Void) -> Bool {
		withLockAndDeferredSideEffects { effects in
			var document = loadClaudePermissionsLocked(deferred: &effects)
			mutation(&document)
			normalizeClaude(&document, fallback: .failClosed)
			document.updatedAt = now()
			return saveLocked(document, domain: .claude, cache: &claudeCache, deferred: &effects)
		}
	}

	@discardableResult
	func updateGeminiPermissions(_ mutation: (inout SecureGeminiPermissionDocument) -> Void) -> Bool {
		withLockAndDeferredSideEffects { effects in
			var document = loadGeminiPermissionsLocked(deferred: &effects)
			mutation(&document)
			normalizeGemini(&document)
			document.updatedAt = now()
			return saveLocked(document, domain: .gemini, cache: &geminiCache, deferred: &effects)
		}
	}

	@discardableResult
	func updateOpenCodePermissions(_ mutation: (inout SecureOpenCodePermissionDocument) -> Void) -> Bool {
		withLockAndDeferredSideEffects { effects in
			var document = loadOpenCodePermissionsLocked(deferred: &effects)
			mutation(&document)
			normalizeOpenCode(&document)
			document.updatedAt = now()
			return saveLocked(document, domain: .openCode, cache: &openCodeCache, deferred: &effects)
		}
	}

	@discardableResult
	func updateCursorPermissions(_ mutation: (inout SecureCursorPermissionDocument) -> Void) -> Bool {
		withLockAndDeferredSideEffects { effects in
			var document = loadCursorPermissionsLocked(deferred: &effects)
			mutation(&document)
			normalizeCursor(&document)
			document.updatedAt = now()
			return saveLocked(document, domain: .cursor, cache: &cursorCache, deferred: &effects)
		}
	}

	@discardableResult
	func setCodexPermissionLevel(_ level: CodexAgentToolPreferences.PermissionLevel) -> Bool {
		updateCodexPermissions { document in
			document.approvalPolicyRaw = level.approvalPolicy.persistedValue
			document.sandboxModeRaw = level.sandboxMode.persistedValue
			document.approvalReviewerRaw = level.approvalReviewer.persistedValue
		}
	}

	@discardableResult
	func setClaudePermissionLevel(_ level: ClaudeAgentToolPreferences.PermissionLevel) -> Bool {
		updateClaudePermissions { document in
			document.permissionModeRaw = level.permissionMode
		}
	}

	@discardableResult
	func setGeminiPermissionLevel(_ level: GeminiAgentToolPreferences.PermissionLevel) -> Bool {
		updateGeminiPermissions { document in
			document.sessionModeID = level.sessionModeID
		}
	}

	@discardableResult
	func setOpenCodePermissionLevel(_ level: OpenCodeAgentToolPreferences.PermissionLevel) -> Bool {
		updateOpenCodePermissions { document in
			document.permissionLevelRaw = level.rawValue
		}
	}

	@discardableResult
	func setCursorPermissionLevel(_ level: CursorAgentToolPreferences.PermissionLevel) -> Bool {
		updateCursorPermissions { document in
			document.permissionLevelRaw = level.rawValue
		}
	}

	// MARK: - Locked loads

	private func loadSubagentPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureSubagentPermissionDocument {
		loadLocked(
			domain: .subagent,
			cache: &subagentCache,
			defaultDocument: SecureSubagentPermissionDocument.defaultDocument(now: now()),
			failClosedDocument: SecureSubagentPermissionDocument.failClosedDocument(now: now()),
			legacyDocument: legacySubagentPermissions,
			normalize: { normalizeSubagent(&$0, fallback: .defaultValue) },
			deferred: &effects
		)
	}

	private func loadCodexPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureCodexPermissionDocument {
		loadLocked(
			domain: .codex,
			cache: &codexCache,
			defaultDocument: SecureCodexPermissionDocument.defaultDocument(now: now()),
			failClosedDocument: SecureCodexPermissionDocument.failClosedDocument(now: now()),
			legacyDocument: legacyCodexPermissions,
			normalize: { normalizeCodex(&$0, fallback: .defaultValue) },
			deferred: &effects
		)
	}

	private func loadClaudePermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureClaudePermissionDocument {
		loadLocked(
			domain: .claude,
			cache: &claudeCache,
			defaultDocument: SecureClaudePermissionDocument.defaultDocument(now: now()),
			failClosedDocument: SecureClaudePermissionDocument.failClosedDocument(now: now()),
			legacyDocument: legacyClaudePermissions,
			normalize: { normalizeClaude(&$0, fallback: .defaultValue) },
			deferred: &effects
		)
	}

	private func loadGeminiPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureGeminiPermissionDocument {
		loadLocked(
			domain: .gemini,
			cache: &geminiCache,
			defaultDocument: SecureGeminiPermissionDocument.defaultDocument(now: now()),
			failClosedDocument: SecureGeminiPermissionDocument.failClosedDocument(now: now()),
			legacyDocument: legacyGeminiPermissions,
			normalize: normalizeGemini,
			deferred: &effects
		)
	}

	private func loadOpenCodePermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureOpenCodePermissionDocument {
		loadLocked(
			domain: .openCode,
			cache: &openCodeCache,
			defaultDocument: SecureOpenCodePermissionDocument.defaultDocument(now: now()),
			failClosedDocument: SecureOpenCodePermissionDocument.failClosedDocument(now: now()),
			legacyDocument: legacyOpenCodePermissions,
			normalize: normalizeOpenCode,
			deferred: &effects
		)
	}

	private func loadCursorPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureCursorPermissionDocument {
		loadLocked(
			domain: .cursor,
			cache: &cursorCache,
			defaultDocument: SecureCursorPermissionDocument.defaultDocument(now: now()),
			failClosedDocument: SecureCursorPermissionDocument.failClosedDocument(now: now()),
			legacyDocument: legacyCursorPermissions,
			normalize: normalizeCursor,
			deferred: &effects
		)
	}

	private enum NormalizationFallback {
		case defaultValue
		case failClosed
	}

	private struct StoredDocumentFailure {
		let kind: AgentPermissionStorageDiagnostic.Kind
		let message: String
	}

	private enum StoredDocumentDecodeResult<Document> {
		case success(document: Document, normalized: Bool)
		case failure(StoredDocumentFailure)
	}

	private enum LegacyIntegrityLoadResult<Document> {
		case migrated(Document)
		case missing
		case failed(StoredDocumentFailure)
	}

	private func loadLocked<Document: Codable>(
		domain: AgentPermissionSecureDomain,
		cache: inout Document?,
		defaultDocument: Document,
		failClosedDocument: Document,
		legacyDocument: () -> Document?,
		normalize: (inout Document) -> Bool,
		deferred effects: inout DeferredSideEffects
	) -> Document {
		if let cache {
			return cache
		}

		do {
			guard let payload = try secureStrings.getPlainValue(for: domain.storageKey) else {
				switch loadLegacyIntegrityProtectedDocumentLocked(domain: domain, cache: &cache, normalize: normalize, deferred: &effects) {
				case .migrated(let document):
					return document
				case .failed(let failure):
					return failClosed(
						domain: domain,
						failure: failure,
						failClosedDocument: failClosedDocument,
						cache: &cache,
						deferred: &effects
					)
				case .missing:
					break
				}

				var document = legacyDocument() ?? defaultDocument
				_ = normalize(&document)
				if saveMigratedLocked(document, domain: domain, cache: &cache, deferred: &effects) {
					return document
				}
				cache = failClosedDocument
				return failClosedDocument
			}

			switch decodeStoredDocument(payload, normalize: normalize) {
			case .success(let document, let normalized):
				return finishLoadedDocument(
					document,
					normalized: normalized,
					domain: domain,
					cache: &cache,
					deferred: &effects
				)
			case .failure(let plainFailure):
				switch loadLegacyIntegrityProtectedDocumentLocked(domain: domain, cache: &cache, normalize: normalize, deferred: &effects) {
				case .migrated(let document):
					return document
				case .failed(let legacyFailure)
					where legacyFailure.kind == .integrityCheckFailed && shouldAttemptLegacyIntegrityFallback(forPlainPayload: payload):
					return failClosed(
						domain: domain,
						failure: legacyFailure,
						failClosedDocument: failClosedDocument,
						cache: &cache,
						deferred: &effects
					)
				case .failed, .missing:
					break
				}
				return failClosed(
					domain: domain,
					failure: plainFailure,
					failClosedDocument: failClosedDocument,
					cache: &cache,
					deferred: &effects
				)
			}
		} catch {
			switch loadLegacyIntegrityProtectedDocumentLocked(domain: domain, cache: &cache, normalize: normalize, deferred: &effects) {
			case .migrated(let document):
				return document
			case .failed(let failure):
				return failClosed(
					domain: domain,
					failure: failure,
					failClosedDocument: failClosedDocument,
					cache: &cache,
					deferred: &effects
				)
			case .missing:
				let failure = StoredDocumentFailure(kind: readFailureKind(for: error), message: error.localizedDescription)
				return failClosed(
					domain: domain,
					failure: failure,
					failClosedDocument: failClosedDocument,
					cache: &cache,
					deferred: &effects
				)
			}
		}
	}

	private func decodeStoredDocument<Document: Codable>(
		_ payload: String,
		normalize: (inout Document) -> Bool
	) -> StoredDocumentDecodeResult<Document> {
		let document: Document
		do {
			document = try decoder.decode(Document.self, from: Data(payload.utf8))
		} catch {
			return .failure(StoredDocumentFailure(kind: .decodeFailed, message: error.localizedDescription))
		}

		if schemaVersion(of: document) > supportedSchemaVersion(of: document) {
			return .failure(StoredDocumentFailure(
				kind: .unsupportedFutureSchema,
				message: "Unsupported future schema version \(schemaVersion(of: document))."
			))
		}

		var normalizedDocument = document
		let normalized = normalize(&normalizedDocument)
		return .success(document: normalizedDocument, normalized: normalized)
	}

	private func loadLegacyIntegrityProtectedDocumentLocked<Document: Codable>(
		domain: AgentPermissionSecureDomain,
		cache: inout Document?,
		normalize: (inout Document) -> Bool,
		deferred effects: inout DeferredSideEffects
	) -> LegacyIntegrityLoadResult<Document> {
		do {
			guard let payload = try secureStrings.getIntegrityProtectedValue(for: domain.storageKey) else {
				return .missing
			}

			switch decodeStoredDocument(payload, normalize: normalize) {
			case .success(let document, _):
				let loaded = finishLoadedDocument(
					document,
					normalized: true,
					domain: domain,
					cache: &cache,
					deferred: &effects
				)
				return .migrated(loaded)
			case .failure(let failure):
				return .failed(failure)
			}
		} catch KeychainService.KeychainError.itemNotFound {
			return .missing
		} catch {
			return .failed(StoredDocumentFailure(kind: readFailureKind(for: error), message: error.localizedDescription))
		}
	}

	private func finishLoadedDocument<Document: Codable>(
		_ document: Document,
		normalized: Bool,
		domain: AgentPermissionSecureDomain,
		cache: inout Document?,
		deferred effects: inout DeferredSideEffects
	) -> Document {
		cache = document
		clearDiagnostic(for: domain)
		if normalized {
			do {
				try saveDocument(document, domain: domain)
				effects.requestSafeShadow(for: domain)
			} catch {
				recordDiagnostic(domain: domain, kind: .keychainWriteFailed, error: error)
			}
		}
		return document
	}

	private func failClosed<Document>(
		domain: AgentPermissionSecureDomain,
		failure: StoredDocumentFailure,
		failClosedDocument: Document,
		cache: inout Document?,
		deferred effects: inout DeferredSideEffects
	) -> Document {
		recordDiagnostic(domain: domain, kind: failure.kind, message: failure.message)
		effects.requestSafeShadow(for: domain)
		cache = failClosedDocument
		return failClosedDocument
	}

	private func shouldAttemptLegacyIntegrityFallback(forPlainPayload payload: String) -> Bool {
		let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let first = trimmed.first else { return true }
		return first != "{" && first != "["
	}

	private func saveMigratedLocked<Document: Codable>(
		_ document: Document,
		domain: AgentPermissionSecureDomain,
		cache: inout Document?,
		deferred effects: inout DeferredSideEffects
	) -> Bool {
		do {
			try saveDocument(document, domain: domain)
			cache = document
			clearDiagnostic(for: domain)
			effects.requestSafeShadow(for: domain)
			return true
		} catch {
			recordDiagnostic(domain: domain, kind: .keychainWriteFailed, error: error)
			return false
		}
	}

	private func saveLocked<Document: Codable>(
		_ document: Document,
		domain: AgentPermissionSecureDomain,
		cache: inout Document?,
		deferred effects: inout DeferredSideEffects
	) -> Bool {
		do {
			try saveDocument(document, domain: domain)
			cache = document
			clearDiagnostic(for: domain)
			effects.requestSafeShadow(for: domain)
			effects.requestChangeNotification(domain: domain, writeSucceeded: true)
			return true
		} catch {
			recordDiagnostic(domain: domain, kind: .keychainWriteFailed, error: error)
			if cache == nil {
				cache = failClosedDocument(for: domain) as? Document
			}
			effects.requestChangeNotification(domain: domain, writeSucceeded: false)
			return false
		}
	}

	private func resetLocked<Document: Codable>(
		_ document: Document,
		domain: AgentPermissionSecureDomain,
		cache: inout Document?,
		deferred effects: inout DeferredSideEffects
	) -> Bool {
		do {
			try saveDocument(document, domain: domain)
			cache = document
			clearDiagnostic(for: domain)
			effects.requestSafeShadow(for: domain)
			effects.requestChangeNotification(domain: domain, writeSucceeded: true)
			return true
		} catch {
			recordDiagnostic(domain: domain, kind: .keychainWriteFailed, error: error)
			try? secureStrings.deletePlainValue(for: domain.storageKey)
			try? secureStrings.deleteIntegrityProtectedValue(for: domain.storageKey)
			cache = document
			effects.requestSafeShadow(for: domain)
			effects.requestChangeNotification(domain: domain, writeSucceeded: false)
			return false
		}
	}

	private func saveDocument<Document: Codable>(_ document: Document, domain: AgentPermissionSecureDomain) throws {
		let data = try encoder.encode(document)
		guard let payload = String(data: data, encoding: .utf8) else {
			throw AgentPermissionSecureStoreError.encodingFailed
		}
		try secureStrings.savePlainValue(payload, for: domain.storageKey)
	}

	// MARK: - Normalization

	@discardableResult
	private func normalizeSubagent(
		_ document: inout SecureSubagentPermissionDocument,
		fallback _: NormalizationFallback
	) -> Bool {
		var changed = false
		let originalSchemaVersion = document.schemaVersion
		if document.schemaVersion != SecureSubagentPermissionDocument.currentSchemaVersion {
			document.schemaVersion = SecureSubagentPermissionDocument.currentSchemaVersion
			changed = true
		}
		if AgentSubagentPermissionPolicy(rawValue: document.globalPolicyRaw ?? "") == nil {
			document.globalPolicyRaw = AgentSubagentPermissionPolicy.safeManaged.rawValue
			changed = true
		}

		let originalLevels = document.providerPermissionLevelsRawByProviderID ?? [:]
		var normalizedLevels: [String: String] = [:]
		for providerID in AgentProviderBindingID.allCases {
			if let raw = originalLevels[providerID.rawValue],
				let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw) {
				normalizedLevels[providerID.rawValue] = level.subagentRawValue
			}
		}

		if originalSchemaVersion < 2 {
			let legacyPolicies = document.providerPoliciesRawByProviderID ?? [:]
			for providerID in AgentProviderBindingID.allCases where legacyPolicies[providerID.rawValue] != nil {
				let defaultLevel = AgentProviderPermissionLevelID.subagentDefault(for: providerID)
				normalizedLevels[providerID.rawValue] = defaultLevel.subagentRawValue
			}
		}

		if normalizedLevels != originalLevels {
			document.providerPermissionLevelsRawByProviderID = normalizedLevels.isEmpty ? nil : normalizedLevels
			changed = true
		}
		if document.providerPoliciesRawByProviderID != nil {
			document.providerPoliciesRawByProviderID = nil
			changed = true
		}
		return changed
	}

	@discardableResult
	private func normalizeCodex(
		_ document: inout SecureCodexPermissionDocument,
		fallback: NormalizationFallback
	) -> Bool {
		var changed = false
		if document.schemaVersion != SecureCodexPermissionDocument.currentSchemaVersion {
			document.schemaVersion = SecureCodexPermissionDocument.currentSchemaVersion
			changed = true
		}
		let approval = CodexAgentToolPreferences.ApprovalPolicy(storedValue: document.approvalPolicyRaw ?? "") ?? .onRequest
		if document.approvalPolicyRaw != approval.persistedValue {
			document.approvalPolicyRaw = approval.persistedValue
			changed = true
		}
		let sandbox = CodexAgentToolPreferences.SandboxMode(storedValue: document.sandboxModeRaw ?? "") ?? .workspaceWrite
		if document.sandboxModeRaw != sandbox.persistedValue {
			document.sandboxModeRaw = sandbox.persistedValue
			changed = true
		}
		let reviewer = CodexAgentToolPreferences.ApprovalReviewer(storedValue: document.approvalReviewerRaw ?? "") ?? .user
		if document.approvalReviewerRaw != reviewer.persistedValue {
			document.approvalReviewerRaw = reviewer.persistedValue
			changed = true
		}
		if document.bashToolEnabled == nil {
			document.bashToolEnabled = fallback == .failClosed ? false : true
			changed = true
		}
		let originalToggles = document.mcpServerTogglesByNormalizedName ?? [:]
		var normalized: [String: Bool] = [:]
		for (key, value) in originalToggles {
			let normalizedKey = SecureCodexPermissionDocument.normalizedMCPServerKey(key)
			guard !normalizedKey.isEmpty else { continue }
			normalized[normalizedKey] = value
		}
		if normalized != originalToggles {
			document.mcpServerTogglesByNormalizedName = normalized.isEmpty ? nil : normalized
			changed = true
		}
		return changed
	}

	@discardableResult
	private func normalizeClaude(
		_ document: inout SecureClaudePermissionDocument,
		fallback: NormalizationFallback
	) -> Bool {
		var changed = false
		if document.schemaVersion != SecureClaudePermissionDocument.currentSchemaVersion {
			document.schemaVersion = SecureClaudePermissionDocument.currentSchemaVersion
			changed = true
		}
		let mode = SecureClaudePermissionDocument.normalizedPermissionMode(document.permissionModeRaw, preserveUnknown: true)
		if document.permissionModeRaw != mode {
			document.permissionModeRaw = mode
			changed = true
		}
		if document.bashToolEnabled == nil {
			document.bashToolEnabled = fallback == .failClosed ? false : true
			changed = true
		}
		if document.mcpStrictModeEnabled == nil {
			document.mcpStrictModeEnabled = true
			changed = true
		}
		return changed
	}

	@discardableResult
	private func normalizeGemini(_ document: inout SecureGeminiPermissionDocument) -> Bool {
		var changed = false
		if document.schemaVersion != SecureGeminiPermissionDocument.currentSchemaVersion {
			document.schemaVersion = SecureGeminiPermissionDocument.currentSchemaVersion
			changed = true
		}
		let trimmed = document.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let sessionModeID = trimmed.isEmpty ? GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID : trimmed
		if document.sessionModeID != sessionModeID {
			document.sessionModeID = sessionModeID
			changed = true
		}
		return changed
	}

	@discardableResult
	private func normalizeOpenCode(_ document: inout SecureOpenCodePermissionDocument) -> Bool {
		var changed = false
		if document.schemaVersion != SecureOpenCodePermissionDocument.currentSchemaVersion {
			document.schemaVersion = SecureOpenCodePermissionDocument.currentSchemaVersion
			changed = true
		}
		let level = OpenCodeAgentToolPreferences.PermissionLevel(rawValue: document.permissionLevelRaw ?? "") ?? .managedDefault
		if document.permissionLevelRaw != level.rawValue {
			document.permissionLevelRaw = level.rawValue
			changed = true
		}
		return changed
	}

	@discardableResult
	private func normalizeCursor(_ document: inout SecureCursorPermissionDocument) -> Bool {
		var changed = false
		if document.schemaVersion != SecureCursorPermissionDocument.currentSchemaVersion {
			document.schemaVersion = SecureCursorPermissionDocument.currentSchemaVersion
			changed = true
		}
		let level = CursorAgentToolPreferences.PermissionLevel.from(rawValue: document.permissionLevelRaw)
		if document.permissionLevelRaw != level.rawValue {
			document.permissionLevelRaw = level.rawValue
			changed = true
		}
		return changed
	}

	// MARK: - Legacy migration scaffolding

	private func legacySubagentPermissions() -> SecureSubagentPermissionDocument? {
		var hasLegacyValue = false
		let policy: AgentSubagentPermissionPolicy
		if let raw = legacyDefaults.string(forKey: LegacyKeys.subagentPermissionPolicy),
			let value = AgentSubagentPermissionPolicy(rawValue: raw) {
			hasLegacyValue = true
			policy = value
		} else if legacyDefaults.object(forKey: LegacyKeys.forceSafeSubagentPermissions) != nil {
			hasLegacyValue = true
			policy = legacyDefaults.bool(forKey: LegacyKeys.forceSafeSubagentPermissions)
				? .safeManaged
				: .inheritProviderSettings
		} else {
			policy = .safeManaged
		}

		var providerPolicies: [String: String] = [:]
		for providerID in AgentProviderBindingID.allCases {
			let key = LegacyKeys.providerSubagentPolicyKey(for: providerID)
			guard legacyDefaults.object(forKey: key) != nil else { continue }
			hasLegacyValue = true
			let policy = ProviderSubagentPermissionPolicy(rawValue: legacyDefaults.string(forKey: key) ?? "") ?? .useGlobal
			providerPolicies[providerID.rawValue] = policy.rawValue
		}

		guard hasLegacyValue else { return nil }
		return SecureSubagentPermissionDocument(
			updatedAt: now(),
			globalPolicyRaw: policy.rawValue,
			providerPoliciesRawByProviderID: providerPolicies.isEmpty ? nil : providerPolicies,
			migratedFromLegacyAt: now()
		)
	}

	private func legacyCodexPermissions() -> SecureCodexPermissionDocument? {
		let keys = [
			LegacyKeys.codexBashToolEnabled,
			LegacyKeys.codexApprovalPolicy,
			LegacyKeys.codexSandboxMode,
			LegacyKeys.codexApprovalReviewer,
			LegacyKeys.codexMCPServerToggles
		]
		guard keys.contains(where: { legacyDefaults.object(forKey: $0) != nil }) else { return nil }
		let approvalPolicy = CodexAgentToolPreferences.ApprovalPolicy(
			storedValue: legacyDefaults.string(forKey: LegacyKeys.codexApprovalPolicy) ?? ""
		) ?? .onRequest
		let sandboxMode = CodexAgentToolPreferences.SandboxMode(
			storedValue: legacyDefaults.string(forKey: LegacyKeys.codexSandboxMode) ?? ""
		) ?? .workspaceWrite
		let approvalReviewer = CodexAgentToolPreferences.ApprovalReviewer(
			storedValue: legacyDefaults.string(forKey: LegacyKeys.codexApprovalReviewer) ?? ""
		) ?? .user
		let bashEnabled = legacyDefaults.object(forKey: LegacyKeys.codexBashToolEnabled) == nil
			? true
			: legacyDefaults.bool(forKey: LegacyKeys.codexBashToolEnabled)
		return SecureCodexPermissionDocument(
			updatedAt: now(),
			approvalPolicyRaw: approvalPolicy.persistedValue,
			sandboxModeRaw: sandboxMode.persistedValue,
			approvalReviewerRaw: approvalReviewer.persistedValue,
			bashToolEnabled: bashEnabled,
			mcpServerTogglesByNormalizedName: legacyCodexMCPToggles(),
			migratedFromLegacyAt: now()
		)
	}

	private func legacyClaudePermissions() -> SecureClaudePermissionDocument? {
		let keys = [
			LegacyKeys.claudeBashToolEnabled,
			LegacyKeys.claudePermissionMode,
			LegacyKeys.claudeMCPStrictModeEnabled
		]
		guard keys.contains(where: { legacyDefaults.object(forKey: $0) != nil }) else { return nil }
		let rawPermissionMode = legacyDefaults.string(forKey: LegacyKeys.claudePermissionMode)
		let permissionMode = SecureClaudePermissionDocument.normalizedPermissionMode(
			rawPermissionMode,
			preserveUnknown: true
		)
		let bashEnabled = legacyDefaults.object(forKey: LegacyKeys.claudeBashToolEnabled) == nil
			? true
			: legacyDefaults.bool(forKey: LegacyKeys.claudeBashToolEnabled)
		let mcpStrictEnabled = legacyDefaults.object(forKey: LegacyKeys.claudeMCPStrictModeEnabled) == nil
			? true
			: legacyDefaults.bool(forKey: LegacyKeys.claudeMCPStrictModeEnabled)
		return SecureClaudePermissionDocument(
			updatedAt: now(),
			permissionModeRaw: permissionMode,
			bashToolEnabled: bashEnabled,
			mcpStrictModeEnabled: mcpStrictEnabled,
			migratedFromLegacyAt: now()
		)
	}

	private func legacyGeminiPermissions() -> SecureGeminiPermissionDocument? {
		guard legacyDefaults.object(forKey: LegacyKeys.geminiSessionMode) != nil else { return nil }
		let rawSessionMode = legacyDefaults.string(forKey: LegacyKeys.geminiSessionMode)
		let sessionModeID = rawSessionMode?.trimmingCharacters(in: .whitespacesAndNewlines)
		return SecureGeminiPermissionDocument(
			updatedAt: now(),
			sessionModeID: sessionModeID?.isEmpty == false ? sessionModeID : GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID,
			migratedFromLegacyAt: now()
		)
	}

	private func legacyOpenCodePermissions() -> SecureOpenCodePermissionDocument? {
		guard legacyDefaults.object(forKey: LegacyKeys.openCodeSessionMode) != nil else { return nil }
		let rawSessionMode = legacyDefaults.string(forKey: LegacyKeys.openCodeSessionMode) ?? ""
		return SecureOpenCodePermissionDocument(
			updatedAt: now(),
			permissionLevelRaw: OpenCodeAgentToolPreferences.PermissionLevel.from(sessionModeID: rawSessionMode).rawValue,
			migratedFromLegacyAt: now()
		)
	}

	private func legacyCursorPermissions() -> SecureCursorPermissionDocument? {
		guard legacyDefaults.object(forKey: LegacyKeys.cursorPermissionLevel) != nil else { return nil }
		return SecureCursorPermissionDocument(
			updatedAt: now(),
			permissionLevelRaw: CursorAgentToolPreferences.PermissionLevel.from(
				rawValue: legacyDefaults.string(forKey: LegacyKeys.cursorPermissionLevel)
			).rawValue,
			migratedFromLegacyAt: now()
		)
	}

	private func legacyCodexMCPToggles() -> [String: Bool]? {
		guard let raw = legacyDefaults.dictionary(forKey: LegacyKeys.codexMCPServerToggles) else {
			return nil
		}
		var mapped: [String: Bool] = [:]
		for (key, value) in raw {
			guard let boolValue = value as? Bool else { continue }
			let normalized = SecureCodexPermissionDocument.normalizedMCPServerKey(key)
			guard !normalized.isEmpty else { continue }
			mapped[normalized] = boolValue
		}
		return mapped.isEmpty ? nil : mapped
	}

	private func safeShadowLegacyValues(for domain: AgentPermissionSecureDomain) {
		switch domain {
		case .subagent:
			legacyDefaults.set(AgentSubagentPermissionPolicy.safeManaged.rawValue, forKey: LegacyKeys.subagentPermissionPolicy)
			legacyDefaults.set(true, forKey: LegacyKeys.forceSafeSubagentPermissions)
			for providerID in AgentProviderBindingID.allCases {
				legacyDefaults.removeObject(forKey: LegacyKeys.providerSubagentPolicyKey(for: providerID))
				legacyDefaults.removeObject(forKey: LegacyKeys.providerSubagentPermissionLevelKey(for: providerID))
			}
		case .codex:
			legacyDefaults.set(CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue, forKey: LegacyKeys.codexApprovalPolicy)
			legacyDefaults.set(CodexAgentToolPreferences.SandboxMode.workspaceWrite.persistedValue, forKey: LegacyKeys.codexSandboxMode)
			legacyDefaults.set(CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue, forKey: LegacyKeys.codexApprovalReviewer)
			legacyDefaults.set(false, forKey: LegacyKeys.codexBashToolEnabled)
			legacyDefaults.set([String: Bool](), forKey: LegacyKeys.codexMCPServerToggles)
		case .claude:
			legacyDefaults.set(ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode, forKey: LegacyKeys.claudePermissionMode)
			legacyDefaults.set(false, forKey: LegacyKeys.claudeBashToolEnabled)
			legacyDefaults.set(true, forKey: LegacyKeys.claudeMCPStrictModeEnabled)
		case .gemini:
			legacyDefaults.set(GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID, forKey: LegacyKeys.geminiSessionMode)
		case .openCode:
			legacyDefaults.set(OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.sessionModeID, forKey: LegacyKeys.openCodeSessionMode)
		case .cursor:
			legacyDefaults.set(CursorAgentToolPreferences.PermissionLevel.managedDefault.rawValue, forKey: LegacyKeys.cursorPermissionLevel)
		}
	}

	// MARK: - Helpers

	private func supportedSchemaVersion<Document>(of document: Document) -> Int {
		switch document {
		case _ as SecureSubagentPermissionDocument:
			return SecureSubagentPermissionDocument.currentSchemaVersion
		case _ as SecureCodexPermissionDocument:
			return SecureCodexPermissionDocument.currentSchemaVersion
		case _ as SecureClaudePermissionDocument:
			return SecureClaudePermissionDocument.currentSchemaVersion
		case _ as SecureGeminiPermissionDocument:
			return SecureGeminiPermissionDocument.currentSchemaVersion
		case _ as SecureOpenCodePermissionDocument:
			return SecureOpenCodePermissionDocument.currentSchemaVersion
		case _ as SecureCursorPermissionDocument:
			return SecureCursorPermissionDocument.currentSchemaVersion
		default:
			return 1
		}
	}

	private func schemaVersion<Document>(of document: Document) -> Int {
		switch document {
		case let value as SecureSubagentPermissionDocument:
			return value.schemaVersion
		case let value as SecureCodexPermissionDocument:
			return value.schemaVersion
		case let value as SecureClaudePermissionDocument:
			return value.schemaVersion
		case let value as SecureGeminiPermissionDocument:
			return value.schemaVersion
		case let value as SecureOpenCodePermissionDocument:
			return value.schemaVersion
		case let value as SecureCursorPermissionDocument:
			return value.schemaVersion
		default:
			return 1
		}
	}

	private func failClosedDocument(for domain: AgentPermissionSecureDomain) -> Any {
		switch domain {
		case .subagent:
			return SecureSubagentPermissionDocument.failClosedDocument(now: now())
		case .codex:
			return SecureCodexPermissionDocument.failClosedDocument(now: now())
		case .claude:
			return SecureClaudePermissionDocument.failClosedDocument(now: now())
		case .gemini:
			return SecureGeminiPermissionDocument.failClosedDocument(now: now())
		case .openCode:
			return SecureOpenCodePermissionDocument.failClosedDocument(now: now())
		case .cursor:
			return SecureCursorPermissionDocument.failClosedDocument(now: now())
		}
	}

	private func readFailureKind(for error: Error) -> AgentPermissionStorageDiagnostic.Kind {
		if case KeychainService.KeychainError.integrityCheckFailed = error {
			return .integrityCheckFailed
		}
		return .keychainReadFailed
	}

	private func recordDiagnostic(
		domain: AgentPermissionSecureDomain,
		kind: AgentPermissionStorageDiagnostic.Kind,
		error: Error
	) {
		recordDiagnostic(domain: domain, kind: kind, message: error.localizedDescription)
	}

	private func recordDiagnostic(
		domain: AgentPermissionSecureDomain,
		kind: AgentPermissionStorageDiagnostic.Kind,
		message: String
	) {
		diagnosticsByDomain[domain] = AgentPermissionStorageDiagnostic(
			domain: domain,
			kind: kind,
			message: message,
			occurredAt: now()
		)
	}

	private func clearDiagnostic(for domain: AgentPermissionSecureDomain) {
		diagnosticsByDomain.removeValue(forKey: domain)
	}

	private func postChangeNotification(domain: AgentPermissionSecureDomain, writeSucceeded: Bool) {
		notificationCenter.post(
			name: .agentPermissionSecureStoreDidChange,
			object: self,
			userInfo: [
				AgentPermissionSecureStoreNotificationKey.domain: domain.rawValue,
				AgentPermissionSecureStoreNotificationKey.writeSucceeded: writeSucceeded
			]
		)
	}

	private func performDeferredSideEffects(_ effects: DeferredSideEffects) {
		for domain in effects.safeShadowDomains {
			safeShadowLegacyValues(for: domain)
		}
		for notification in effects.changeNotifications {
			postChangeNotification(domain: notification.domain, writeSucceeded: notification.writeSucceeded)
		}
	}

	private func withLock<T>(_ body: () -> T) -> T {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}

	private func withLockAndDeferredSideEffects<T>(_ body: (inout DeferredSideEffects) -> T) -> T {
		var effects = DeferredSideEffects()
		let result: T = {
			lock.lock()
			defer { lock.unlock() }
			return body(&effects)
		}()
		performDeferredSideEffects(effects)
		return result
	}

	private enum AgentPermissionSecureStoreError: LocalizedError {
		case encodingFailed

		var errorDescription: String? {
			switch self {
			case .encodingFailed:
				return "Failed to encode secure permission document."
			}
		}
	}

	private enum LegacyKeys {
		static let forceSafeSubagentPermissions = "agentMode.subagents.forceSafePermissions"
		static let subagentPermissionPolicy = "agentMode.subagents.permissionPolicy"
		static let providerSubagentPolicyPrefix = "agentMode.subagents.providerPolicy."
		static let providerSubagentPermissionLevelPrefix = "agentMode.subagents.providerPermissionLevel."

		static let codexBashToolEnabled = "codexAgentTools.bash.enabled"
		static let codexApprovalPolicy = "codexAgentTools.bash.approvalPolicy"
		static let codexSandboxMode = "codexAgentTools.bash.sandboxMode"
		static let codexApprovalReviewer = "codexAgentTools.approvalsReviewer"
		static let codexMCPServerToggles = "codexAgentTools.mcpServerToggles"

		static let claudeBashToolEnabled = "claudeCodeAllowNativeBashTool"
		static let claudePermissionMode = "claudeCodePermissionMode"
		static let claudeMCPStrictModeEnabled = "claudeCodeMCPStrictModeEnabled"

		static let geminiSessionMode = "geminiACPSessionMode"
		static let openCodeSessionMode = "openCodeACPSessionMode"
		static let cursorPermissionLevel = "cursorACPToolPermissionLevel"

		static func providerSubagentPolicyKey(for providerID: AgentProviderBindingID) -> String {
			"\(providerSubagentPolicyPrefix)\(providerID.rawValue)"
		}

		static func providerSubagentPermissionLevelKey(for providerID: AgentProviderBindingID) -> String {
			"\(providerSubagentPermissionLevelPrefix)\(providerID.rawValue)"
		}
	}
}
