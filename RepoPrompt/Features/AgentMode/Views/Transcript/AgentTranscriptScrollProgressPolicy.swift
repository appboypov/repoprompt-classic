import Foundation
import CoreGraphics

enum AgentTranscriptUserScrollIntentResolver {
	/// Resolves manual scroll direction from viewport movement plus an already-sanitized
	/// distance-to-bottom delta. Callers must zero `distanceDelta` when content or
	/// viewport size changed, because raw distance-to-bottom also includes relayout.
	static func resolve(
		distanceDelta: CGFloat,
		visibleMinYDelta: CGFloat,
		distanceThreshold: CGFloat,
		visibleMinYThreshold: CGFloat
	) -> DetachedManualScrollDirection {
		if distanceDelta >= distanceThreshold || visibleMinYDelta <= -visibleMinYThreshold {
			return .towardHistory
		}
		if distanceDelta <= -distanceThreshold || visibleMinYDelta >= visibleMinYThreshold {
			return .towardLiveBottom
		}
		return .unknown
	}

	/// Variant used while logically pinned to live bottom. Distance-only growth is
	/// never accepted as upward escape, but sanitized distance shrink can still
	/// indicate motion back toward the live bottom.
	static func resolvePinnedLiveBottomFollowIntent(
		distanceDelta: CGFloat,
		visibleMinYDelta: CGFloat,
		distanceThreshold: CGFloat,
		visibleMinYThreshold: CGFloat
	) -> DetachedManualScrollDirection {
		if visibleMinYDelta <= -visibleMinYThreshold {
			return .towardHistory
		}
		if distanceDelta <= -distanceThreshold || visibleMinYDelta >= visibleMinYThreshold {
			return .towardLiveBottom
		}
		return .unknown
	}

	static func resolve(
		verticalVelocity: CGFloat,
		minimumMagnitude: CGFloat = 1
	) -> DetachedManualScrollDirection {
		guard abs(verticalVelocity) >= minimumMagnitude else {
			return .unknown
		}
		return verticalVelocity > 0 ? .towardHistory : .towardLiveBottom
	}

	/// Fallback for short/slow gestures where no single geometry callback crosses
	/// the frame-delta threshold, but cumulative viewport movement from the scroll
	/// session baseline clearly indicates user intent. Uses only viewport origin so
	/// content-height relayout cannot masquerade as intent.
	static func resolveFromCumulativeViewportMovement(
		visibleMinYDelta: CGFloat,
		visibleMinYThreshold: CGFloat
	) -> DetachedManualScrollDirection {
		if visibleMinYDelta <= -visibleMinYThreshold {
			return .towardHistory
		}
		if visibleMinYDelta >= visibleMinYThreshold {
			return .towardLiveBottom
		}
		return .unknown
	}
}

enum AgentTranscriptScrollProgressPolicy {
	static func effectiveDistanceDeltaForManualScroll(
		oldMetrics: AgentTranscriptScrollMetrics,
		newMetrics: AgentTranscriptScrollMetrics,
		layoutMutationThreshold: CGFloat
	) -> CGFloat {
		let contentHeightDelta = abs(newMetrics.contentHeight - oldMetrics.contentHeight)
		let viewportHeightDelta = abs(newMetrics.viewportHeight - oldMetrics.viewportHeight)
		guard contentHeightDelta < layoutMutationThreshold,
			viewportHeightDelta < layoutMutationThreshold
		else {
			return 0
		}
		return newMetrics.distanceToBottom - oldMetrics.distanceToBottom
	}

	static func hasTowardHistoryViewportEscape(
		progress: AgentTranscriptViewportProgress,
		visibleMinYThreshold: CGFloat
	) -> Bool {
		guard visibleMinYThreshold > 0 else { return false }
		let visibleMinYDecrease = progress.baselineVisibleMinY - progress.currentVisibleMinY
		return visibleMinYDecrease >= visibleMinYThreshold
	}

	static func hasMeaningfulManualProgress(
		direction: DetachedManualScrollDirection,
		progress: AgentTranscriptViewportProgress,
		distanceThreshold _: CGFloat,
		visibleMinYThreshold: CGFloat
	) -> Bool {
		let visibleMinYDelta = progress.currentVisibleMinY - progress.baselineVisibleMinY

		switch direction {
		case .towardHistory:
			return visibleMinYDelta <= -visibleMinYThreshold
		case .towardLiveBottom:
			return visibleMinYDelta >= visibleMinYThreshold
		case .unknown:
			return abs(visibleMinYDelta) >= visibleMinYThreshold
		}
	}
}
