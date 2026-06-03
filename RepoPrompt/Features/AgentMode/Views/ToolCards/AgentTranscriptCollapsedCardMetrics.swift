import CoreGraphics

enum AgentTranscriptCollapsedCardMetrics {
	static var collapsedHeight: CGFloat { FontScalePreset.current.scaledMetric(56) }
	static let compactChipLineLimit: Int = 1
	static let compactChipMaxVisiblePaths: Int = 2
}
