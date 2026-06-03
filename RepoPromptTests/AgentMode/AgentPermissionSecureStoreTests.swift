import XCTest
@testable import RepoPrompt

final class AgentPermissionSecureStoreTests: XCTestCase {
	private final class InMemorySecureStrings: SecureIntegrityStringStoring {
		var values: [String: String] = [:]
		var legacyIntegrityValues: [String: String] = [:]
		var readErrors: [String: Error] = [:]
		var plainReadErrors: [String: Error] = [:]
		var integrityReadErrors: [String: Error] = [:]
		var failSaves = false
		var failSaveKeys: Set<String> = []
		var savedKeys: [String] = []
		var integritySavedKeys: [String] = []

		func getPlainValue(for key: String) throws -> String? {
			if let error = plainReadErrors[key] ?? readErrors[key] {
				throw error
			}
			return values[key]
		}

		func savePlainValue(_ value: String, for key: String) throws {
			if failSaves || failSaveKeys.contains(key) {
				throw TestError.writeFailed
			}
			values[key] = value
			savedKeys.append(key)
		}

		func deletePlainValue(for key: String) throws {
			values.removeValue(forKey: key)
		}

		func getIntegrityProtectedValue(for key: String) throws -> String? {
			if let error = integrityReadErrors[key] ?? readErrors[key] {
				throw error
			}
			return legacyIntegrityValues[key]
		}

		func saveIntegrityProtectedValue(_ value: String, for key: String) throws {
			if failSaves {
				throw TestError.writeFailed
			}
			legacyIntegrityValues[key] = value
			integritySavedKeys.append(key)
		}

		func deleteIntegrityProtectedValue(for key: String) throws {
			legacyIntegrityValues.removeValue(forKey: key)
		}
	}

	private final class MutationProbingUserDefaults: UserDefaults {
		var mutationCount = 0
		var onMutation: (() -> Void)?

		override func set(_ value: Any?, forKey defaultName: String) {
			mutationCount += 1
			onMutation?()
			super.set(value, forKey: defaultName)
		}

		override func removeObject(forKey defaultName: String) {
			mutationCount += 1
			onMutation?()
			super.removeObject(forKey: defaultName)
		}
	}

	private enum TestError: Error {
		case writeFailed
	}

	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	override func setUp() {
		super.setUp()
		encoder.outputFormatting = [.sortedKeys]
	}

	private func makeDefaults() -> UserDefaults {
		let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	private func makeProbingDefaults() -> MutationProbingUserDefaults {
		let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
		let defaults = MutationProbingUserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	private func makeStore(
		secureStrings: InMemorySecureStrings = InMemorySecureStrings(),
		defaults: UserDefaults? = nil,
		notificationCenter: NotificationCenter = NotificationCenter()
	) -> AgentPermissionSecureStore {
		AgentPermissionSecureStore(
			secureStrings: secureStrings,
			legacyDefaults: defaults ?? makeDefaults(),
			notificationCenter: notificationCenter
		)
	}

	private func encode<Document: Encodable>(_ document: Document) throws -> String {
		let data = try encoder.encode(document)
		return try XCTUnwrap(String(data: data, encoding: .utf8))
	}

	private func decode<Document: Decodable>(_ type: Document.Type, from payload: String?) throws -> Document {
		let payload = try XCTUnwrap(payload)
		return try decoder.decode(Document.self, from: Data(payload.utf8))
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

	private func writePermissiveLegacyMirrors(to defaults: UserDefaults) {
		defaults.set(AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue, forKey: LegacyKeys.subagentPermissionPolicy)
		defaults.set(false, forKey: LegacyKeys.forceSafeSubagentPermissions)
		for providerID in AgentProviderBindingID.allCases {
			defaults.set(
				ProviderSubagentPermissionPolicy.inheritProviderSettings.rawValue,
				forKey: LegacyKeys.providerSubagentPolicyKey(for: providerID)
			)
			let permissiveLevel: AgentProviderPermissionLevelID = switch providerID {
			case .codex: .codex(.fullAccess)
			case .claude: .claude(.fullAccess)
			case .gemini: .gemini(.fullAccess)
			case .openCode: .openCode(.fullAccess)
			case .cursor: .cursor(.fullAccess)
			}
			defaults.set(
				permissiveLevel.subagentRawValue,
				forKey: LegacyKeys.providerSubagentPermissionLevelKey(for: providerID)
			)
		}

		defaults.set(CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue, forKey: LegacyKeys.codexApprovalPolicy)
		defaults.set(CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue, forKey: LegacyKeys.codexSandboxMode)
		defaults.set(CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue, forKey: LegacyKeys.codexApprovalReviewer)
		defaults.set(true, forKey: LegacyKeys.codexBashToolEnabled)
		defaults.set(["externalsrv": true], forKey: LegacyKeys.codexMCPServerToggles)

		defaults.set(ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode, forKey: LegacyKeys.claudePermissionMode)
		defaults.set(true, forKey: LegacyKeys.claudeBashToolEnabled)
		defaults.set(false, forKey: LegacyKeys.claudeMCPStrictModeEnabled)

		defaults.set(GeminiAgentToolPreferences.PermissionLevel.fullAccess.sessionModeID, forKey: LegacyKeys.geminiSessionMode)
		defaults.set(OpenCodeAgentConfig.managedFullAccessSessionModeID, forKey: LegacyKeys.openCodeSessionMode)
		defaults.set(CursorAgentToolPreferences.PermissionLevel.fullAccess.rawValue, forKey: LegacyKeys.cursorPermissionLevel)
	}

	private func assertSafeLegacyMirrors(
		in defaults: UserDefaults,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.subagentPermissionPolicy), AgentSubagentPermissionPolicy.safeManaged.rawValue, file: file, line: line)
		XCTAssertTrue(defaults.bool(forKey: LegacyKeys.forceSafeSubagentPermissions), file: file, line: line)
		for providerID in AgentProviderBindingID.allCases {
			XCTAssertNil(defaults.object(forKey: LegacyKeys.providerSubagentPolicyKey(for: providerID)), file: file, line: line)
			XCTAssertNil(defaults.object(forKey: LegacyKeys.providerSubagentPermissionLevelKey(for: providerID)), file: file, line: line)
		}

		XCTAssertEqual(defaults.string(forKey: LegacyKeys.codexApprovalPolicy), CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.codexSandboxMode), CodexAgentToolPreferences.SandboxMode.workspaceWrite.persistedValue, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.codexApprovalReviewer), CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue, file: file, line: line)
		XCTAssertFalse(defaults.bool(forKey: LegacyKeys.codexBashToolEnabled), file: file, line: line)
		let codexToggles = defaults.dictionary(forKey: LegacyKeys.codexMCPServerToggles) as? [String: Bool]
		XCTAssertEqual(codexToggles ?? [:], [:], file: file, line: line)

