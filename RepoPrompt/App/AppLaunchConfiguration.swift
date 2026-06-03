import Foundation
import CoreGraphics

struct AppLaunchConfiguration {
	enum ForcedRootRoute: Equatable {
		case main
	}

	static let current = AppLaunchConfiguration(processInfo: .processInfo)

	let isUITestSession: Bool
	let suppressesWindowRestore: Bool
	let suppressesWindowPersistence: Bool
	let suppressesWindowModePersistence: Bool
	let suppressesAgentSessionPersistence: Bool
	let suppressesNonessentialLaunchSideEffects: Bool
	let forcedRootRoute: ForcedRootRoute?
	let forcedWindowUIMode: WindowUIMode?
	#if DEBUG
	let agentChatStress: AgentChatStressLaunchConfiguration?
	#endif

	private init(processInfo: ProcessInfo) {
		let arguments = Set(processInfo.arguments)
		let environment = processInfo.environment
		let isUITestSession = arguments.contains("-RP_UITEST")
		#if DEBUG
		let agentChatStress = arguments.contains("-RP_AGENT_CHAT_STRESS")
			? AgentChatStressLaunchConfiguration(environment: environment)
			: nil
		let isAgentChatStressEnabled = agentChatStress != nil
		#else
		let isAgentChatStressEnabled = false
		#endif
		let isDeterministicUITestLaunch = isUITestSession || isAgentChatStressEnabled
		#if DEBUG
		let allowsStressAgentSessionPersistence = agentChatStress?.allowsAgentSessionPersistence ?? false
		#else
		let allowsStressAgentSessionPersistence = false
		#endif

		self.isUITestSession = isUITestSession
		self.suppressesWindowRestore = isDeterministicUITestLaunch
		self.suppressesWindowPersistence = isDeterministicUITestLaunch
		self.suppressesWindowModePersistence = isDeterministicUITestLaunch
		self.suppressesAgentSessionPersistence = isDeterministicUITestLaunch && !allowsStressAgentSessionPersistence
		self.suppressesNonessentialLaunchSideEffects = isDeterministicUITestLaunch
		self.forcedRootRoute = isDeterministicUITestLaunch ? .main : nil
		self.forcedWindowUIMode = isAgentChatStressEnabled ? .agent : (isUITestSession ? .ide : nil)
		#if DEBUG
		self.agentChatStress = agentChatStress
		#endif
	}
}

#if DEBUG
struct AgentChatStressLaunchConfiguration: Equatable {
	enum Scenario: String, Equatable {
		case mixedToolLoop
		case richToolChurn
		case assistantMarkdownChurn
		case assistantMarkdownMegaChurn
		case persistedCodexReplayChurn
		case persistedAgentSessionFixture

		var requiresPersistedSessionRestore: Bool {
			switch self {
			case .persistedCodexReplayChurn, .persistedAgentSessionFixture:
				return true
			case .mixedToolLoop, .richToolChurn, .assistantMarkdownChurn, .assistantMarkdownMegaChurn:
				return false
			}
		}
	}

	enum MutationRefreshPolicy: String, Equatable {
		case urgentPerMutation
		case deferred
	}

	let autoStart: Bool
	let showOverlay: Bool
	let scenario: Scenario
	let insertionInterval: TimeInterval
	let warmupTurnCount: Int
	let toolStepRepeatCount: Int
	let mutationRefreshPolicy: MutationRefreshPolicy
	let maxVisibleEventLogEntries: Int
	let catastrophicJumpThresholdPoints: CGFloat
	let catastrophicHistoricalExposureBlockThreshold: Int
	let workspaceName: String?
	let workspaceRootPaths: [String]
	let createsWorkspaceIfNeeded: Bool
	let allowsAgentSessionPersistence: Bool
	let agentSessionFixtureName: String?

	init(environment: [String: String]) {
		autoStart = Self.boolValue(environment["RP_AGENT_STRESS_AUTO_START"], default: true)
		showOverlay = Self.boolValue(environment["RP_AGENT_STRESS_SHOW_OVERLAY"], default: true)
		scenario = Scenario(rawValue: environment["RP_AGENT_STRESS_SCENARIO"] ?? "") ?? .mixedToolLoop
		insertionInterval = max(0.05, Double(environment["RP_AGENT_STRESS_INTERVAL_MS"] ?? "120").map { $0 / 1000.0 } ?? 0.12)
		warmupTurnCount = max(1, Int(environment["RP_AGENT_STRESS_WARMUP_TURNS"] ?? "4") ?? 4)
		toolStepRepeatCount = min(8, max(1, Int(environment["RP_AGENT_STRESS_TOOL_STEP_REPEAT"] ?? "1") ?? 1))
		mutationRefreshPolicy = MutationRefreshPolicy(rawValue: environment["RP_AGENT_STRESS_REFRESH_POLICY"] ?? "") ?? .urgentPerMutation
		maxVisibleEventLogEntries = max(5, Int(environment["RP_AGENT_STRESS_MAX_LOG_ENTRIES"] ?? "24") ?? 24)
		catastrophicJumpThresholdPoints = max(80, Double(environment["RP_AGENT_STRESS_CATASTROPHIC_JUMP_POINTS"] ?? "220").map { CGFloat($0) } ?? 220)
		catastrophicHistoricalExposureBlockThreshold = max(4, Int(environment["RP_AGENT_STRESS_CATASTROPHIC_EXPOSURE_BLOCKS"] ?? "10") ?? 10)
		workspaceName = Self.normalizedString(environment["RP_AGENT_STRESS_WORKSPACE_NAME"])
		workspaceRootPaths = Self.pathListValue(
			environment["RP_AGENT_STRESS_WORKSPACE_ROOTS"] ?? environment["RP_AGENT_STRESS_WORKSPACE_ROOT"]
		)
		createsWorkspaceIfNeeded = Self.boolValue(
			environment["RP_AGENT_STRESS_CREATE_WORKSPACE_IF_NEEDED"],
			default: workspaceName != nil && !workspaceRootPaths.isEmpty
		)
		allowsAgentSessionPersistence = Self.boolValue(
			environment["RP_AGENT_STRESS_ALLOW_SESSION_PERSISTENCE"],
			default: scenario.requiresPersistedSessionRestore
		)
		agentSessionFixtureName = Self.normalizedString(environment["RP_AGENT_STRESS_AGENT_SESSION_FIXTURE"])
			?? (scenario == .persistedAgentSessionFixture
				? "review-idle-scroll-coalescing-fix-97A6BA23.json"
				: nil)
	}

	private static func boolValue(_ raw: String?, default defaultValue: Bool) -> Bool {
		guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
			return defaultValue
		}
		switch normalized {
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		default:
			return defaultValue
		}
	}

	private static func normalizedString(_ raw: String?) -> String? {
		guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}

	private static func pathListValue(_ raw: String?) -> [String] {
		guard let raw else { return [] }
		return raw
			.split(whereSeparator: { $0 == "\n" || $0 == ";" })
			.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}
}
#endif
