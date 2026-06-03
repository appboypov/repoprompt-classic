import SwiftUI

// MARK: - Scroll Placement & Reason

enum AgentTranscriptScrollPlacement {
	case top
	case bottom

	var unitPoint: UnitPoint {
		switch self {
		case .top:
			return .top
		case .bottom:
			return .bottom
		}
	}
}

enum AgentTranscriptScrollReason {
	case sessionSwitchRestore
	case transcriptChangeWhilePinned
	case transcriptChangeWhileDetached
	case historyCompressionTransition
	case blockerDismissed
	case bottomButtonTap
	case userSendWhilePinned
	case userSendWhileDetached
	case waitingStateChange
	case busyStateChange
	case bottomClearanceChange
	case nearBottomReengaged
}

// MARK: - Scroll Intent

enum AgentTranscriptScrollIntent {
	case bottom(animated: Bool, reason: AgentTranscriptScrollReason)
	case anchor(AgentTranscriptAnchor, placement: AgentTranscriptScrollPlacement, animated: Bool, reason: AgentTranscriptScrollReason)
	case viewportTarget(AgentTranscriptViewportTargetID, placement: AgentTranscriptScrollPlacement, animated: Bool, reason: AgentTranscriptScrollReason)

	var isAnimated: Bool {
		switch self {
		case .bottom(let animated, _), .anchor(_, _, let animated, _), .viewportTarget(_, _, let animated, _):
			return animated
		}
	}

	var reason: AgentTranscriptScrollReason {
		switch self {
		case .bottom(_, let reason), .anchor(_, _, _, let reason), .viewportTarget(_, _, _, let reason):
			return reason
		}
	}

	var scheduleDelay: TimeInterval {
		switch reason {
		case .sessionSwitchRestore, .userSendWhilePinned, .userSendWhileDetached, .bottomButtonTap:
			return 0
		case .bottomClearanceChange, .blockerDismissed:
			return 0.05
		default:
			return 0.2
		}
	}

	var settleDelay: TimeInterval {
		switch reason {
		case .sessionSwitchRestore:
			return 0.05
		case .userSendWhilePinned, .userSendWhileDetached, .bottomButtonTap:
			return 0.18
		case .bottomClearanceChange, .blockerDismissed:
			return 0.2
		default:
			return 0.12
		}
	}

	var allowsRevisionMismatch: Bool {
		switch reason {
		case .sessionSwitchRestore,
				.userSendWhilePinned,
				.userSendWhileDetached,
				.transcriptChangeWhilePinned,
				.transcriptChangeWhileDetached,
				.historyCompressionTransition,
				.waitingStateChange,
				.busyStateChange,
				.bottomClearanceChange,
				.nearBottomReengaged,
				.bottomButtonTap:
			return true
		case .blockerDismissed:
			return false
		}
	}
}

// MARK: - Compression & Restore

enum AgentTranscriptCompressionRestoreStrategy {
	case preserveBottom
	case restoreAnchor(AgentTranscriptAnchor)
}

// MARK: - Rehydrate Restore

enum AgentTranscriptRehydrateRestoreTarget: Equatable {
	case liveBottom
	case detached(DetachedViewportAuthority?)
}

enum AgentTranscriptRehydrateRestorePhase: Equatable {
	case idle
	case awaitingHydration(tabID: UUID, target: AgentTranscriptRehydrateRestoreTarget)
	case awaitingLayout(tabID: UUID, presentationRevision: Int, target: AgentTranscriptRehydrateRestoreTarget)
	case driving(tabID: UUID, presentationRevision: Int, target: AgentTranscriptRehydrateRestoreTarget)

	var tabID: UUID? {
		switch self {
		case .idle:
			return nil
		case .awaitingHydration(let tabID, _),
			.awaitingLayout(let tabID, _, _),
			.driving(let tabID, _, _):
			return tabID
		}
	}

	var target: AgentTranscriptRehydrateRestoreTarget? {
		switch self {
		case .idle:
			return nil
		case .awaitingHydration(_, let target),
			.awaitingLayout(_, _, let target),
			.driving(_, _, let target):
			return target
		}
	}

	var isActive: Bool {
		if case .idle = self {
			return false
		}
		return true
	}
}

// MARK: - Viewport Types

struct AgentTranscriptBlockViewportFrame: Equatable {
	let blockID: String
	let minY: CGFloat
	let maxY: CGFloat
}