		XCTAssertEqual(defaults.string(forKey: LegacyKeys.claudePermissionMode), ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode, file: file, line: line)
		XCTAssertFalse(defaults.bool(forKey: LegacyKeys.claudeBashToolEnabled), file: file, line: line)
		XCTAssertTrue(defaults.bool(forKey: LegacyKeys.claudeMCPStrictModeEnabled), file: file, line: line)

		XCTAssertEqual(defaults.string(forKey: LegacyKeys.geminiSessionMode), GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.openCodeSessionMode), OpenCodeAgentConfig.managedSessionModeID, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.cursorPermissionLevel), CursorAgentToolPreferences.PermissionLevel.managedDefault.rawValue, file: file, line: line)
	}

	private func assertPermissiveLegacyMirrors(
		in defaults: UserDefaults,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.subagentPermissionPolicy), AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue, file: file, line: line)
		XCTAssertFalse(defaults.bool(forKey: LegacyKeys.forceSafeSubagentPermissions), file: file, line: line)
		for providerID in AgentProviderBindingID.allCases {
			XCTAssertEqual(defaults.string(forKey: LegacyKeys.providerSubagentPolicyKey(for: providerID)), ProviderSubagentPermissionPolicy.inheritProviderSettings.rawValue, file: file, line: line)
			let permissiveLevel: AgentProviderPermissionLevelID = switch providerID {
			case .codex: .codex(.fullAccess)
			case .claude: .claude(.fullAccess)
			case .gemini: .gemini(.fullAccess)
			case .openCode: .openCode(.fullAccess)
			case .cursor: .cursor(.fullAccess)
			}
			XCTAssertEqual(defaults.string(forKey: LegacyKeys.providerSubagentPermissionLevelKey(for: providerID)), permissiveLevel.subagentRawValue, file: file, line: line)
		}

		XCTAssertEqual(defaults.string(forKey: LegacyKeys.codexApprovalPolicy), CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.codexSandboxMode), CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.codexApprovalReviewer), CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue, file: file, line: line)
		XCTAssertTrue(defaults.bool(forKey: LegacyKeys.codexBashToolEnabled), file: file, line: line)
		let codexToggles = defaults.dictionary(forKey: LegacyKeys.codexMCPServerToggles) as? [String: Bool]
		XCTAssertEqual(codexToggles, ["externalsrv": true], file: file, line: line)

		XCTAssertEqual(defaults.string(forKey: LegacyKeys.claudePermissionMode), ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode, file: file, line: line)
		XCTAssertTrue(defaults.bool(forKey: LegacyKeys.claudeBashToolEnabled), file: file, line: line)
		XCTAssertFalse(defaults.bool(forKey: LegacyKeys.claudeMCPStrictModeEnabled), file: file, line: line)

		XCTAssertEqual(defaults.string(forKey: LegacyKeys.geminiSessionMode), GeminiAgentToolPreferences.PermissionLevel.fullAccess.sessionModeID, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.openCodeSessionMode), OpenCodeAgentConfig.managedFullAccessSessionModeID, file: file, line: line)
		XCTAssertEqual(defaults.string(forKey: LegacyKeys.cursorPermissionLevel), CursorAgentToolPreferences.PermissionLevel.fullAccess.rawValue, file: file, line: line)
	}

	func testStorageKeysDecodeToExpectedAccounts() {
		XCTAssertEqual(AgentPermissionSecureDomain.subagent.storageKey, "rp.agent.permissions.subagent.v1")
		XCTAssertEqual(AgentPermissionSecureDomain.codex.storageKey, "rp.agent.permissions.codex.v1")
		XCTAssertEqual(AgentPermissionSecureDomain.claude.storageKey, "rp.agent.permissions.claude.v1")
		XCTAssertEqual(AgentPermissionSecureDomain.gemini.storageKey, "rp.agent.permissions.gemini.v1")
		XCTAssertEqual(AgentPermissionSecureDomain.openCode.storageKey, "rp.agent.permissions.openCode.v1")
		XCTAssertEqual(AgentPermissionSecureDomain.cursor.storageKey, "rp.agent.permissions.cursor.v1")
	}

	func testMissingValuesUseDefaultsAndPersistSecureDocuments() throws {
		let secureStrings = InMemorySecureStrings()
		let store = makeStore(secureStrings: secureStrings)

		let codex = store.codexPermissions()

		XCTAssertEqual(codex.approvalPolicy(), .onRequest)
		XCTAssertEqual(codex.sandboxMode(), .workspaceWrite)
		XCTAssertEqual(codex.approvalReviewer(), .user)
		XCTAssertEqual(codex.bashToolEnabled, true)
		XCTAssertNotNil(secureStrings.values[AgentPermissionSecureDomain.codex.storageKey])
		XCTAssertTrue(store.diagnostics().isEmpty)
	}

	func testSubagentV1ProviderPoliciesMigrateToConcreteSafeDefaults() throws {
		let secureStrings = InMemorySecureStrings()
		secureStrings.values[AgentPermissionSecureDomain.subagent.storageKey] = try encode(
			SecureSubagentPermissionDocument(
				schemaVersion: 1,
				globalPolicyRaw: AgentSubagentPermissionPolicy.custom.rawValue,
				providerPoliciesRawByProviderID: [
					AgentProviderBindingID.claude.rawValue: ProviderSubagentPermissionPolicy.inheritProviderSettings.rawValue,
					AgentProviderBindingID.codex.rawValue: ProviderSubagentPermissionPolicy.safeManaged.rawValue
				]
			)
		)
		let store = makeStore(secureStrings: secureStrings)

		XCTAssertEqual(store.subagentPolicy(), .custom)
		XCTAssertEqual(store.providerSubagentPermissionLevel(for: .claude), .claude(.requireApproval))
		XCTAssertEqual(store.providerSubagentPermissionLevel(for: .codex), .codex(.defaultPermission))

		let persisted = try decode(
			SecureSubagentPermissionDocument.self,
			from: secureStrings.values[AgentPermissionSecureDomain.subagent.storageKey]
		)
		XCTAssertEqual(persisted.schemaVersion, SecureSubagentPermissionDocument.currentSchemaVersion)
		XCTAssertNil(persisted.providerPoliciesRawByProviderID)
		XCTAssertEqual(persisted.providerPermissionLevelsRawByProviderID?[AgentProviderBindingID.claude.rawValue], ClaudeAgentToolPreferences.PermissionLevel.requireApproval.rawValue)
		XCTAssertEqual(persisted.providerPermissionLevelsRawByProviderID?[AgentProviderBindingID.codex.rawValue], CodexAgentToolPreferences.PermissionLevel.defaultPermission.rawValue)
	}

	func testSecureReadDoesNotSafeShadowStalePermissivePlaintextMirrorsAcrossDomains() throws {
		let defaults = makeProbingDefaults()
		writePermissiveLegacyMirrors(to: defaults)
		let secureStrings = InMemorySecureStrings()
		secureStrings.values[AgentPermissionSecureDomain.subagent.storageKey] = try encode(
			SecureSubagentPermissionDocument(
				globalPolicyRaw: AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue,
				providerPermissionLevelsRawByProviderID: [
					AgentProviderBindingID.claude.rawValue: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.rawValue
				]
			)
		)
		secureStrings.values[AgentPermissionSecureDomain.codex.storageKey] = try encode(
			SecureCodexPermissionDocument(
				approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
				sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
				bashToolEnabled: true,
				mcpServerTogglesByNormalizedName: ["externalsrv": true]
			)
		)
		secureStrings.values[AgentPermissionSecureDomain.claude.storageKey] = try encode(
			SecureClaudePermissionDocument(
				permissionModeRaw: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
				bashToolEnabled: true,
				mcpStrictModeEnabled: false
			)
		)
		secureStrings.values[AgentPermissionSecureDomain.gemini.storageKey] = try encode(
			SecureGeminiPermissionDocument(sessionModeID: GeminiAgentToolPreferences.PermissionLevel.fullAccess.sessionModeID)
		)
		secureStrings.values[AgentPermissionSecureDomain.openCode.storageKey] = try encode(
			SecureOpenCodePermissionDocument(permissionLevelRaw: OpenCodeAgentToolPreferences.PermissionLevel.fullAccess.rawValue)
		)
		secureStrings.values[AgentPermissionSecureDomain.cursor.storageKey] = try encode(
			SecureCursorPermissionDocument(permissionLevelRaw: CursorAgentToolPreferences.PermissionLevel.fullAccess.rawValue)
		)
		let store = makeStore(secureStrings: secureStrings, defaults: defaults)
		defaults.mutationCount = 0

		XCTAssertEqual(store.subagentPolicy(), .inheritProviderSettings)
		XCTAssertEqual(store.providerSubagentPermissionLevel(for: .claude), .claude(.fullAccess))
		XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.codexPermissions().approvalReviewer(), .user)
		XCTAssertEqual(store.codexPermissions().bashToolEnabled, true)
		XCTAssertTrue(store.codexPermissions().mcpServerEnabled(normalizedName: "externalsrv"))
		XCTAssertEqual(store.claudePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.claudePermissions().bashToolEnabled, true)
		XCTAssertEqual(store.claudePermissions().mcpStrictModeEnabled, false)
		XCTAssertEqual(store.geminiPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.openCodePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)

		_ = store.subagentPermissions()
		_ = store.codexPermissions()
		_ = store.claudePermissions()
		_ = store.geminiPermissions()
		_ = store.openCodePermissions()
		_ = store.cursorPermissions()

		XCTAssertEqual(defaults.mutationCount, 0)
		assertPermissiveLegacyMirrors(in: defaults)
	}

	func testLegacyMigrationPreservesSecurePermissiveValuesBeforeSafeShadowingPlaintextMirrors() {
		let defaults = makeDefaults()
		writePermissiveLegacyMirrors(to: defaults)
		let secureStrings = InMemorySecureStrings()
		let store = makeStore(secureStrings: secureStrings, defaults: defaults)

		XCTAssertEqual(store.subagentPolicy(), .inheritProviderSettings)
		XCTAssertEqual(store.providerSubagentPermissionLevel(for: .claude), .claude(.requireApproval))
		XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.codexPermissions().bashToolEnabled, true)
		XCTAssertTrue(store.codexPermissions().mcpServerEnabled(normalizedName: "externalsrv"))
		XCTAssertEqual(store.claudePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.claudePermissions().bashToolEnabled, true)
		XCTAssertEqual(store.claudePermissions().mcpStrictModeEnabled, false)
		XCTAssertEqual(store.geminiPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.openCodePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)
		for domain in AgentPermissionSecureDomain.allCases {
			XCTAssertNotNil(secureStrings.values[domain.storageKey], "Missing migrated secure document for \(domain)")
		}

		assertSafeLegacyMirrors(in: defaults)
	}

	func testSecurePermissiveWritesSafeShadowPlaintextMirrorsAcrossDomains() {
		let defaults = makeDefaults()
		writePermissiveLegacyMirrors(to: defaults)
		let store = makeStore(defaults: defaults)

		XCTAssertTrue(store.updateSubagentPermissions { document in
			document.globalPolicyRaw = AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue
			document.providerPermissionLevelsRawByProviderID = [
				AgentProviderBindingID.claude.rawValue: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.rawValue
			]
		})
		XCTAssertTrue(store.setCodexPermissionLevel(.fullAccess))
		XCTAssertEqual(store.codexPermissions().approvalReviewer(), .user)
		XCTAssertTrue(store.updateCodexPermissions { document in
			document.bashToolEnabled = true
			document.mcpServerTogglesByNormalizedName = ["externalsrv": true]
		})
		XCTAssertTrue(store.setClaudePermissionLevel(.fullAccess))
		XCTAssertTrue(store.updateClaudePermissions { document in
			document.bashToolEnabled = true
			document.mcpStrictModeEnabled = false
		})
		XCTAssertTrue(store.setGeminiPermissionLevel(.fullAccess))
		XCTAssertTrue(store.setOpenCodePermissionLevel(.fullAccess))
		XCTAssertTrue(store.setCursorPermissionLevel(.fullAccess))

		XCTAssertEqual(store.subagentPolicy(), .inheritProviderSettings)
		XCTAssertEqual(store.providerSubagentPermissionLevel(for: .claude), .claude(.fullAccess))
		XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.claudePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.geminiPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.openCodePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)

		assertSafeLegacyMirrors(in: defaults)
	}

	func testSecureWriteReadRoundTrip() {
		let secureStrings = InMemorySecureStrings()
		let store = makeStore(secureStrings: secureStrings)

		XCTAssertTrue(store.setCursorPermissionLevel(.fullAccess))
		XCTAssertTrue(store.setCodexPermissionLevel(.autoReview))

		let reloaded = makeStore(secureStrings: secureStrings)
		XCTAssertEqual(reloaded.cursorPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(reloaded.codexPermissions().permissionLevel(), .autoReview)
		XCTAssertEqual(reloaded.codexPermissions().approvalReviewer(), .autoReview)
		XCTAssertEqual(
			Set(secureStrings.values.keys),
			Set([AgentPermissionSecureDomain.cursor.storageKey, AgentPermissionSecureDomain.codex.storageKey])
		)
		XCTAssertTrue(secureStrings.legacyIntegrityValues.isEmpty)
		XCTAssertTrue(secureStrings.integritySavedKeys.isEmpty)
	}

	func testValidLegacyIntegrityDocumentMigratesToPlainJSON() throws {
		let secureStrings = InMemorySecureStrings()
		let key = AgentPermissionSecureDomain.cursor.storageKey
		secureStrings.plainReadErrors[key] = KeychainService.KeychainError.invalidData
		secureStrings.legacyIntegrityValues[key] = try encode(
			SecureCursorPermissionDocument(permissionLevelRaw: CursorAgentToolPreferences.PermissionLevel.fullAccess.rawValue)
		)
		let store = makeStore(secureStrings: secureStrings)

		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)
		XCTAssertNil(store.diagnostic(for: .cursor))
		XCTAssertTrue(secureStrings.savedKeys.contains(key))
		XCTAssertTrue(secureStrings.integritySavedKeys.isEmpty)

		secureStrings.plainReadErrors.removeValue(forKey: key)
		let migrated = try decode(SecureCursorPermissionDocument.self, from: secureStrings.values[key])
		XCTAssertEqual(migrated.permissionLevel(), .fullAccess)
	}

	func testMissingPlainDocumentStillMigratesValidLegacyIntegrityDocument() throws {
		let secureStrings = InMemorySecureStrings()
		let key = AgentPermissionSecureDomain.claude.storageKey
		secureStrings.legacyIntegrityValues[key] = try encode(
			SecureClaudePermissionDocument(
				permissionModeRaw: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
				bashToolEnabled: true,
				mcpStrictModeEnabled: false
			)
		)
		let store = makeStore(secureStrings: secureStrings)

		XCTAssertEqual(store.claudePermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.claudePermissions().bashToolEnabled, true)
		XCTAssertEqual(store.claudePermissions().mcpStrictModeEnabled, false)
		XCTAssertNil(store.diagnostic(for: .claude))
		XCTAssertTrue(secureStrings.savedKeys.contains(key))

		let migrated = try decode(SecureClaudePermissionDocument.self, from: secureStrings.values[key])
		XCTAssertEqual(migrated.permissionLevel(), .fullAccess)
	}

	func testInvalidRawValuesNormalizeToSafeDefaults() throws {
		let secureStrings = InMemorySecureStrings()
		secureStrings.values[AgentPermissionSecureDomain.codex.storageKey] = try encode(
			SecureCodexPermissionDocument(
				approvalPolicyRaw: "invalid-approval",
				sandboxModeRaw: "invalid-sandbox",
				approvalReviewerRaw: "invalid-reviewer",
				bashToolEnabled: nil,
				mcpServerTogglesByNormalizedName: [
					" ExternalSrv ": true,
					"\t": true
				]
			)
		)
		let store = makeStore(secureStrings: secureStrings)

		let codex = store.codexPermissions()

		XCTAssertEqual(codex.approvalPolicy(), .onRequest)
		XCTAssertEqual(codex.sandboxMode(), .workspaceWrite)
		XCTAssertEqual(codex.approvalReviewer(), .user)
		XCTAssertEqual(codex.bashToolEnabled, true)
		XCTAssertTrue(codex.mcpServerEnabled(normalizedName: "externalsrv"))
		XCTAssertFalse(codex.mcpServerTogglesByNormalizedName?.keys.contains("") ?? true)

		let persisted = try decode(
			SecureCodexPermissionDocument.self,
			from: secureStrings.values[AgentPermissionSecureDomain.codex.storageKey]
		)
		XCTAssertEqual(persisted.approvalPolicy(), .onRequest)
		XCTAssertEqual(persisted.sandboxMode(), .workspaceWrite)
		XCTAssertEqual(persisted.approvalReviewer(), .user)
		XCTAssertEqual(persisted.mcpServerTogglesByNormalizedName, ["externalsrv": true])
	}

	func testWriteFailureDoesNotCacheUnsafeRequestedValues() {
		let secureStrings = InMemorySecureStrings()
		secureStrings.failSaves = true
		let store = makeStore(secureStrings: secureStrings)

		XCTAssertFalse(store.setCursorPermissionLevel(.fullAccess))

		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .managedDefault)
		XCTAssertNil(secureStrings.values[AgentPermissionSecureDomain.cursor.storageKey])
		XCTAssertEqual(store.diagnostic(for: .cursor)?.kind, .keychainWriteFailed)
	}

	func testDecodeFailureFailsClosedToSafeDefaultsAndSafeShadowsLegacyValues() {
		let secureStrings = InMemorySecureStrings()
		let defaults = makeDefaults()
		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		ClaudeAgentToolPreferences.setBashToolEnabled(true, defaults: defaults)
		ClaudeAgentToolPreferences.setMCPStrictModeEnabled(false, defaults: defaults)
		secureStrings.values[AgentPermissionSecureDomain.claude.storageKey] = "{not-json"
		let store = makeStore(secureStrings: secureStrings, defaults: defaults)

		let claude = store.claudePermissions()

		XCTAssertEqual(claude.permissionMode(), ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode)
		XCTAssertEqual(claude.bashToolEnabled, false)
		XCTAssertEqual(claude.mcpStrictModeEnabled, true)
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .requireApproval)
		XCTAssertFalse(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults))
		XCTAssertTrue(ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults))
		XCTAssertEqual(store.diagnostic(for: .claude)?.kind, .decodeFailed)
	}

	func testIntegrityFailureFailsClosedToSafeDefaults() {
		let secureStrings = InMemorySecureStrings()
		let key = AgentPermissionSecureDomain.openCode.storageKey
		secureStrings.plainReadErrors[key] = KeychainService.KeychainError.invalidData
		secureStrings.integrityReadErrors[key] = KeychainService.KeychainError.integrityCheckFailed
		let store = makeStore(secureStrings: secureStrings)

		let openCode = store.openCodePermissions()

		XCTAssertEqual(openCode.permissionLevel(), .managedDefault)
		XCTAssertEqual(openCode.sessionModeID(), OpenCodeAgentConfig.managedSessionModeID)
		XCTAssertEqual(store.diagnostic(for: .openCode)?.kind, .integrityCheckFailed)
	}

	func testResetAgentPermissionsToSafeDefaultsWritesAllDomainsAndClearsDiagnostics() throws {
		let defaults = makeDefaults()
		writePermissiveLegacyMirrors(to: defaults)
		let secureStrings = InMemorySecureStrings()
		let notificationCenter = NotificationCenter()
		let store = makeStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		let failingKey = AgentPermissionSecureDomain.claude.storageKey
		secureStrings.plainReadErrors[failingKey] = KeychainService.KeychainError.invalidData
		secureStrings.integrityReadErrors[failingKey] = KeychainService.KeychainError.integrityCheckFailed
		_ = store.claudePermissions()
		XCTAssertEqual(store.diagnostic(for: .claude)?.kind, .integrityCheckFailed)

		var notifications: [(AgentPermissionSecureDomain, Bool)] = []
		let observer = notificationCenter.addObserver(
			forName: .agentPermissionSecureStoreDidChange,
			object: store,
			queue: nil
		) { note in
			guard
				let rawDomain = note.userInfo?[AgentPermissionSecureStoreNotificationKey.domain] as? String,
				let domain = AgentPermissionSecureDomain(rawValue: rawDomain),
				let writeSucceeded = note.userInfo?[AgentPermissionSecureStoreNotificationKey.writeSucceeded] as? Bool
			else { return }
			notifications.append((domain, writeSucceeded))
		}
		defer { notificationCenter.removeObserver(observer) }

		let result = store.resetAgentPermissionsToSafeDefaults()

		XCTAssertTrue(result.succeeded)
		XCTAssertEqual(Set(result.succeededDomains), Set(AgentPermissionSecureDomain.allCases))
		XCTAssertTrue(result.failedDomains.isEmpty)
		XCTAssertTrue(store.diagnostics().isEmpty)
		XCTAssertEqual(Set(secureStrings.values.keys), Set(AgentPermissionSecureDomain.allCases.map(\.storageKey)))
		XCTAssertTrue(secureStrings.integritySavedKeys.isEmpty)
		assertSafeLegacyMirrors(in: defaults)
		XCTAssertEqual(Set(notifications.map { $0.0 }), Set(AgentPermissionSecureDomain.allCases))
		XCTAssertTrue(notifications.allSatisfy { $0.1 })

		let subagent = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.values[AgentPermissionSecureDomain.subagent.storageKey])
		XCTAssertEqual(subagent.globalPolicy(), .safeManaged)
		let codex = try decode(SecureCodexPermissionDocument.self, from: secureStrings.values[AgentPermissionSecureDomain.codex.storageKey])
		XCTAssertEqual(codex.approvalPolicy(), .onRequest)
		XCTAssertEqual(codex.sandboxMode(), .workspaceWrite)
		XCTAssertEqual(codex.approvalReviewer(), .user)
		XCTAssertEqual(codex.bashToolEnabled, false)
		XCTAssertNil(codex.mcpServerTogglesByNormalizedName)
		let claude = try decode(SecureClaudePermissionDocument.self, from: secureStrings.values[AgentPermissionSecureDomain.claude.storageKey])
		XCTAssertEqual(claude.permissionLevel(), .requireApproval)
		XCTAssertEqual(claude.bashToolEnabled, false)
		XCTAssertEqual(claude.mcpStrictModeEnabled, true)
		let gemini = try decode(SecureGeminiPermissionDocument.self, from: secureStrings.values[AgentPermissionSecureDomain.gemini.storageKey])
		XCTAssertEqual(gemini.permissionLevel(), .default)
		let openCode = try decode(SecureOpenCodePermissionDocument.self, from: secureStrings.values[AgentPermissionSecureDomain.openCode.storageKey])
		XCTAssertEqual(openCode.permissionLevel(), .managedDefault)
		let cursor = try decode(SecureCursorPermissionDocument.self, from: secureStrings.values[AgentPermissionSecureDomain.cursor.storageKey])
		XCTAssertEqual(cursor.permissionLevel(), .managedDefault)
	}

	func testResetAgentPermissionsToSafeDefaultsReportsWriteFailures() throws {
		let defaults = makeDefaults()
		writePermissiveLegacyMirrors(to: defaults)
		let secureStrings = InMemorySecureStrings()
		let notificationCenter = NotificationCenter()
		let codexKey = AgentPermissionSecureDomain.codex.storageKey
		secureStrings.values[codexKey] = try encode(
			SecureCodexPermissionDocument(
				approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
				sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
				bashToolEnabled: true,
				mcpServerTogglesByNormalizedName: ["externalsrv": true]
			)
		)
		let store = makeStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		secureStrings.failSaveKeys = [codexKey]

		var notifications: [(AgentPermissionSecureDomain, Bool)] = []
		let observer = notificationCenter.addObserver(
			forName: .agentPermissionSecureStoreDidChange,
			object: store,
			queue: nil
		) { note in
			guard
				let rawDomain = note.userInfo?[AgentPermissionSecureStoreNotificationKey.domain] as? String,
				let domain = AgentPermissionSecureDomain(rawValue: rawDomain),
				let writeSucceeded = note.userInfo?[AgentPermissionSecureStoreNotificationKey.writeSucceeded] as? Bool
			else { return }
			notifications.append((domain, writeSucceeded))
		}
		defer { notificationCenter.removeObserver(observer) }

		let result = store.resetAgentPermissionsToSafeDefaults()

		XCTAssertFalse(result.succeeded)
		XCTAssertEqual(result.failedDomains, [.codex])
		XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)
		XCTAssertNil(secureStrings.values[codexKey])
		XCTAssertEqual(store.codexPermissions().permissionLevel(), .defaultPermission)
		XCTAssertEqual(store.codexPermissions().bashToolEnabled, false)
		assertSafeLegacyMirrors(in: defaults)
		XCTAssertEqual(notifications.first { $0.0 == .codex }?.1, false)
		XCTAssertEqual(Set(notifications.map { $0.0 }), Set(AgentPermissionSecureDomain.allCases))

		secureStrings.failSaveKeys = []
		let reloaded = makeStore(
			secureStrings: secureStrings,
			defaults: defaults,
			notificationCenter: notificationCenter
		)
		XCTAssertEqual(reloaded.codexPermissions().permissionLevel(), .defaultPermission)
		XCTAssertEqual(reloaded.codexPermissions().bashToolEnabled, false)
		XCTAssertFalse(reloaded.codexPermissions().mcpServerEnabled(normalizedName: "externalsrv"))
	}

	func testPerDomainIsolation() {
		let secureStrings = InMemorySecureStrings()
		let store = makeStore(secureStrings: secureStrings)

		XCTAssertTrue(store.setCodexPermissionLevel(.fullAccess))
		XCTAssertTrue(store.setCursorPermissionLevel(.fullAccess))

		XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)

		secureStrings.values[AgentPermissionSecureDomain.cursor.storageKey] = "corrupt"
		store.clearCachedDocuments()

		XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .managedDefault)
		XCTAssertEqual(store.diagnostic(for: .cursor)?.kind, .decodeFailed)
		XCTAssertNil(store.diagnostic(for: .codex))
	}

	func testLegacyMigrationStoresSecureDocumentAndSafeShadowsLegacyValue() {
		let defaults = makeDefaults()
		let secureStrings = InMemorySecureStrings()
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		let store = makeStore(secureStrings: secureStrings, defaults: defaults)

		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertNotNil(secureStrings.values[AgentPermissionSecureDomain.cursor.storageKey])
	}

	func testLegacySafeShadowRunsAfterReleasingSecureStoreLockDuringMigration() {
		let defaults = makeProbingDefaults()
		let secureStrings = InMemorySecureStrings()
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
		let store = makeStore(secureStrings: secureStrings, defaults: defaults)
		let probeQueue = DispatchQueue(label: "AgentPermissionSecureStoreTests.migrationLockProbe")
		var didProbe = false
		var probeCompleted = false
		defaults.onMutation = {
			guard !didProbe else { return }
			didProbe = true
			let semaphore = DispatchSemaphore(value: 0)
			probeQueue.async {
				_ = store.diagnostics()
				semaphore.signal()
			}
			probeCompleted = semaphore.wait(timeout: .now() + 2) == .success
		}

		XCTAssertEqual(store.cursorPermissions().permissionLevel(), .fullAccess)

		XCTAssertTrue(didProbe)
		XCTAssertTrue(probeCompleted)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertNotNil(secureStrings.values[AgentPermissionSecureDomain.cursor.storageKey])
	}

	func testSecureStoreChangeNotificationPostsAfterReleasingSecureStoreLock() {
		let notificationCenter = NotificationCenter()
		let store = makeStore(notificationCenter: notificationCenter)
		let probeQueue = DispatchQueue(label: "AgentPermissionSecureStoreTests.notificationLockProbe")
		var observerCalled = false
		var probeCompleted = false
		let observer = notificationCenter.addObserver(
			forName: .agentPermissionSecureStoreDidChange,
			object: store,
			queue: nil
		) { _ in
			observerCalled = true
			let semaphore = DispatchSemaphore(value: 0)
			probeQueue.async {
				_ = store.diagnostics()
				semaphore.signal()
			}
			probeCompleted = semaphore.wait(timeout: .now() + 2) == .success
		}
		defer { notificationCenter.removeObserver(observer) }

		XCTAssertTrue(store.setCursorPermissionLevel(.fullAccess))

		XCTAssertTrue(observerCalled)
		XCTAssertTrue(probeCompleted)
	}

	func testProviderHelpersUseExplicitSecureStoreForSensitiveValuesOnly() {
		let defaults = makeDefaults()
		let secureStrings = InMemorySecureStrings()
		let store = makeStore(secureStrings: secureStrings, defaults: defaults)

		CodexAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
		CodexAgentToolPreferences.setBashToolEnabled(true, defaults: defaults, secureStore: store)
		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: "ExternalSrv",
			isEnabled: true,
			defaults: defaults,
			secureStore: store
		)
		CodexAgentToolPreferences.setSearchToolEnabled(false, defaults: defaults)

		ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
		ClaudeAgentToolPreferences.setBashToolEnabled(true, defaults: defaults, secureStore: store)
		ClaudeAgentToolPreferences.setMCPStrictModeEnabled(false, defaults: defaults, secureStore: store)
		ClaudeAgentToolPreferences.setToolSearchEnabled(false, defaults: defaults)

		GeminiAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
		CursorAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)

		XCTAssertEqual(CodexAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .fullAccess)
		XCTAssertTrue(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: store))
		XCTAssertTrue(CodexAgentToolPreferences.mcpServerEnabled(normalizedName: "externalsrv", defaults: defaults, secureStore: store))
		XCTAssertFalse(CodexAgentToolPreferences.searchToolEnabled(defaults: defaults), "Non-sensitive search remains in UserDefaults")
		XCTAssertEqual(CodexAgentToolPreferences.permissionLevel(defaults: defaults), .defaultPermission, "Legacy custom UserDefaults path is safe-shadowed, not permissive")
		XCTAssertFalse(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults))

		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .fullAccess)
		XCTAssertTrue(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: store))
		XCTAssertFalse(ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: store))
		XCTAssertFalse(ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults), "Non-sensitive tool search remains in UserDefaults")
		XCTAssertEqual(ClaudeAgentToolPreferences.permissionLevel(defaults: defaults), .requireApproval)
		XCTAssertFalse(ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults))
		XCTAssertTrue(ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults))

		XCTAssertEqual(GeminiAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .fullAccess)
		XCTAssertEqual(OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .fullAccess)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .fullAccess)
		XCTAssertEqual(GeminiAgentToolPreferences.permissionLevel(defaults: defaults), .default)
		XCTAssertEqual(OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
		XCTAssertEqual(CursorAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
	}
}
