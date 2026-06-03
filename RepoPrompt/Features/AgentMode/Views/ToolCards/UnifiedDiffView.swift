import SwiftUI

// MARK: - Unified Diff View

/// Renders unified diffs with the AppKit-backed path.
struct UnifiedDiffView: View {
	let largeBodyMaxHeight: CGFloat
	private let document: UnifiedDiffDocument

	init(diff: String, largeBodyMaxHeight: CGFloat = 260) {
		self.largeBodyMaxHeight = largeBodyMaxHeight
		self.document = UnifiedDiffCardRendering.parse(diff)
	}

	var body: some View {
		LargeUnifiedDiffContainer(
			document: document,
			largeBodyMaxHeight: largeBodyMaxHeight
		)
		.background(Color(nsColor: .textBackgroundColor).opacity(0.3))
		.cornerRadius(6)
	}
}

private struct LargeUnifiedDiffContainer: View {
	let document: UnifiedDiffDocument
	let largeBodyMaxHeight: CGFloat

	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject private var fontScale = FontScaleManager.shared

	private var fontPreset: FontScalePreset { fontScale.preset }

	private var fontSize: CGFloat {
		CGFloat(max(fontPreset.rawValue - 2, 9))
	}

	private var resolvedMaxHeight: CGFloat {
		fontPreset.scaledClamped(largeBodyMaxHeight, max: 420)
	}

	private var resolvedHeight: CGFloat {
		UnifiedDiffCardRendering.estimatedHeight(
			for: document,
			fontSize: fontSize,
			fontPreset: fontPreset,
			maxHeight: resolvedMaxHeight
		)
	}

	var body: some View {
		UnifiedDiffTextView(
			document: document,
			fontSize: fontSize,
			fontPreset: fontPreset,
			colorScheme: colorScheme
		)
		.frame(maxWidth: .infinity)
		.frame(height: resolvedHeight)
	}
}

// MARK: - Preview

#if DEBUG
struct UnifiedDiffView_Previews: PreviewProvider {
	static var previews: some View {
		UnifiedDiffView(diff: """
	diff --git a/file.swift b/file.swift
	index abc123..def456 100644
	--- a/file.swift
	+++ b/file.swift
	@@ -10,7 +10,8 @@ func example() {
			let x = 1
	-    let y = 2
	+    let y = 3
	+    let z = 4
			return x + y
		}
	""")
		.padding()
		.frame(width: 500)
	}
}
#endif