struct AgentTranscriptRehydrateRetryKey: Equatable {
	let tabID: UUID
	let presentationRevision: Int
	let layoutPassToken: UInt64

	init(tabID: UUID, presentationRevision: Int, layoutPassToken: UInt64 = 0) {
		self.tabID = tabID
		self.presentationRevision = presentationRevision
		self.layoutPassToken = layoutPassToken
	}
}

struct AgentTranscriptRestoreSignal: Equatable {
	let tabID: UUID?
	let bindingsHydrated: Bool
	let presentationRevision: Int
}

struct AgentTranscriptViewportCandidate: Equatable {
	let targetID: AgentTranscriptViewportTargetID
	let semanticAnchor: AgentTranscriptAnchor?
	let sequenceIndex: Int?
	let fallbackBlockID: String?
	let minY: CGFloat
	let maxY: CGFloat
}


struct AgentTranscriptScrollMetrics: Equatable {
	var distanceToBottom: CGFloat = 0
	var visibleMinY: CGFloat = 0
	var contentHeight: CGFloat = 0
	var viewportHeight: CGFloat = 0
}

// MARK: - User Scroll Types

enum DetachedManualScrollDirection: String, Equatable {
	case towardHistory
	case towardLiveBottom
	case unknown

	var debugLabel: String { rawValue }
}

enum AgentTranscriptUserScrollPhase: String, Equatable {
	case idle
	case tracking
	case interacting
	case decelerating
	case animating
}

struct AgentTranscriptUserScrollSession: Equatable {
	let startedAt: Date
	let baselineMetrics: AgentTranscriptScrollMetrics
	var latestMetrics: AgentTranscriptScrollMetrics
	var latestIntent: DetachedManualScrollDirection
	var lastIntentAt: Date?
	var observedProgress: Bool
}

struct AgentTranscriptCompletedUserScrollSession: Equatable {
	let startedAt: Date
	let endedAt: Date
	let baselineMetrics: AgentTranscriptScrollMetrics
	let finalMetrics: AgentTranscriptScrollMetrics
	let latestIntent: DetachedManualScrollDirection
	let observedProgress: Bool
}

enum AgentTranscriptBottomScrollOutcomeSource: Equatable {
	case explicitBottomAction
	case pinnedFollowMaintenance
}

struct PendingBottomScrollOutcome: Equatable {
	let tabID: UUID
	let startedAt: Date
	let baselineDistanceToBottom: CGFloat
	let source: AgentTranscriptBottomScrollOutcomeSource
	var didExecute = false
}

enum AgentTranscriptPinnedMaintenanceInvalidationReason: String, Equatable {
	case userInteractionBegan
	case detached
	case liveBottomReattached
	case blockerPresented
	case activationRestoreStarted
	case tabChanged
	case explicitBottomAction
	case idleBoundaryDetachResolved
	case staleSuppression
}

// MARK: - Stress Telemetry

