import AppKit
import Combine
import XCTest
@testable import RepoPrompt

final class FontScalePresetTests: XCTestCase {
	func testScaledMetricScalesCGFloatRelativeToNormal() {
		XCTAssertEqual(FontScalePreset.normal.scaledMetric(CGFloat(21)), 21, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.large.scaledMetric(CGFloat(21)), 24, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.extraLarge.scaledMetric(CGFloat(21)), 27, accuracy: 0.0001)
	}

	func testScaledMetricScalesDoubleRelativeToNormal() {
		XCTAssertEqual(FontScalePreset.large.scaledMetric(28.0), 32.0, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.extraLarge.scaledMetric(28.0), 36.0, accuracy: 0.0001)
	}

	func testScaledClampedAppliesOptionalBoundsAfterScaling() {
		XCTAssertEqual(FontScalePreset.large.scaledClamped(21, min: 25), 25, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.extraLarge.scaledClamped(21, max: 25), 25, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.normal.scaledClamped(21, min: 10, max: 30), 21, accuracy: 0.0001)
	}

	func testAppKitFontHelpersUseScaledPointSizes() {
		XCTAssertEqual(FontScalePreset.large.nsFont.pointSize, 16, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.large.nsFont(sizeAtNormal: 21).pointSize, 24, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.extraLarge.monospacedNSFont(sizeAtNormal: 21).pointSize, 27, accuracy: 0.0001)
	}

	func testRowHeightScalesFromNormalPreset() {
		XCTAssertEqual(FontScalePreset.normal.rowHeight, 28, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.large.rowHeight, 32, accuracy: 0.0001)
		XCTAssertEqual(FontScalePreset.extraLarge.rowHeight, 36, accuracy: 0.0001)
	}

	func testAgentSidebarSizingScalesWithFontPreset() {
		XCTAssertEqual(AgentSidebarSizing.minWidth(for: .normal), 300, accuracy: 0.0001)
		XCTAssertEqual(AgentSidebarSizing.idealWidth(for: .normal), 340, accuracy: 0.0001)
		XCTAssertEqual(AgentSidebarSizing.maxWidth(for: .normal), 425, accuracy: 0.0001)

		let extraLargeMin = AgentSidebarSizing.minWidth(for: .extraLarge)
		let extraLargeIdeal = AgentSidebarSizing.idealWidth(for: .extraLarge)
		let extraLargeMax = AgentSidebarSizing.maxWidth(for: .extraLarge)
		XCTAssertEqual(extraLargeMin, CGFloat(300) * 18 / 14, accuracy: 0.0001)
		XCTAssertEqual(extraLargeIdeal, CGFloat(340) * 18 / 14, accuracy: 0.0001)
		XCTAssertEqual(extraLargeMax, CGFloat(425) * 18 / 14, accuracy: 0.0001)
		XCTAssertLessThanOrEqual(extraLargeMin, extraLargeIdeal)
		XCTAssertLessThanOrEqual(extraLargeIdeal, extraLargeMax)

		let resolvedMax = AgentSidebarSizing.resolvedMaxWidth(for: 600, preset: .extraLarge)
		let resolvedIdeal = AgentSidebarSizing.resolvedIdealWidth(for: 600, preset: .extraLarge)
		XCTAssertEqual(resolvedMax, extraLargeMin, accuracy: 0.0001)
		XCTAssertGreaterThanOrEqual(resolvedIdeal, extraLargeMin)
		XCTAssertLessThanOrEqual(resolvedIdeal, resolvedMax)
	}

	@MainActor
	func testFreezeUnfreezeDoNotPublishObjectWillChangeWithoutPresetChange() {
		let manager = FontScaleManager.shared
		let originalPreset = manager.preset
		manager.unfreeze()
		defer {
			manager.unfreeze()
			if manager.preset != originalPreset {
				manager.setPreset(originalPreset)
			}
		}

		var objectWillChangeCount = 0
		let cancellable = manager.objectWillChange.sink {
			objectWillChangeCount += 1
		}
		defer { cancellable.cancel() }

		manager.freeze()
		manager.freeze()
		manager.unfreeze()
		manager.unfreeze()

		XCTAssertFalse(manager.isFrozen)
		XCTAssertEqual(objectWillChangeCount, 0)
	}

