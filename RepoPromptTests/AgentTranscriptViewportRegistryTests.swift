import XCTest
@testable import RepoPrompt

@MainActor
final class AgentTranscriptViewportRegistryTests: XCTestCase {
	func testReplaceBlockFramesStoresFramesByBlockID() {
		let registry = AgentTranscriptViewportRegistry()
		let first = AgentTranscriptBlockViewportFrame(blockID: "first", minY: -12, maxY: 80)
		let second = AgentTranscriptBlockViewportFrame(blockID: "second", minY: 48, maxY: 140)

		registry.replaceBlockFrames([first, second])

		XCTAssertEqual(registry.blockFrame(for: "first"), first)
		XCTAssertEqual(registry.blockFrame(for: "second"), second)
	}

	func testReplaceViewportCandidatesStoresCandidatesByTargetID() {
		let registry = AgentTranscriptViewportRegistry()
		let rowID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
		let candidate = AgentTranscriptViewportCandidate(
			targetID: .row(rowID),
			semanticAnchor: nil,
			sequenceIndex: 7,
			fallbackBlockID: "activity:block",
			minY: -18,
			maxY: 44
		)

		registry.replaceViewportCandidates([candidate])

		XCTAssertEqual(registry.viewportCandidate(for: .row(rowID)), candidate)
		XCTAssertEqual(registry.viewportCandidates, [candidate])
	}

	func testClearRemovesStoredViewportData() {
		let registry = AgentTranscriptViewportRegistry()
		let rowID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
		registry.replaceBlockFrames([
			AgentTranscriptBlockViewportFrame(blockID: "block", minY: 0, maxY: 100)
		])
		registry.replaceViewportCandidates([
			AgentTranscriptViewportCandidate(
				targetID: .row(rowID),
				semanticAnchor: nil,
				sequenceIndex: nil,
				fallbackBlockID: "block",
				minY: 0,
				maxY: 40
			)
		])

		registry.clear()

		XCTAssertNil(registry.blockFrame(for: "block"))
		XCTAssertNil(registry.viewportCandidate(for: .row(rowID)))
		XCTAssertTrue(registry.viewportCandidates.isEmpty)
	}

	func testDetachedViewportTrackingModeContainsOnlyTargetedRows() {
		let targeted = AgentDetachedViewportTrackingMode.targetedRows(["block-a", "block-b"])

		XCTAssertTrue(targeted.shouldTrackCandidates)
		XCTAssertTrue(targeted.containsRowTracking(for: "block-a"))
		XCTAssertFalse(targeted.containsRowTracking(for: "block-c"))
		XCTAssertFalse(AgentDetachedViewportTrackingMode.blockOnly.containsRowTracking(for: "block-a"))
		XCTAssertFalse(AgentDetachedViewportTrackingMode.off.shouldTrackCandidates)
	}
}
