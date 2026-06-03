import Foundation
import CoreGraphics

enum AgentTranscriptAutoFollowRearmPolicy {
	static func shouldDetachFromLiveBottom(
		runtime: AgentTranscriptScrollRuntimeState,
		latestManualIntent: DetachedManualScrollDirection,
		progress: AgentTranscriptViewportProgress,
		minimumViewportEscapeDistance: CGFloat,
		suppressGeometryDetach: Bool,
		suppressRepinGraceDetach: Bool
	) -> Bool {
		guard runtime.isPinnedToLiveBottom,
			runtime.isUserInteractingWithScroll,
			latestManualIntent == .towardHistory,
			!suppressGeometryDetach,
			!suppressRepinGraceDetach
		else {
			return false
		}
		return AgentTranscriptScrollProgressPolicy.hasTowardHistoryViewportEscape(
			progress: progress,
			visibleMinYThreshold: minimumViewportEscapeDistance
		)
	}

	static func shouldDetachFromLiveBottomAfterRunBecomesIdle(
		runtime: AgentTranscriptScrollRuntimeState,
		idleTransitionArmed: Bool,
		hasTowardHistoryManualIntent: Bool,
		progress: AgentTranscriptViewportProgress,
		minimumEscapeDistance: CGFloat
	) -> Bool {
		guard runtime.isPinnedToLiveBottom,
			!runtime.isDetachedFromLiveBottom,
			idleTransitionArmed,
			hasTowardHistoryManualIntent,
			minimumEscapeDistance > 0,
			!runtime.isInteractionBlocked,
			!runtime.isRehydrateRestoreActive
		else {
			return false
		}
		return AgentTranscriptScrollProgressPolicy.hasTowardHistoryViewportEscape(
			progress: progress,
			visibleMinYThreshold: minimumEscapeDistance
		)
	}

	static func shouldForceRepinDetachedAtActualBottom(
		runtime: AgentTranscriptScrollRuntimeState,
		actualBottomDistanceThreshold: CGFloat
	) -> Bool {
		guard runtime.isDetachedFromLiveBottom,
			!runtime.isPinnedToLiveBottom,
			runtime.distanceToBottom <= actualBottomDistanceThreshold,
			!runtime.canScrollTowardLiveBottom,
			!runtime.isInteractionBlocked,
			!runtime.isRehydrateRestoreActive,
			!runtime.isProgrammaticScrollInFlight
		else {
			return false
		}
		return true
	}
}