	@MainActor
	func testUnfreezeAppliesCachedPresetRequestedWhileFrozen() {
		let manager = FontScaleManager.shared
		let originalPreset = manager.preset
		let cachedPreset: FontScalePreset = originalPreset == .large ? .extraLarge : .large
		manager.unfreeze()
		defer {
			manager.unfreeze()
			if manager.preset != originalPreset {
				manager.setPreset(originalPreset)
			}
		}

		manager.freeze()
		manager.setPreset(cachedPreset)
		XCTAssertEqual(manager.preset, originalPreset)
		XCTAssertTrue(manager.isFrozen)

		manager.unfreeze()
		XCTAssertFalse(manager.isFrozen)
		XCTAssertEqual(manager.preset, cachedPreset)
	}

#if DEBUG
	func testFontScalePerfDiagnosticsRecordsFontHelperCountersWhenEnabled() {
		let originalPreset = FontScalePreset.current
		FontScalePerfDiagnostics.setDebugProcessOverrideEnabled(true)
		FontScalePerfDiagnostics.clearRecentMetrics()
		defer {
			FontScalePreset.updateCachedPreset(originalPreset)
			FontScalePerfDiagnostics.clearRecentMetrics()
			FontScalePerfDiagnostics.setDebugProcessOverrideEnabled(nil)
		}

		_ = FontScalePreset.large.font
		_ = FontScalePreset.large.standardFont
		_ = FontScalePreset.large.scaledMetric(CGFloat(21))
		_ = FontScalePreset.large.scaledMetric(28.0)
		_ = FontScalePreset.large.scaledClamped(21, min: 10, max: 40)
		_ = FontScalePreset.large.swiftUIFont(sizeAtNormal: 12)
		_ = FontScalePreset.large.nsFont
		_ = FontScalePreset.large.nsFont(sizeAtNormal: 12)
		_ = FontScalePreset.large.monospacedNSFont(sizeAtNormal: 12)
		_ = FontScalePreset.current
		_ = FontScalePreset.large.rowHeight
		_ = FontScalePreset.currentRowHeight
		FontScalePreset.updateCachedPreset(.large)
		FontScalePerfDiagnostics.event("fontScale.unit.mark", fields: ["source": "unitTest"])

		let payload = FontScalePerfDiagnostics.debugStateSnapshot(
			lineLimit: 20,
			currentPreset: FontScalePreset.current,
			managerPreset: nil,
			managerIsFrozen: nil
		)
		let counters = payload["counters"] as? [String: Int] ?? [:]
		let lines = payload["lines"] as? [String] ?? []

		XCTAssertEqual(counters["helper.font"], 1)
		XCTAssertEqual(counters["helper.standardFont"], 1)
		XCTAssertGreaterThanOrEqual(counters["helper.scaledMetric.cgFloat"] ?? 0, 4)
		XCTAssertEqual(counters["helper.scaledMetric.double"], 1)
		XCTAssertEqual(counters["helper.scaledClamped"], 1)
		XCTAssertEqual(counters["helper.swiftUIFont"], 1)
		XCTAssertEqual(counters["helper.nsFont"], 1)
		XCTAssertEqual(counters["helper.nsFont.sized"], 1)
		XCTAssertEqual(counters["helper.monospacedNSFont"], 1)
		XCTAssertGreaterThanOrEqual(counters["helper.current"] ?? 0, 2)
		XCTAssertGreaterThanOrEqual(counters["helper.rowHeight"] ?? 0, 2)
		XCTAssertEqual(counters["helper.currentRowHeight"], 1)
		XCTAssertEqual(counters["event.fontScale.cache.update"], 1)
		XCTAssertTrue(lines.contains { $0.contains("fontScale.cache.update") })
		XCTAssertTrue(lines.contains { $0.contains("fontScale.unit.mark") })
	}
#endif
}