#if DEBUG
struct AgentChatStressTelemetryState {
	var sampleIndex = 0
	var scrollIntentCount = 0
	var lastSettledBottomReason: String?
	var detachCount = 0
	var repinCount = 0
	var unexpectedPinnedDriftCount = 0
	var maxUnexpectedPinnedDrift: CGFloat = 0
	var unexpectedJumpCount = 0
	var maxUnexpectedJumpMagnitude: CGFloat = 0
	var unexpectedHistoricalExposureCount = 0
	var maxUnexpectedHistoricalExposureBlocksBelowTop = 0
	var lastUnexpectedHistoricalExposureBlockID: String?
	var lastUnexpectedHistoricalExposureKind: String?
	var largeStreamingPinnedJumpCount = 0
	var maxLargeStreamingPinnedJumpMagnitude: CGFloat = 0
	var largeStreamingHistoricalExposureCount = 0
	var maxLargeStreamingHistoricalExposureBlocksBelowTop = 0
	var lastLargeStreamingHistoricalExposureBlockID: String?
	var lastLargeStreamingHistoricalExposureKind: String?
	var lastLargeStreamingAssistantActiveAt: Date?
	var wasTrackingLargeStreamingJump = false
	var wasTrackingLargeStreamingHistoricalExposure = false
	var detachedJumpCount = 0
	var maxDetachedJumpMagnitude: CGFloat = 0
	var detachedAnchorChangeCount = 0
	var detachedSnapToTopCount = 0
	var detachedAcceptedDriftCount = 0
	var detachedRestoreIntentCount = 0
	var lastDetachedRebaseAction: String?
	var smoothSendScrollCount = 0
	var smoothSendStartCount = 0
	var smoothSendCompletionCount = 0
	var smoothSendFinishedWithoutAnimationCount = 0
	var smoothSendInterruptedCount = 0
	var smoothSendCorrectiveScrollCount = 0
	var lastSmoothSendSettleDurationMS: Double?
	var maxSmoothSendSettleDurationMS: Double = 0
	var viewportFrameUpdateCount = 0
	var viewportCandidateUpdateCount = 0
	var lastScrollIntentReason: String?
	var wasTrackingPinnedDrift = false
	var wasTrackingJump = false
	var wasTrackingHistoricalExposure = false
	var wasTrackingDetachedJump = false
	var coldRestoreStartCount = 0
	var coldRestoreScrollCount = 0
	var coldRestoreCorrectiveScrollCount = 0
	var coldRestoreCompletionCount = 0
	var lastColdRestoreSettleDurationMS: Double?
	var maxColdRestoreSettleDurationMS: Double = 0
	var manualScrollGestureCount = 0
	var manualScrollEffectCount = 0
	var manualScrollTowardHistoryGestureCount = 0
	var manualScrollTowardHistoryEffectCount = 0
	var manualScrollTowardLiveBottomGestureCount = 0
	var manualScrollTowardLiveBottomEffectCount = 0
	var manualScrollUnknownDirectionCount = 0
	var lastManualScrollDirection: String?
	var lastManualScrollOutcome: String?
	var scrollToBottomTapCount = 0
	var scrollToBottomSuccessCount = 0
	var scrollToBottomNoEffectCount = 0
	var lastScrollToBottomOutcome: String?
}
#endif

// MARK: - Detached Rebase & Viewport

struct AgentDetachedRebaseKey: Equatable {
	let baseTargetID: AgentTranscriptViewportTargetID?
	let baseAnchor: AgentTranscriptAnchor?
	let baseSequenceIndex: Int?
	let family: AgentDetachedAuthorityFamily?
}

struct DetachedViewportTarget {
	let anchor: AgentTranscriptAnchor?
	let baseSequenceIndex: Int?
}

struct RepinGraceState: Equatable {
	let presentationRevision: Int
	let reason: AgentTranscriptScrollReason
	let activatedAt: Date
}

// MARK: - Smooth Send & Pinned Bottom

enum SmoothPinnedSendPhase: Equatable {
	case preservingBottomBeforeAnimation
	case animatingToBottom
}

struct SmoothPinnedSendState: Equatable {
	let userMessageID: UUID
	let originUserSequenceIndex: Int
	let startedAt: Date
	let presentationRevision: Int
	var phase: SmoothPinnedSendPhase
	var lastLayoutMutationAt: Date
	var correctiveScrollCount: Int
}

enum PinnedBottomRequestSource: Equatable {
	case smoothSend
	case transcriptChangeWhilePinned
	case waitingStateChange
	case busyStateChange
	case bottomClearanceChange

	var priority: Int {
		switch self {
		case .smoothSend:
			return 0
		case .transcriptChangeWhilePinned:
			return 1
		case .waitingStateChange, .busyStateChange:
			return 2
		case .bottomClearanceChange:
			return 3
		}
	}

	var gateDelay: TimeInterval {
		switch self {
		case .smoothSend:
			return 0
		case .transcriptChangeWhilePinned:
			return 0
		case .waitingStateChange, .busyStateChange:
			return 0.05
		case .bottomClearanceChange:
			return 0.08
		}
	}

	var scrollReason: AgentTranscriptScrollReason {
		switch self {
		case .smoothSend:
			return .userSendWhilePinned
		case .transcriptChangeWhilePinned:
			return .transcriptChangeWhilePinned
		case .waitingStateChange:
			return .waitingStateChange
		case .busyStateChange:
			return .busyStateChange
		case .bottomClearanceChange:
			return .bottomClearanceChange
		}
	}
}

struct AgentTranscriptPinnedMaintenanceRequest: Equatable {
	let source: PinnedBottomRequestSource
	let generation: UInt64
	let requestedAt: Date
}
