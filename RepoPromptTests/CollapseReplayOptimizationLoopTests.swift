//
//  CollapseReplayOptimizationLoopTests.swift
//  RepoPromptTests
//

#if DEBUG
import CoreServices
import Darwin
import XCTest
@testable import RepoPrompt

@MainActor
final class CollapseReplayOptimizationLoopTests: XCTestCase {
	private let parentFolderCount = 20
	private let newFilesPerParent = 512
	private let namePayloadLength = 96
	private let warmupCount = 3
	private let measuredCount = 15
	private let benchmarkTelemetryProfile = BenchmarkTelemetryProfile.current

	private struct BenchmarkTelemetryProfile {
		let name: String
		let includeVerbosePayload: Bool
		let captureMemoryTelemetry: Bool
		let captureIgnoreMatcherMetrics: Bool
		let enableDetailedReplayWallAttribution: Bool

		static var current: BenchmarkTelemetryProfile {
			let verbose = isTruthy(ProcessInfo.processInfo.environment["REPOPROMPT_REPLAY_BENCHMARK_VERBOSE_TELEMETRY"])
			return BenchmarkTelemetryProfile(
				name: verbose ? "verbose" : "compact",
				includeVerbosePayload: verbose,
				captureMemoryTelemetry: verbose,
				captureIgnoreMatcherMetrics: verbose,
				enableDetailedReplayWallAttribution: verbose
			)
		}

		private static func isTruthy(_ value: String?) -> Bool {
			guard let value = value?.lowercased() else { return false }
			return ["1", "true", "yes", "on"].contains(value)
		}
	}

	private let serviceEventIgnorePayloadKeys = [
		"serviceEventUnknownRegularFileDecisionCountMedian",
		"serviceEventParentStateCacheHitCountMedian",
		"serviceEventParentStateCacheMissCountMedian",
		"serviceEventExactParentStateCountMedian",
		"serviceEventUnsupportedParentStateCountMedian",
		"serviceEventDirectLeafCheckCountMedian",
		"serviceEventDirectLeafIgnoredCountMedian",
		"serviceEventFallbackFullTargetIgnoreCheckCountMedian",
		"serviceEventFallbackFullTargetIgnoredCountMedian",
		"serviceEventExactFullTargetIgnoreCheckCountMedian",
		"serviceEventSkippedKnownOrControlTargetIgnoreCheckCountMedian"
	]

	private let serviceEventPathMappingPayloadKeys = [
		"serviceEventPathMappingRawPathCountMedian",
		"serviceEventPathMappingFastStandardRootHitCountMedian",
		"serviceEventPathMappingFastCanonicalRootHitCountMedian",
		"serviceEventPathMappingFallbackStandardizationCountMedian",
		"serviceEventPathMappingRejectedUnsafePathCountMedian"
	]

	private let verboseBenchmarkPayloadKeys = [
		"residentMemoryDeltaTrimmedMeanMB",
		"residentMemoryDeltaP95MB",
		"mallocMemoryDeltaTrimmedMeanMB",
		"mallocMemoryDeltaP95MB",
		"memoryTelemetryNote",
		"ignoreOutcomeEvaluationCountMedian",
		"ignorePatternVisitCountMedian",
		"ignorePatternMatchAttemptCountMedian",
		"ignorePatternPrefilterCheckCountMedian",
		"ignorePatternPrefilterSkipCountMedian",
		"ignorePatternPrefilterPassCountMedian",
		"ignoreMaxPatternVisitsPerOutcomeMedian",
		"ignoreMaxPatternAttemptsPerOutcomeMedian",
		"ignoreOutcomeZeroAttemptCountMedian",
		"ignoreOutcomeOneAttemptCountMedian",
		"ignoreOutcomeTwoToFourAttemptCountMedian",
		"ignoreOutcomeFiveToEightAttemptCountMedian",
		"ignoreOutcomeNineToSixteenAttemptCountMedian",
		"ignoreOutcomeSeventeenToThirtyTwoAttemptCountMedian",
		"ignoreOutcomeThirtyThreeToSixtyFourAttemptCountMedian",
		"ignoreOutcomeSixtyFivePlusAttemptCountMedian",
		"ignoreMeanPatternVisitsPerOutcome",
		"ignoreMeanPatternAttemptsPerOutcome",
		"ignorePrefilterSkipRatePercent",
		"cleanupScanInvocationCountMedian",
		"cleanupScannedCandidateCountMedian",
		"updateFolderStatesMeanMS",
		"fileAddParentLookupCountMedian",
		"fileAddParentLookupHitCountMedian",
		"fileAddParentLookupMissCountMedian",
		"fileAddParentLookupRootReturnCountMedian",
		"fileAddUniqueParentPathCountMedian",
		"fileAddInsertFileCountMedian",
		"fileAddInsertParentDerivationCountMedian",
		"fileAddInsertParentLookupHitCountMedian",
		"fileAddInsertParentLookupMissCountMedian",
		"fileAddCreateMissingParentFolderCallCountMedian",
		"fileAddCreateMissingParentFolderCreatedCountMedian",
		"fileAddFileHierarchyInsertFileCountMedian",
		"fileAddEligibilityDurationTrimmedMeanMS",
		"fileAddEligibilityMeanPerCallUS",
		"fileAddEligibilityMaxDurationMS",
		"fileAddEligibilityBatchRawInputCountMedian",
		"fileAddEligibilityBatchUniquePathCountMedian",
		"fileAddEligibilityBatchResultCountMedian",
		"fileAddEligibilityPreparedFastPathAttemptCountMedian",
		"fileAddEligibilityPreparedFastPathUsedCountMedian",
		"fileAddEligibilityPreparedFastPathFallbackCountMedian",
		"fileAddEligibilityPreparedFastPathInputCountMedian",
		"fileAddEligibilityPreparedFastPathGroupedEntryCountMedian",
		"fileAddEligibilityPreparedFastPathParentReuseHitCountMedian",
		"fileAddEligibilityPreparedFastPathParentReuseMissCountMedian",
		"fileAddEligibilityBatchParentGroupCountMedian",
		"fileAddEligibilityBatchMaxParentGroupSizeMedian",
		"fileAddEligibilityStandardizeGroupDurationTrimmedMeanMS",
		"fileAddEligibilityParentProcessingDurationTrimmedMeanMS",
		"fileAddEligibilityParentScanDurationTrimmedMeanMS",
		"fileAddEligibilityDirectoryScanGroupCountMedian",
		"fileAddEligibilityDirectoryScanFailureGroupCountMedian",
		"fileAddEligibilityDirectoryEntryCountMedian",
		"fileAddEligibilityEntriesMapDurationTrimmedMeanMS",
		"fileAddEligibilityCanonicalParentDurationTrimmedMeanMS",
		"fileAddEligibilityPreparedIgnoreRulesDurationTrimmedMeanMS",
		"fileAddEligibilityPreparedIgnoreRulesGroupCountMedian",
		"fileAddEligibilityPreparedIgnoreRulesFailureGroupCountMedian",
		"fileAddEligibilityPreparedIgnoreRulesCacheHitDirectoryCountMedian",
		"fileAddEligibilityPreparedIgnoreRulesCacheMissDirectoryCountMedian",
		"fileAddEligibilityHierarchicalIgnoreDurationTrimmedMeanMS",
		"fileAddEligibilityHierarchicalIgnoreCountMedian",
		"fileAddEligibilityHierarchicalIgnoreNoOpParentGroupCountMedian",
		"fileAddEligibilityHierarchicalIgnoreSkippedLeafCheckCountMedian",
		"fileAddEligibilityHierarchicalIgnoreMeanPerCallUS",
		"fileAddEligibilityPrefixIgnoreDurationTrimmedMeanMS",
		"fileAddEligibilityPrefixIgnoreCountMedian",
		"fileAddEligibilityPrefixIgnoreNoOpParentGroupCountMedian",
		"fileAddEligibilityPrefixIgnoreSkippedLeafCheckCountMedian",
		"fileAddEligibilityPrefixDirectLeafFastPathParentGroupCountMedian",
		"fileAddEligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCountMedian",
		"fileAddEligibilityPrefixDirectLeafFastPathLeafCheckCountMedian",
		"fileAddEligibilityPrefixDirectLeafFastPathIgnoredLeafCountMedian",
		"fileAddEligibilityPrefixDirectLeafFastPathCandidatePatternCountMaxMedian",
		"fileAddEligibilityPrefixDirectLeafFastPathDurationTrimmedMeanMS",
		"fileAddEligibilityPrefixParentRuleShapeGroupCountMedian",
		"fileAddEligibilityPrefixParentRuleDepthTotalMedian",
		"fileAddEligibilityPrefixParentRuleDepthMaxMedian",
		"fileAddEligibilityPrefixParentActivePatternCountTotalMedian",
		"fileAddEligibilityPrefixParentActivePatternCountMaxMedian",
		"fileAddEligibilityPrefixParentHasNegativePatternGroupCountMedian",
		"fileAddEligibilityPrefixIgnoreMeanPerCallUS",
		"fileAddEligibilityPrefixFullMatcherMeanPerCallUS",
		"fileAddEligibilitySingleFileFallbackUniquePathCountMedian",
		"fileAddEligibilitySingleFileFallbackDurationTrimmedMeanMS",
		"fileAddEligibilitySingleFileFallbackMeanPerCallUS",
		"fileAddEligibilityFallbackParentSymlinkCountMedian",
		"fileAddEligibilityFallbackDirectoryScanFailureCountMedian",
		"fileAddEligibilityFallbackMissingEntryCountMedian",
		"fileAddEligibilityFallbackUnknownEntryMetadataCountMedian",
		"fileAddEligibilityFallbackPreparedRulesFailureCountMedian",
		"fileAddEligibilityFallbackPreparedRuleMissCountMedian",
		"fileAddEligibilityFallbackInvalidLeafNameCountMedian",
		"fileAddEligibilityEligibleUniquePathCountMedian",
		"fileAddEligibilityIgnoredUniquePathCountMedian",
		"fileAddEligibilityMissingOrDirectoryUniquePathCountMedian",
		"fileAddEligibilitySymbolicLinkUniquePathCountMedian",
		"fileAddEligibilityNonRegularFileUniquePathCountMedian",
		"fileAddEligibilitySymlinkComponentUniquePathCountMedian",
		"fileAddEligibilityOutsideCanonicalRootUniquePathCountMedian",
		"fileAddEligibilityInvalidRelativePathUniquePathCountMedian",
		"fileAddEligibilityOutsideRootUniquePathCountMedian",
		"fileAddEligibilityInternalAccountedDurationTrimmedMeanMS",
		"fileAddEligibilityInternalUnattributedDurationTrimmedMeanMS",
		"fileAddParentContextDurationTrimmedMeanMS",
		"fileAddReplayPathMetadataDurationTrimmedMeanMS",
		"fileAddReplayPathMetadataCountMedian",
		"fileAddHandleNewFileDurationTrimmedMeanMS",
		"fileAddHandleNewFileMeanPerCallUS",
		"fileAddHandleNewFileMaxDurationMS",
		"fileAddFindExistingLookupDurationTrimmedMeanMS",
		"fileAddFileViewModelConstructionDurationTrimmedMeanMS",
		"fileAddFileViewModelConstructionCountMedian",
		"fileAddFileViewModelConstructionMeanPerCallUS",
		"fileAddSelectionCallbackAttachDurationTrimmedMeanMS",
		"fileAddHierarchyInsertDurationTrimmedMeanMS",
		"fileAddInsertFileDurationTrimmedMeanMS",
		"fileAddEnqueueDurationTrimmedMeanMS",
		"fileAddEnqueueCountMedian",
		"fileAddParentMetadataLookupDurationTrimmedMeanMS",
		"fileAddHierarchyInsertEnqueueDurationTrimmedMeanMS",
		"fileAddHandleNewFileUnattributedTrimmedMeanMS",
		"fileAddDeltaLoopUnattributedTrimmedMeanMS"
	]

	private struct BenchmarkSample {
		let primaryMS: Double
		let serviceWallMS: Double?
		let replayWallMS: Double
		let endToEndWallMS: Double
		let publishedDeltaCount: Int?
		let rawDeltaCount: Int?
		let immediateSample: RepoFileManagerViewModel.ImmediateReplayPerfSample
		let ignoreMetrics: IgnoreDebugMetrics?
		let serviceEventIgnoreDiagnostics: EventTargetIgnoreFastPathDiagnostics?
		let serviceEventPathMappingDiagnostics: EventPathMappingFastPathDiagnostics?
		let residentMemoryDeltaMB: Double?
		let mallocMemoryDeltaMB: Double?

		var flushPendingInsertsMS: Double {
			let invocationTotal = immediateSample.pendingInsertFlushTotalDurationMS
			guard invocationTotal > 0 else {
				return immediateSample.replayedChunks.reduce(0) { $0 + $1.flushPendingInsertsDurationMS }
			}
			return invocationTotal
		}

		var applyAwaitMS: Double {
			immediateSample.replayedChunks.reduce(0) { $0 + $1.applyAwaitDurationMS }
		}

		var pendingInsertFlushInvocationCount: Int {
			immediateSample.pendingInsertFlushInvocations.count
		}

		var pendingInsertFlushEntryCount: Int {
			immediateSample.pendingInsertFlushTotalEntryCount
		}

		var pendingInsertFlushMaxParentGroupCount: Int {
			immediateSample.pendingInsertFlushInvocations.map(\.parentGroupCountBeforeFlush).max() ?? 0
		}

		var cleanupScanInvocationCount: Int {
			immediateSample.replayedChunks.reduce(0) { $0 + $1.incrementalDescendantScanInvocationCount }
		}

		var cleanupScannedCandidateCount: Int {
			immediateSample.replayedChunks.reduce(0) {
				$0 + $1.incrementalDescendantScannedFolderCandidateCount + $1.incrementalDescendantScannedFileCandidateCount
			}
		}
	}

	private struct BenchmarkMemorySnapshot {
		let residentBytes: UInt64?
		let mallocBytes: UInt64?

		static func capture() -> BenchmarkMemorySnapshot {
			BenchmarkMemorySnapshot(
				residentBytes: captureResidentBytes(),
				mallocBytes: captureMallocBytes()
			)
		}

		func residentDeltaMB(to end: BenchmarkMemorySnapshot) -> Double? {
			deltaMB(start: residentBytes, end: end.residentBytes)
		}

		func mallocDeltaMB(to end: BenchmarkMemorySnapshot) -> Double? {
			deltaMB(start: mallocBytes, end: end.mallocBytes)
		}

		private func deltaMB(start: UInt64?, end: UInt64?) -> Double? {
			guard let start, let end else { return nil }
			return (Double(end) - Double(start)) / (1024.0 * 1024.0)
		}

		private static func captureResidentBytes() -> UInt64? {
			var info = mach_task_basic_info()
			var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
			let result = withUnsafeMutablePointer(to: &info) {
				$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
					task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
				}
			}
			guard result == KERN_SUCCESS else { return nil }
			return UInt64(info.resident_size)
		}

		private static func captureMallocBytes() -> UInt64? {
			guard let zone = malloc_default_zone() else { return nil }
			var stats = malloc_statistics_t()
			malloc_zone_statistics(zone, &stats)
			return UInt64(stats.size_in_use)
		}
	}

	private struct BenchmarkSummary {
		let scenario: String
		let keptSamples: [BenchmarkSample]
		let allMeasuredSamples: [BenchmarkSample]
		let medianMS: Double
		let trimmedMeanMS: Double
		let p90MS: Double
		let p95MS: Double
		let rawP95MS: Double
		let minKeptMS: Double
		let maxKeptMS: Double
		let stdDevMS: Double
		let coefficientOfVariationPercent: Double
		let headlineP95MS: Double
		let headlineTrimmedMeanMS: Double
		let headlineMedianMS: Double
		let headlineCoefficientOfVariationPercent: Double
		let flushPendingInsertsP95MS: Double
		let flushPendingInsertsTrimmedMeanMS: Double
		let flushPendingInsertsMedianMS: Double
		let flushPendingInsertsRawP95MS: Double
		let flushPendingInsertsMinKeptMS: Double
		let flushPendingInsertsMaxKeptMS: Double
		let flushPendingInsertsStdDevMS: Double
		let flushPendingInsertsCoefficientOfVariationPercent: Double
		let serviceMeanMS: Double?
		let replayMeanMS: Double
		let deltaLoopMeanMS: Double
		let flushPendingInsertsMeanMS: Double
		let applyAwaitTrimmedMeanMS: Double
		let replayWallTrimmedMeanMS: Double
		let pendingInsertFlushInvocationCountMedian: Int
		let pendingInsertFlushEntryCountMedian: Int
		let pendingInsertFlushMaxParentGroupCountMedian: Int
		let cleanupScanInvocationCountMedian: Int
		let cleanupScannedCandidateCountMedian: Int
		let updateFolderStatesMeanMS: Double
		let publishedDeltaCountMedian: Int
		let rawDeltaCountMedian: Int?
		let chunkCountMedian: Int
		let fileAddedCountMedian: Int
		let fileAddHandleNewFileCountMedian: Int?
		let fileAddNewFileCountMedian: Int?
		let fileAddExistingFileCountMedian: Int?
		let fileAddFindExistingFileLookupCountMedian: Int?
		let fileAddFindExistingStandardizedFastPathCountMedian: Int?
		let fileAddNewlyCreatedMarkerEmptySetSkipCountMedian: Int?
		let fileAddNewlyCreatedMarkerKeyBuildCountMedian: Int?
		let fileAddNewlyCreatedMarkerConsumedCountMedian: Int?
		let fileAddParentLookupCountMedian: Int?
		let fileAddParentLookupHitCountMedian: Int?
		let fileAddParentLookupMissCountMedian: Int?
		let fileAddParentLookupRootReturnCountMedian: Int?
		let fileAddUniqueParentPathCountMedian: Int?
		let fileAddInsertFileCountMedian: Int?
		let fileAddInsertParentDerivationCountMedian: Int?
		let fileAddInsertParentLookupHitCountMedian: Int?
		let fileAddInsertParentLookupMissCountMedian: Int?
		let fileAddCreateMissingParentFolderCallCountMedian: Int?
		let fileAddCreateMissingParentFolderCreatedCountMedian: Int?
		let fileAddFileHierarchyInsertFileCountMedian: Int?
	}

	private struct AggregatedFileAddPathMetrics {
		var handleNewFileCallCount = 0
		var existingFileCount = 0
		var newFileCount = 0
		var findExistingFileLookupCount = 0
		var findExistingStandardizedFastPathCount = 0
		var newlyCreatedMarkerEmptySetSkipCount = 0
		var newlyCreatedMarkerKeyBuildCount = 0
		var newlyCreatedMarkerConsumedCount = 0
		var parentFolderLookupCallCount = 0
		var parentFolderRootReturnCount = 0
		var parentFolderLookupHitCount = 0
		var parentFolderLookupMissCount = 0
		var insertFileCallCount = 0
		var insertFileParentPathDerivationCount = 0
		var insertFileParentLookupHitCount = 0
		var insertFileParentLookupMissCount = 0
		var createMissingParentFolderCallCount = 0
		var createMissingParentFolderCreatedCount = 0
		var fileHierarchyInsertFileCount = 0
		var uniqueParentPathCount = 0
		var eligibilityCheckCount = 0
		var eligibilityEligibleCount = 0
		var eligibilityIneligibleCount = 0
		var eligibilityCheckDurationMS = 0.0
		var eligibilityCheckMaxDurationMS = 0.0
		var eligibilityBatchRawInputCount = 0
		var eligibilityBatchUniquePathCount = 0
		var eligibilityBatchResultCount = 0
		var eligibilityPreparedFastPathAttemptCount = 0
		var eligibilityPreparedFastPathUsedCount = 0
		var eligibilityPreparedFastPathFallbackCount = 0
		var eligibilityPreparedFastPathInputCount = 0
		var eligibilityPreparedFastPathGroupedEntryCount = 0
		var eligibilityPreparedFastPathParentReuseHitCount = 0
		var eligibilityPreparedFastPathParentReuseMissCount = 0
		var eligibilityBatchParentGroupCount = 0
		var eligibilityBatchMaxParentGroupSize = 0
		var eligibilityStandardizeAndGroupDurationMS = 0.0
		var eligibilityParentProcessingDurationMS = 0.0
		var eligibilityDirectoryScanGroupCount = 0
		var eligibilityDirectoryScanFailureGroupCount = 0
		var eligibilityDirectoryScanDurationMS = 0.0
		var eligibilityDirectoryEntryCount = 0
		var eligibilityEntriesMapBuildDurationMS = 0.0
		var eligibilityCanonicalParentResolveDurationMS = 0.0
		var eligibilityPreparedIgnoreRulesGroupCount = 0
		var eligibilityPreparedIgnoreRulesFailureGroupCount = 0
		var eligibilityPreparedIgnoreRulesDurationMS = 0.0
		var eligibilityPreparedIgnoreRulesCacheHitDirectoryCount = 0
		var eligibilityPreparedIgnoreRulesCacheMissDirectoryCount = 0
		var eligibilityHierarchicalIgnoreCheckCount = 0
		var eligibilityHierarchicalIgnoreNoOpParentGroupCount = 0
		var eligibilityHierarchicalIgnoreSkippedLeafCheckCount = 0
		var eligibilityHierarchicalIgnoreDurationMS = 0.0
		var eligibilityPrefixIgnoreCheckCount = 0
		var eligibilityPrefixIgnoreNoOpParentGroupCount = 0
		var eligibilityPrefixIgnoreSkippedLeafCheckCount = 0
		var eligibilityPrefixIgnoreDurationMS = 0.0
		var eligibilityPrefixDirectLeafFastPathParentGroupCount = 0
		var eligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCount = 0
		var eligibilityPrefixDirectLeafFastPathLeafCheckCount = 0
		var eligibilityPrefixDirectLeafFastPathIgnoredLeafCount = 0
		var eligibilityPrefixDirectLeafFastPathCandidatePatternCountTotal = 0
		var eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax = 0
		var eligibilityPrefixDirectLeafFastPathDurationMS = 0.0
		var eligibilityPrefixParentRuleShapeGroupCount = 0
		var eligibilityPrefixParentRuleDepthTotal = 0
		var eligibilityPrefixParentRuleDepthMax = 0
		var eligibilityPrefixParentActivePatternCountTotal = 0
		var eligibilityPrefixParentActivePatternCountMax = 0
		var eligibilityPrefixParentHasNegativePatternGroupCount = 0
		var eligibilitySingleFileFallbackUniquePathCount = 0
		var eligibilitySingleFileFallbackDurationMS = 0.0
		var eligibilityFallbackParentSymlinkCount = 0
		var eligibilityFallbackDirectoryScanFailureCount = 0
		var eligibilityFallbackMissingEntryCount = 0
		var eligibilityFallbackUnknownEntryMetadataCount = 0
		var eligibilityFallbackPreparedRulesFailureCount = 0
		var eligibilityFallbackPreparedRuleMissCount = 0
		var eligibilityFallbackInvalidLeafNameCount = 0
		var eligibilityEligibleUniquePathCount = 0
		var eligibilityIgnoredUniquePathCount = 0
		var eligibilityMissingOrDirectoryUniquePathCount = 0
		var eligibilitySymbolicLinkUniquePathCount = 0
		var eligibilityNonRegularFileUniquePathCount = 0
		var eligibilitySymlinkComponentUniquePathCount = 0
		var eligibilityOutsideCanonicalRootUniquePathCount = 0
		var eligibilityInvalidRelativePathUniquePathCount = 0
		var eligibilityOutsideRootUniquePathCount = 0
		var parentContextCallCount = 0
		var parentContextCacheHitCount = 0
		var parentContextCacheMissCount = 0
		var parentContextOrderedReuseHitCount = 0
		var parentContextOrderedReuseMissCount = 0
		var parentContextParentStringBuildCount = 0
		var parentContextDurationMS = 0.0
		var replayPathMetadataCount = 0
		var replayPathMetadataDurationMS = 0.0
		var handleNewFileDurationMS = 0.0
		var handleNewFileMaxDurationMS = 0.0
		var findExistingFileLookupDurationMS = 0.0
		var fileViewModelConstructionCount = 0
		var fileViewModelConstructionDurationMS = 0.0
		var selectionCallbackAttachDurationMS = 0.0
		var fileHierarchyInsertFileDurationMS = 0.0
		var insertFileDurationMS = 0.0
		var insertFileParentPathDerivationDurationMS = 0.0
		var insertFileParentLookupDurationMS = 0.0
		var createMissingParentFolderDurationMS = 0.0
		var enqueueInsertCount = 0
		var enqueueInsertDurationMS = 0.0
	}

	private struct CollapseScenario {
		let rootURL: URL
		let rootFolder: FolderViewModel
		let service: FileSystemService
		let deltas: [FileSystemDelta]
		let fileURLs: [URL]
	}

	func testCollapseImmediateReplayAddBurstBenchmark() async throws {
		let summary = try await runBenchmark(scenario: "immediate_add_burst") { iteration in
			let scenario = try await makeScenario(iteration: iteration, createFilesOnDisk: true)
			defer { try? FileManager.default.removeItem(at: scenario.rootURL) }

			let vm = RepoFileManagerViewModel()
			vm.registerRootFolderForTesting(scenario.rootFolder, service: scenario.service)
			await vm.ensureReplayIngressRegistrationForTesting(forRootFolder: scenario.rootFolder)
			await vm.setWindowFocusedForTesting(true)
			vm.setDeltaReplayTuningForTesting(chunkSize: nil, interChunkDelayNanoseconds: nil)
			vm.setScheduledInsertFlushSuppressedForTesting(true)
			vm.setDetailedReplayWallAttributionEnabledForTesting(benchmarkTelemetryProfile.enableDetailedReplayWallAttribution)
			defer {
				vm.setScheduledInsertFlushSuppressedForTesting(false)
				vm.setDetailedReplayWallAttributionEnabledForTesting(false)
			}
			vm.resetReplayPerfSamplesForTesting()
			if benchmarkTelemetryProfile.captureIgnoreMatcherMetrics {
				IgnoreDebugMetricsRecorder.reset()
			}

			let memoryBefore = benchmarkTelemetryProfile.captureMemoryTelemetry ? BenchmarkMemorySnapshot.capture() : nil
			let startMS = benchmarkTimestampMS()
			await vm.applyFileSystemDeltasForTesting(scenario.deltas, forRootFolder: scenario.rootFolder)
			let replayWallMS = benchmarkElapsedMS(since: startMS)
			let sample = try XCTUnwrap(vm.latestImmediateReplayPerfSampleForTesting())
			let ignoreMetrics = benchmarkTelemetryProfile.captureIgnoreMatcherMetrics ? IgnoreDebugMetricsRecorder.snapshot() : nil
			let memoryAfter = benchmarkTelemetryProfile.captureMemoryTelemetry ? BenchmarkMemorySnapshot.capture() : nil
			try assertScenarioApplied(scenario, vm: vm, sample: sample)

			return BenchmarkSample(
				primaryMS: replayWallMS,
				serviceWallMS: nil,
				replayWallMS: replayWallMS,
				endToEndWallMS: replayWallMS,
				publishedDeltaCount: scenario.deltas.count,
				rawDeltaCount: nil,
				immediateSample: sample,
				ignoreMetrics: ignoreMetrics,
				serviceEventIgnoreDiagnostics: nil,
				serviceEventPathMappingDiagnostics: nil,
				residentMemoryDeltaMB: memoryBefore.flatMap { before in memoryAfter.flatMap { before.residentDeltaMB(to: $0) } },
				mallocMemoryDeltaMB: memoryBefore.flatMap { before in memoryAfter.flatMap { before.mallocDeltaMB(to: $0) } }
			)
		}
		printBenchmarkSummary(summary)
	}

	func testLazyNewlyCreatedMarkerStillSelectsCreatedFile() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("CollapseReplayCreatedSelection-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let rootFolder = FolderViewModel(
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let vm = RepoFileManagerViewModel()
		vm.registerRootFolderForTesting(rootFolder, service: service)

		try await vm.writeFileFromTool(
			userPath: "Created.swift",
			content: "struct Created {}\n",
			ifExists: "error",
			selectAfterCreate: true
		)

		let createdURL = rootURL.appendingPathComponent("Created.swift")
		let createdFile = try XCTUnwrap(vm.findFileByFullPath(createdURL.path))
		XCTAssertTrue(createdFile.isChecked)
		XCTAssertEqual(vm.selectedFiles.map(\.standardizedFullPath), [createdFile.standardizedFullPath])
	}

	func testCollapseEndToEndRawEventReplayBenchmark() async throws {
		let summary = try await runBenchmark(scenario: "end_to_end_raw_event_replay") { iteration in
			let scenario = try await makeScenario(iteration: iteration, createFilesOnDisk: true)
			defer { try? FileManager.default.removeItem(at: scenario.rootURL) }

			let vm = RepoFileManagerViewModel()
			vm.registerRootFolderForTesting(scenario.rootFolder, service: scenario.service)
			vm.setWindowFocused(true)
			vm.setDeltaReplayTuningForTesting(chunkSize: nil, interChunkDelayNanoseconds: nil)
			await vm.connectRegisteredFileSystemServicePublisherForTesting(forRootFolder: scenario.rootFolder)

			let events = scenario.fileURLs.enumerated().map { index, fileURL in
				(
					absolutePath: fileURL.path,
					flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
					eventId: FSEventStreamEventId(iteration * 10_000 + index + 1)
				)
			}
			vm.resetReplayPerfSamplesForTesting()
			vm.setDetailedReplayWallAttributionEnabledForTesting(benchmarkTelemetryProfile.enableDetailedReplayWallAttribution)
			defer {
				vm.setDetailedReplayWallAttributionEnabledForTesting(false)
			}
			if benchmarkTelemetryProfile.captureIgnoreMatcherMetrics {
				IgnoreDebugMetricsRecorder.reset()
			}

			let memoryBefore = benchmarkTelemetryProfile.captureMemoryTelemetry ? BenchmarkMemorySnapshot.capture() : nil
			let endToEndStartMS = benchmarkTimestampMS()
			let serviceStartMS = benchmarkTimestampMS()
			await scenario.service.enqueuePendingRawEventsForTesting(events)
			await scenario.service.flushPendingEventsNow()
			let serviceEventIgnoreDiagnostics = await scenario.service.lastEventTargetIgnoreFastPathDiagnosticsForTesting()
			let serviceEventPathMappingDiagnostics = await scenario.service.lastEventPathMappingFastPathDiagnosticsForTesting()
			let serviceWallMS = benchmarkElapsedMS(since: serviceStartMS)
			let sample = try await waitForImmediateReplaySample(
				vm: vm,
				expectedFileAddedCount: scenario.deltas.count
			)
			let endToEndWallMS = benchmarkElapsedMS(since: endToEndStartMS)
			let ignoreMetrics = benchmarkTelemetryProfile.captureIgnoreMatcherMetrics ? IgnoreDebugMetricsRecorder.snapshot() : nil
			let memoryAfter = benchmarkTelemetryProfile.captureMemoryTelemetry ? BenchmarkMemorySnapshot.capture() : nil
			try assertScenarioApplied(scenario, vm: vm, sample: sample, requireBoundaryFlushShape: false)

			let diagnostics = await scenario.service.lastPublishedDeltaCoalescingDiagnosticsForTesting()
			return BenchmarkSample(
				primaryMS: endToEndWallMS,
				serviceWallMS: serviceWallMS,
				replayWallMS: sample.totalDurationMS,
				endToEndWallMS: endToEndWallMS,
				publishedDeltaCount: diagnostics?.publishedDeltaCount,
				rawDeltaCount: diagnostics?.rawDeltaCount,
				immediateSample: sample,
				ignoreMetrics: ignoreMetrics,
				serviceEventIgnoreDiagnostics: serviceEventIgnoreDiagnostics,
				serviceEventPathMappingDiagnostics: serviceEventPathMappingDiagnostics,
				residentMemoryDeltaMB: memoryBefore.flatMap { before in memoryAfter.flatMap { before.residentDeltaMB(to: $0) } },
				mallocMemoryDeltaMB: memoryBefore.flatMap { before in memoryAfter.flatMap { before.mallocDeltaMB(to: $0) } }
			)
		}
		printBenchmarkSummary(summary)
	}

	private func runBenchmark(
		scenario: String,
		measure: (Int) async throws -> BenchmarkSample
	) async throws -> BenchmarkSummary {
		var measuredSamples: [BenchmarkSample] = []
		for iteration in 0..<(warmupCount + measuredCount) {
			let sample = try await measure(iteration)
			if iteration >= warmupCount {
				measuredSamples.append(sample)
			}
		}
		return summarize(scenario: scenario, samples: measuredSamples)
	}

	private func makeScenario(iteration: Int, createFilesOnDisk: Bool) async throws -> CollapseScenario {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("CollapseReplayBenchmark-\(UUID().uuidString)-\(iteration)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)

		let rootFolder = FolderViewModel(
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)

		var deltas: [FileSystemDelta] = []
		var fileURLs: [URL] = []
		deltas.reserveCapacity(parentFolderCount * newFilesPerParent)
		fileURLs.reserveCapacity(parentFolderCount * newFilesPerParent)

		for parentIndex in 0..<parentFolderCount {
			let folderName = syntheticFolderName(index: parentIndex)
			let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)
			try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
			let subfolder = FolderViewModel(
				folder: Folder(name: folderName, path: folderURL.path, modificationDate: Date()),
				rootPath: rootURL.path,
				hierarchyLevel: 1,
				isExpanded: true
			)
			rootFolder.addSubfolder(subfolder)

			for fileIndex in 0..<newFilesPerParent {
				let relativePath = "\(folderName)/\(syntheticFileName(parentIndex: parentIndex, fileIndex: fileIndex))"
				let fileURL = rootURL.appendingPathComponent(relativePath)
				if createFilesOnDisk {
					FileManager.default.createFile(atPath: fileURL.path, contents: nil)
				}
				deltas.append(.fileAdded(relativePath))
				fileURLs.append(fileURL)
			}
		}

		return CollapseScenario(rootURL: rootURL, rootFolder: rootFolder, service: service, deltas: deltas, fileURLs: fileURLs)
	}

	private func assertScenarioApplied(
		_ scenario: CollapseScenario,
		vm: RepoFileManagerViewModel,
		sample: RepoFileManagerViewModel.ImmediateReplayPerfSample,
		requireBoundaryFlushShape: Bool = true
	) throws {
		XCTAssertEqual(sample.totalDeltaCount, scenario.deltas.count)
		XCTAssertEqual(sample.replayedChunks.reduce(0) { $0 + $1.fileAddedCount }, scenario.deltas.count)
		XCTAssertEqual(sample.rootPass?.deltaAppliedPublisherInvocationCount, 1)
		XCTAssertEqual(sample.chunkCount, 1)
		if requireBoundaryFlushShape {
			XCTAssertEqual(sample.pendingInsertFlushInvocations.count, 1)
			XCTAssertEqual(sample.pendingInsertFlushInvocations.first?.parentGroupCountBeforeFlush, parentFolderCount)
			XCTAssertEqual(sample.pendingInsertFlushTotalEntryCount, scenario.deltas.count)
		} else {
			XCTAssertGreaterThanOrEqual(sample.pendingInsertFlushTotalEntryCount, scenario.deltas.count)
		}
		if let fileAddMetrics = aggregateFileAddPathMetrics(sample) {
			XCTAssertEqual(fileAddMetrics.newFileCount + fileAddMetrics.existingFileCount, scenario.deltas.count)
			XCTAssertEqual(fileAddMetrics.findExistingStandardizedFastPathCount, scenario.deltas.count)
			XCTAssertEqual(fileAddMetrics.newlyCreatedMarkerEmptySetSkipCount, scenario.deltas.count)
			XCTAssertEqual(fileAddMetrics.newlyCreatedMarkerKeyBuildCount, 0)
			XCTAssertEqual(fileAddMetrics.newlyCreatedMarkerConsumedCount, 0)
			XCTAssertEqual(fileAddMetrics.uniqueParentPathCount, parentFolderCount)
			XCTAssertEqual(fileAddMetrics.createMissingParentFolderCreatedCount, 0)
		}
		let pendingFiles = scenario.fileURLs.filter { vm.findFileByFullPath($0.path) == nil }
		XCTAssertTrue(pendingFiles.isEmpty, "Missing \(pendingFiles.count) replayed files")
	}

	private func aggregateFileAddPathMetrics(
		_ sample: RepoFileManagerViewModel.ImmediateReplayPerfSample
	) -> AggregatedFileAddPathMetrics? {
		var aggregate = AggregatedFileAddPathMetrics()
		var sawMetrics = false
		for chunk in sample.replayedChunks {
			guard let metrics = chunk.fileAddPathMetrics else { continue }
			sawMetrics = true
			aggregate.handleNewFileCallCount += metrics.handleNewFileCallCount
			aggregate.existingFileCount += metrics.existingFileCount
			aggregate.newFileCount += metrics.newFileCount
			aggregate.findExistingFileLookupCount += metrics.findExistingFileLookupCount
			aggregate.findExistingStandardizedFastPathCount += metrics.findExistingStandardizedFastPathCount
			aggregate.newlyCreatedMarkerEmptySetSkipCount += metrics.newlyCreatedMarkerEmptySetSkipCount
			aggregate.newlyCreatedMarkerKeyBuildCount += metrics.newlyCreatedMarkerKeyBuildCount
			aggregate.newlyCreatedMarkerConsumedCount += metrics.newlyCreatedMarkerConsumedCount
			aggregate.parentFolderLookupCallCount += metrics.parentFolderLookupCallCount
			aggregate.parentFolderRootReturnCount += metrics.parentFolderRootReturnCount
			aggregate.parentFolderLookupHitCount += metrics.parentFolderLookupHitCount
			aggregate.parentFolderLookupMissCount += metrics.parentFolderLookupMissCount
			aggregate.insertFileCallCount += metrics.insertFileCallCount
			aggregate.insertFileParentPathDerivationCount += metrics.insertFileParentPathDerivationCount
			aggregate.insertFileParentLookupHitCount += metrics.insertFileParentLookupHitCount
			aggregate.insertFileParentLookupMissCount += metrics.insertFileParentLookupMissCount
			aggregate.createMissingParentFolderCallCount += metrics.createMissingParentFolderCallCount
			aggregate.createMissingParentFolderCreatedCount += metrics.createMissingParentFolderCreatedCount
			aggregate.fileHierarchyInsertFileCount += metrics.fileHierarchyInsertFileCount
			aggregate.uniqueParentPathCount += metrics.uniqueParentPathCount
			aggregate.eligibilityCheckCount += metrics.eligibilityCheckCount
			aggregate.eligibilityEligibleCount += metrics.eligibilityEligibleCount
			aggregate.eligibilityIneligibleCount += metrics.eligibilityIneligibleCount
			aggregate.eligibilityCheckDurationMS += metrics.eligibilityCheckDurationMS
			aggregate.eligibilityCheckMaxDurationMS = max(aggregate.eligibilityCheckMaxDurationMS, metrics.eligibilityCheckMaxDurationMS)
			aggregate.eligibilityBatchRawInputCount += metrics.eligibilityBatchRawInputCount
			aggregate.eligibilityBatchUniquePathCount += metrics.eligibilityBatchUniquePathCount
			aggregate.eligibilityBatchResultCount += metrics.eligibilityBatchResultCount
			aggregate.eligibilityPreparedFastPathAttemptCount += metrics.eligibilityPreparedFastPathAttemptCount
			aggregate.eligibilityPreparedFastPathUsedCount += metrics.eligibilityPreparedFastPathUsedCount
			aggregate.eligibilityPreparedFastPathFallbackCount += metrics.eligibilityPreparedFastPathFallbackCount
			aggregate.eligibilityPreparedFastPathInputCount += metrics.eligibilityPreparedFastPathInputCount
			aggregate.eligibilityPreparedFastPathGroupedEntryCount += metrics.eligibilityPreparedFastPathGroupedEntryCount
			aggregate.eligibilityPreparedFastPathParentReuseHitCount += metrics.eligibilityPreparedFastPathParentReuseHitCount
			aggregate.eligibilityPreparedFastPathParentReuseMissCount += metrics.eligibilityPreparedFastPathParentReuseMissCount
			aggregate.eligibilityBatchParentGroupCount += metrics.eligibilityBatchParentGroupCount
			aggregate.eligibilityBatchMaxParentGroupSize = max(aggregate.eligibilityBatchMaxParentGroupSize, metrics.eligibilityBatchMaxParentGroupSize)
			aggregate.eligibilityStandardizeAndGroupDurationMS += metrics.eligibilityStandardizeAndGroupDurationMS
			aggregate.eligibilityParentProcessingDurationMS += metrics.eligibilityParentProcessingDurationMS
			aggregate.eligibilityDirectoryScanGroupCount += metrics.eligibilityDirectoryScanGroupCount
			aggregate.eligibilityDirectoryScanFailureGroupCount += metrics.eligibilityDirectoryScanFailureGroupCount
			aggregate.eligibilityDirectoryScanDurationMS += metrics.eligibilityDirectoryScanDurationMS
			aggregate.eligibilityDirectoryEntryCount += metrics.eligibilityDirectoryEntryCount
			aggregate.eligibilityEntriesMapBuildDurationMS += metrics.eligibilityEntriesMapBuildDurationMS
			aggregate.eligibilityCanonicalParentResolveDurationMS += metrics.eligibilityCanonicalParentResolveDurationMS
			aggregate.eligibilityPreparedIgnoreRulesGroupCount += metrics.eligibilityPreparedIgnoreRulesGroupCount
			aggregate.eligibilityPreparedIgnoreRulesFailureGroupCount += metrics.eligibilityPreparedIgnoreRulesFailureGroupCount
			aggregate.eligibilityPreparedIgnoreRulesDurationMS += metrics.eligibilityPreparedIgnoreRulesDurationMS
			aggregate.eligibilityPreparedIgnoreRulesCacheHitDirectoryCount += metrics.eligibilityPreparedIgnoreRulesCacheHitDirectoryCount
			aggregate.eligibilityPreparedIgnoreRulesCacheMissDirectoryCount += metrics.eligibilityPreparedIgnoreRulesCacheMissDirectoryCount
			aggregate.eligibilityHierarchicalIgnoreCheckCount += metrics.eligibilityHierarchicalIgnoreCheckCount
			aggregate.eligibilityHierarchicalIgnoreNoOpParentGroupCount += metrics.eligibilityHierarchicalIgnoreNoOpParentGroupCount
			aggregate.eligibilityHierarchicalIgnoreSkippedLeafCheckCount += metrics.eligibilityHierarchicalIgnoreSkippedLeafCheckCount
			aggregate.eligibilityHierarchicalIgnoreDurationMS += metrics.eligibilityHierarchicalIgnoreDurationMS
			aggregate.eligibilityPrefixIgnoreCheckCount += metrics.eligibilityPrefixIgnoreCheckCount
			aggregate.eligibilityPrefixIgnoreNoOpParentGroupCount += metrics.eligibilityPrefixIgnoreNoOpParentGroupCount
			aggregate.eligibilityPrefixIgnoreSkippedLeafCheckCount += metrics.eligibilityPrefixIgnoreSkippedLeafCheckCount
			aggregate.eligibilityPrefixIgnoreDurationMS += metrics.eligibilityPrefixIgnoreDurationMS
			aggregate.eligibilityPrefixDirectLeafFastPathParentGroupCount += metrics.eligibilityPrefixDirectLeafFastPathParentGroupCount
			aggregate.eligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCount += metrics.eligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCount
			aggregate.eligibilityPrefixDirectLeafFastPathLeafCheckCount += metrics.eligibilityPrefixDirectLeafFastPathLeafCheckCount
			aggregate.eligibilityPrefixDirectLeafFastPathIgnoredLeafCount += metrics.eligibilityPrefixDirectLeafFastPathIgnoredLeafCount
			aggregate.eligibilityPrefixDirectLeafFastPathCandidatePatternCountTotal += metrics.eligibilityPrefixDirectLeafFastPathCandidatePatternCountTotal
			aggregate.eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax = max(
				aggregate.eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax,
				metrics.eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax
			)
			aggregate.eligibilityPrefixDirectLeafFastPathDurationMS += metrics.eligibilityPrefixDirectLeafFastPathDurationMS
			aggregate.eligibilityPrefixParentRuleShapeGroupCount += metrics.eligibilityPrefixParentRuleShapeGroupCount
			aggregate.eligibilityPrefixParentRuleDepthTotal += metrics.eligibilityPrefixParentRuleDepthTotal
			aggregate.eligibilityPrefixParentRuleDepthMax = max(
				aggregate.eligibilityPrefixParentRuleDepthMax,
				metrics.eligibilityPrefixParentRuleDepthMax
			)
			aggregate.eligibilityPrefixParentActivePatternCountTotal += metrics.eligibilityPrefixParentActivePatternCountTotal
			aggregate.eligibilityPrefixParentActivePatternCountMax = max(
				aggregate.eligibilityPrefixParentActivePatternCountMax,
				metrics.eligibilityPrefixParentActivePatternCountMax
			)
			aggregate.eligibilityPrefixParentHasNegativePatternGroupCount += metrics.eligibilityPrefixParentHasNegativePatternGroupCount
			aggregate.eligibilitySingleFileFallbackUniquePathCount += metrics.eligibilitySingleFileFallbackUniquePathCount
			aggregate.eligibilitySingleFileFallbackDurationMS += metrics.eligibilitySingleFileFallbackDurationMS
			aggregate.eligibilityFallbackParentSymlinkCount += metrics.eligibilityFallbackParentSymlinkCount
			aggregate.eligibilityFallbackDirectoryScanFailureCount += metrics.eligibilityFallbackDirectoryScanFailureCount
			aggregate.eligibilityFallbackMissingEntryCount += metrics.eligibilityFallbackMissingEntryCount
			aggregate.eligibilityFallbackUnknownEntryMetadataCount += metrics.eligibilityFallbackUnknownEntryMetadataCount
			aggregate.eligibilityFallbackPreparedRulesFailureCount += metrics.eligibilityFallbackPreparedRulesFailureCount
			aggregate.eligibilityFallbackPreparedRuleMissCount += metrics.eligibilityFallbackPreparedRuleMissCount
			aggregate.eligibilityFallbackInvalidLeafNameCount += metrics.eligibilityFallbackInvalidLeafNameCount
			aggregate.eligibilityEligibleUniquePathCount += metrics.eligibilityEligibleUniquePathCount
			aggregate.eligibilityIgnoredUniquePathCount += metrics.eligibilityIgnoredUniquePathCount
			aggregate.eligibilityMissingOrDirectoryUniquePathCount += metrics.eligibilityMissingOrDirectoryUniquePathCount
			aggregate.eligibilitySymbolicLinkUniquePathCount += metrics.eligibilitySymbolicLinkUniquePathCount
			aggregate.eligibilityNonRegularFileUniquePathCount += metrics.eligibilityNonRegularFileUniquePathCount
			aggregate.eligibilitySymlinkComponentUniquePathCount += metrics.eligibilitySymlinkComponentUniquePathCount
			aggregate.eligibilityOutsideCanonicalRootUniquePathCount += metrics.eligibilityOutsideCanonicalRootUniquePathCount
			aggregate.eligibilityInvalidRelativePathUniquePathCount += metrics.eligibilityInvalidRelativePathUniquePathCount
			aggregate.eligibilityOutsideRootUniquePathCount += metrics.eligibilityOutsideRootUniquePathCount
			aggregate.parentContextCallCount += metrics.parentContextCallCount
			aggregate.parentContextCacheHitCount += metrics.parentContextCacheHitCount
			aggregate.parentContextCacheMissCount += metrics.parentContextCacheMissCount
			aggregate.parentContextOrderedReuseHitCount += metrics.parentContextOrderedReuseHitCount
			aggregate.parentContextOrderedReuseMissCount += metrics.parentContextOrderedReuseMissCount
			aggregate.parentContextParentStringBuildCount += metrics.parentContextParentStringBuildCount
			aggregate.parentContextDurationMS += metrics.parentContextDurationMS
			aggregate.replayPathMetadataCount += metrics.replayPathMetadataCount
			aggregate.replayPathMetadataDurationMS += metrics.replayPathMetadataDurationMS
			aggregate.handleNewFileDurationMS += metrics.handleNewFileDurationMS
			aggregate.handleNewFileMaxDurationMS = max(aggregate.handleNewFileMaxDurationMS, metrics.handleNewFileMaxDurationMS)
			aggregate.findExistingFileLookupDurationMS += metrics.findExistingFileLookupDurationMS
			aggregate.fileViewModelConstructionCount += metrics.fileViewModelConstructionCount
			aggregate.fileViewModelConstructionDurationMS += metrics.fileViewModelConstructionDurationMS
			aggregate.selectionCallbackAttachDurationMS += metrics.selectionCallbackAttachDurationMS
			aggregate.fileHierarchyInsertFileDurationMS += metrics.fileHierarchyInsertFileDurationMS
			aggregate.insertFileDurationMS += metrics.insertFileDurationMS
			aggregate.insertFileParentPathDerivationDurationMS += metrics.insertFileParentPathDerivationDurationMS
			aggregate.insertFileParentLookupDurationMS += metrics.insertFileParentLookupDurationMS
			aggregate.createMissingParentFolderDurationMS += metrics.createMissingParentFolderDurationMS
			aggregate.enqueueInsertCount += metrics.enqueueInsertCount
			aggregate.enqueueInsertDurationMS += metrics.enqueueInsertDurationMS
		}
		return sawMetrics ? aggregate : nil
	}

	private func waitForImmediateReplaySample(
		vm: RepoFileManagerViewModel,
		expectedFileAddedCount: Int,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> RepoFileManagerViewModel.ImmediateReplayPerfSample {
		let timeoutMS = benchmarkTimestampMS() + 10_000
		while benchmarkTimestampMS() < timeoutMS {
			if let sample = vm.latestImmediateReplayPerfSampleForTesting(),
				sample.replayedChunks.reduce(0, { $0 + $1.fileAddedCount }) == expectedFileAddedCount {
				return sample
			}
			await Task.yield()
			try await Task.sleep(nanoseconds: 1_000_000)
		}
		XCTFail("Timed out waiting for immediate replay sample", file: file, line: line)
		throw TestFailure.timeoutWaitingForReplaySample
	}

	private func summarize(scenario: String, samples: [BenchmarkSample]) -> BenchmarkSummary {
		precondition(samples.count == measuredCount)
		let sorted = samples.sorted { $0.primaryMS < $1.primaryMS }
		let kept = Array(sorted.dropFirst().dropLast(2))
		let keptPrimary = kept.map(\.primaryMS)
		let trimmedMean = mean(keptPrimary)
		let stdDev = standardDeviation(keptPrimary, mean: trimmedMean)
		let allPrimary = sorted.map(\.primaryMS)

		let flushSorted = samples.sorted { $0.flushPendingInsertsMS < $1.flushPendingInsertsMS }
		let flushKept = Array(flushSorted.dropFirst().dropLast(2))
		let keptFlush = flushKept.map(\.flushPendingInsertsMS)
		let flushTrimmedMean = mean(keptFlush)
		let flushStdDev = standardDeviation(keptFlush, mean: flushTrimmedMean)
		let allFlush = flushSorted.map(\.flushPendingInsertsMS)

		let keptFileAddMetrics = kept.compactMap { aggregateFileAddPathMetrics($0.immediateSample) }
		let hasFileAddMetrics = !keptFileAddMetrics.isEmpty

		return BenchmarkSummary(
			scenario: scenario,
			keptSamples: kept,
			allMeasuredSamples: samples,
			medianMS: median(keptPrimary),
			trimmedMeanMS: trimmedMean,
			p90MS: percentile(sortedValues: allPrimary, percentile: 0.90),
			p95MS: percentile(sortedValues: keptPrimary, percentile: 0.95),
			rawP95MS: percentile(sortedValues: allPrimary, percentile: 0.95),
			minKeptMS: keptPrimary.min() ?? 0,
			maxKeptMS: keptPrimary.max() ?? 0,
			stdDevMS: stdDev,
			coefficientOfVariationPercent: trimmedMean > 0 ? (stdDev / trimmedMean) * 100 : 0,
			headlineP95MS: percentile(sortedValues: keptPrimary, percentile: 0.95),
			headlineTrimmedMeanMS: trimmedMean,
			headlineMedianMS: median(keptPrimary),
			headlineCoefficientOfVariationPercent: trimmedMean > 0 ? (stdDev / trimmedMean) * 100 : 0,
			flushPendingInsertsP95MS: percentile(sortedValues: keptFlush, percentile: 0.95),
			flushPendingInsertsTrimmedMeanMS: flushTrimmedMean,
			flushPendingInsertsMedianMS: median(keptFlush),
			flushPendingInsertsRawP95MS: percentile(sortedValues: allFlush, percentile: 0.95),
			flushPendingInsertsMinKeptMS: keptFlush.min() ?? 0,
			flushPendingInsertsMaxKeptMS: keptFlush.max() ?? 0,
			flushPendingInsertsStdDevMS: flushStdDev,
			flushPendingInsertsCoefficientOfVariationPercent: flushTrimmedMean > 0 ? (flushStdDev / flushTrimmedMean) * 100 : 0,
			serviceMeanMS: meanOptional(kept.map(\.serviceWallMS)),
			replayMeanMS: mean(kept.map(\.replayWallMS)),
			deltaLoopMeanMS: mean(kept.map { sample in
				sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.deltaLoopDurationMS }
			}),
			flushPendingInsertsMeanMS: mean(kept.map(\.flushPendingInsertsMS)),
			applyAwaitTrimmedMeanMS: mean(kept.map(\.applyAwaitMS)),
			replayWallTrimmedMeanMS: mean(kept.map(\.replayWallMS)),
			pendingInsertFlushInvocationCountMedian: medianInt(flushKept.map(\.pendingInsertFlushInvocationCount)),
			pendingInsertFlushEntryCountMedian: medianInt(flushKept.map(\.pendingInsertFlushEntryCount)),
			pendingInsertFlushMaxParentGroupCountMedian: medianInt(flushKept.map(\.pendingInsertFlushMaxParentGroupCount)),
			cleanupScanInvocationCountMedian: medianInt(flushKept.map(\.cleanupScanInvocationCount)),
			cleanupScannedCandidateCountMedian: medianInt(flushKept.map(\.cleanupScannedCandidateCount)),
			updateFolderStatesMeanMS: mean(kept.map { sample in
				sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.updateFolderStatesDurationMS }
			}),
			publishedDeltaCountMedian: medianInt(kept.compactMap(\.publishedDeltaCount)),
			rawDeltaCountMedian: kept.contains(where: { $0.rawDeltaCount != nil }) ? medianInt(kept.compactMap(\.rawDeltaCount)) : nil,
			chunkCountMedian: medianInt(kept.map { $0.immediateSample.chunkCount }),
			fileAddedCountMedian: medianInt(kept.map { sample in
				sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.fileAddedCount }
			}),
			fileAddHandleNewFileCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.handleNewFileCallCount)) : nil,
			fileAddNewFileCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.newFileCount)) : nil,
			fileAddExistingFileCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.existingFileCount)) : nil,
			fileAddFindExistingFileLookupCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.findExistingFileLookupCount)) : nil,
			fileAddFindExistingStandardizedFastPathCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.findExistingStandardizedFastPathCount)) : nil,
			fileAddNewlyCreatedMarkerEmptySetSkipCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.newlyCreatedMarkerEmptySetSkipCount)) : nil,
			fileAddNewlyCreatedMarkerKeyBuildCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.newlyCreatedMarkerKeyBuildCount)) : nil,
			fileAddNewlyCreatedMarkerConsumedCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.newlyCreatedMarkerConsumedCount)) : nil,
			fileAddParentLookupCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.parentFolderLookupCallCount)) : nil,
			fileAddParentLookupHitCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.parentFolderLookupHitCount)) : nil,
			fileAddParentLookupMissCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.parentFolderLookupMissCount)) : nil,
			fileAddParentLookupRootReturnCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.parentFolderRootReturnCount)) : nil,
			fileAddUniqueParentPathCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.uniqueParentPathCount)) : nil,
			fileAddInsertFileCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.insertFileCallCount)) : nil,
			fileAddInsertParentDerivationCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.insertFileParentPathDerivationCount)) : nil,
			fileAddInsertParentLookupHitCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.insertFileParentLookupHitCount)) : nil,
			fileAddInsertParentLookupMissCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.insertFileParentLookupMissCount)) : nil,
			fileAddCreateMissingParentFolderCallCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.createMissingParentFolderCallCount)) : nil,
			fileAddCreateMissingParentFolderCreatedCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.createMissingParentFolderCreatedCount)) : nil,
			fileAddFileHierarchyInsertFileCountMedian: hasFileAddMetrics ? medianInt(keptFileAddMetrics.map(\.fileHierarchyInsertFileCount)) : nil
		)
	}

	private func printBenchmarkSummary(_ summary: BenchmarkSummary) {
		let kept = summary.keptSamples
		let keptFileAddMetrics = kept.compactMap { aggregateFileAddPathMetrics($0.immediateSample) }
		let hasFileAddMetrics = !keptFileAddMetrics.isEmpty
		let keptIgnoreMetrics = kept.compactMap(\.ignoreMetrics)
		let hasIgnoreMetrics = !keptIgnoreMetrics.isEmpty
		let keptServiceEventIgnoreDiagnostics = kept.compactMap(\.serviceEventIgnoreDiagnostics)
		let hasServiceEventIgnoreDiagnostics = !keptServiceEventIgnoreDiagnostics.isEmpty
		let keptServiceEventPathMappingDiagnostics = kept.compactMap(\.serviceEventPathMappingDiagnostics)
		let hasServiceEventPathMappingDiagnostics = !keptServiceEventPathMappingDiagnostics.isEmpty

		func p95(_ values: [Double]) -> Double {
			percentile(sortedValues: values.sorted(), percentile: 0.95)
		}

		func metricMean(_ keyPath: KeyPath<AggregatedFileAddPathMetrics, Double>) -> Double {
			mean(keptFileAddMetrics.map { $0[keyPath: keyPath] })
		}

		func metricMedianInt(_ keyPath: KeyPath<AggregatedFileAddPathMetrics, Int>) -> Int {
			medianInt(keptFileAddMetrics.map { $0[keyPath: keyPath] })
		}

		func ignoreMetricMedianInt(_ keyPath: KeyPath<IgnoreDebugMetrics, Int>) -> Int {
			medianInt(keptIgnoreMetrics.map { $0[keyPath: keyPath] })
		}

		func serviceEventIgnoreMedianInt(_ keyPath: KeyPath<EventTargetIgnoreFastPathDiagnostics, Int>) -> Int {
			medianInt(keptServiceEventIgnoreDiagnostics.map { $0[keyPath: keyPath] })
		}

		func serviceEventPathMappingMedianInt(_ keyPath: KeyPath<EventPathMappingFastPathDiagnostics, Int>) -> Int {
			medianInt(keptServiceEventPathMappingDiagnostics.map { $0[keyPath: keyPath] })
		}

		func meanPerCallUS(totalMS: Double, count: Int) -> Double {
			guard count > 0 else { return 0 }
			return (totalMS * 1_000) / Double(count)
		}

		func metricJSON(_ value: Double) -> Any {
			hasFileAddMetrics ? rounded(value) : NSNull()
		}

		func countJSON(_ value: Int) -> Any {
			hasFileAddMetrics ? value : NSNull()
		}

		func ignoreCountJSON(_ value: Int) -> Any {
			hasIgnoreMetrics ? value : NSNull()
		}

		func ignoreMetricJSON(_ value: Double) -> Any {
			hasIgnoreMetrics ? rounded(value) : NSNull()
		}

		func serviceEventIgnoreCountJSON(_ value: Int) -> Any {
			hasServiceEventIgnoreDiagnostics ? value : NSNull()
		}

		func serviceEventPathMappingCountJSON(_ value: Int) -> Any {
			hasServiceEventPathMappingDiagnostics ? value : NSNull()
		}

		let prepareAwaitValues = kept.map { $0.immediateSample.prepareAwaitDurationMS ?? 0 }
		let applyPreparedBatchValues = kept.map { $0.immediateSample.totalDurationMS }
		let directWallUnattributedValues = kept.map { sample in
			max(0, sample.primaryMS - (sample.immediateSample.prepareAwaitDurationMS ?? 0) - sample.immediateSample.totalDurationMS)
		}
		let coalesceDurationValues = kept.map { $0.immediateSample.replayedChunks.first?.coalesceDurationMS ?? 0 }
		let preparationDurationValues = kept.map { $0.immediateSample.replayedChunks.first?.preparationDurationMS ?? 0 }
		let chunkApplyValues = kept.map { sample in
			sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.totalApplyDurationMS }
		}
		let deltaLoopValues = kept.map { sample in
			sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.deltaLoopDurationMS }
		}
		let updateFolderStateValues = kept.map { sample in
			sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.updateFolderStatesDurationMS }
		}
		let finalizeValues = kept.map { $0.immediateSample.rootPass?.finalizeDurationMS ?? 0 }
		let chunkApplyUnattributedValues = kept.map { sample in
			let chunkApply = sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.totalApplyDurationMS }
			let deltaLoop = sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.deltaLoopDurationMS }
			let flush = sample.flushPendingInsertsMS
			let update = sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.updateFolderStatesDurationMS }
			return max(0, chunkApply - deltaLoop - flush - update)
		}
		let replayBatchUnattributedValues = kept.map { sample in
			let chunkApply = sample.immediateSample.replayedChunks.reduce(0) { $0 + $1.totalApplyDurationMS }
			let finalize = sample.immediateSample.rootPass?.finalizeDurationMS ?? 0
			return max(0, sample.immediateSample.totalDurationMS - chunkApply - finalize)
		}

		let eligibilityDurationMS = metricMean(\.eligibilityCheckDurationMS)
		let eligibilityCountMedian = metricMedianInt(\.eligibilityCheckCount)
		let prefixDecisionCountMedian = metricMedianInt(\.eligibilityPrefixIgnoreCheckCount)
			+ metricMedianInt(\.eligibilityPrefixDirectLeafFastPathLeafCheckCount)
		let handleNewFileDurationMS = metricMean(\.handleNewFileDurationMS)
		let handleNewFileCountMedian = metricMedianInt(\.handleNewFileCallCount)
		let fileViewModelConstructionDurationMS = metricMean(\.fileViewModelConstructionDurationMS)
		let fileViewModelConstructionCountMedian = metricMedianInt(\.fileViewModelConstructionCount)
		let parentMetadataLookupDurationMS = metricMean(\.parentContextDurationMS)
			+ metricMean(\.replayPathMetadataDurationMS)
			+ metricMean(\.insertFileParentPathDerivationDurationMS)
			+ metricMean(\.insertFileParentLookupDurationMS)
		let hierarchyInsertEnqueueDurationMS = metricMean(\.fileHierarchyInsertFileDurationMS)
			+ metricMean(\.enqueueInsertDurationMS)
		let handleNewFileUnattributedMS = max(
			0,
			handleNewFileDurationMS
				- metricMean(\.findExistingFileLookupDurationMS)
				- fileViewModelConstructionDurationMS
				- metricMean(\.selectionCallbackAttachDurationMS)
				- metricMean(\.fileHierarchyInsertFileDurationMS)
				- metricMean(\.insertFileDurationMS)
		)
		let deltaLoopUnattributedMS = max(
			0,
			mean(deltaLoopValues)
				- eligibilityDurationMS
				- metricMean(\.parentContextDurationMS)
				- metricMean(\.replayPathMetadataDurationMS)
				- handleNewFileDurationMS
		)
		let eligibilityInternalAccountedMS = metricMean(\.eligibilityStandardizeAndGroupDurationMS)
			+ metricMean(\.eligibilityDirectoryScanDurationMS)
			+ metricMean(\.eligibilityEntriesMapBuildDurationMS)
			+ metricMean(\.eligibilityCanonicalParentResolveDurationMS)
			+ metricMean(\.eligibilityPreparedIgnoreRulesDurationMS)
			+ metricMean(\.eligibilityHierarchicalIgnoreDurationMS)
			+ metricMean(\.eligibilityPrefixIgnoreDurationMS)
			+ metricMean(\.eligibilitySingleFileFallbackDurationMS)
		let eligibilityInternalUnattributedMS = max(0, eligibilityDurationMS - eligibilityInternalAccountedMS)
		let endToEndWallTrimmedMeanMS = mean(kept.map(\.endToEndWallMS))
		let serviceWallTrimmedMeanMS = meanOptional(kept.map(\.serviceWallMS))
		let rawEventBridgeOverheadMS = serviceWallTrimmedMeanMS.map {
			max(0, endToEndWallTrimmedMeanMS - $0 - summary.replayWallTrimmedMeanMS)
		}
		let residentMemoryDeltas = kept.compactMap(\.residentMemoryDeltaMB)
		let mallocMemoryDeltas = kept.compactMap(\.mallocMemoryDeltaMB)
		let residentMemoryDeltaMean = residentMemoryDeltas.isEmpty ? nil : mean(residentMemoryDeltas)
		let mallocMemoryDeltaMean = mallocMemoryDeltas.isEmpty ? nil : mean(mallocMemoryDeltas)
		let residentMemoryDeltaP95 = residentMemoryDeltas.isEmpty ? nil : percentile(sortedValues: residentMemoryDeltas.sorted(), percentile: 0.95)
		let mallocMemoryDeltaP95 = mallocMemoryDeltas.isEmpty ? nil : percentile(sortedValues: mallocMemoryDeltas.sorted(), percentile: 0.95)
		let ignoreOutcomeEvaluationTotal = keptIgnoreMetrics.reduce(0) { $0 + $1.outcomeEvaluationCount }
		let ignorePatternVisitTotal = keptIgnoreMetrics.reduce(0) { $0 + $1.patternVisitCount }
		let ignorePatternAttemptTotal = keptIgnoreMetrics.reduce(0) { $0 + $1.patternMatchAttemptCount }
		let ignorePrefilterCheckTotal = keptIgnoreMetrics.reduce(0) { $0 + $1.patternPrefilterCheckCount }
		let ignorePrefilterSkipTotal = keptIgnoreMetrics.reduce(0) { $0 + $1.patternPrefilterSkipCount }
		let ignoreMeanPatternVisitsPerOutcome = ignoreOutcomeEvaluationTotal > 0
			? Double(ignorePatternVisitTotal) / Double(ignoreOutcomeEvaluationTotal)
			: 0
		let ignoreMeanPatternAttemptsPerOutcome = ignoreOutcomeEvaluationTotal > 0
			? Double(ignorePatternAttemptTotal) / Double(ignoreOutcomeEvaluationTotal)
			: 0
		let ignorePrefilterSkipRatePercent = ignorePrefilterCheckTotal > 0
			? (Double(ignorePrefilterSkipTotal) / Double(ignorePrefilterCheckTotal)) * 100
			: 0

		var payload: [String: Any] = [
			"benchmark": "filesystem_replay_wall_add_burst",
			"benchmarkSchemaVersion": 3,
			"optimizationLoop": "Replay V2 Loop",
			"scenario": summary.scenario,
			"warmupCount": warmupCount,
			"measuredCount": measuredCount,
			"discardRule": "drop_fastest_1_slowest_2",
			"telemetryProfile": benchmarkTelemetryProfile.name,
			"verboseTelemetryIncluded": benchmarkTelemetryProfile.includeVerbosePayload,
			"medianMS": rounded(summary.medianMS),
			"trimmedMeanMS": rounded(summary.trimmedMeanMS),
			"p90MS": rounded(summary.p90MS),
			"p95MS": rounded(summary.p95MS),
			"rawP95MS": rounded(summary.rawP95MS),
			"minKeptMS": rounded(summary.minKeptMS),
			"maxKeptMS": rounded(summary.maxKeptMS),
			"stdDevMS": rounded(summary.stdDevMS),
			"coefficientOfVariationPercent": rounded(summary.coefficientOfVariationPercent),
			"headlineMetric": "replayApplyWallMS",
			"headlineP95MS": rounded(summary.headlineP95MS),
			"headlineTrimmedMeanMS": rounded(summary.headlineTrimmedMeanMS),
			"headlineMedianMS": rounded(summary.headlineMedianMS),
			"headlineCoefficientOfVariationPercent": rounded(summary.headlineCoefficientOfVariationPercent),
			"flushPendingInsertsP95MS": rounded(summary.flushPendingInsertsP95MS),
			"flushPendingInsertsTrimmedMeanMS": rounded(summary.flushPendingInsertsTrimmedMeanMS),
			"flushPendingInsertsMedianMS": rounded(summary.flushPendingInsertsMedianMS),
			"flushPendingInsertsRawP95MS": rounded(summary.flushPendingInsertsRawP95MS),
			"flushPendingInsertsMinKeptMS": rounded(summary.flushPendingInsertsMinKeptMS),
			"flushPendingInsertsMaxKeptMS": rounded(summary.flushPendingInsertsMaxKeptMS),
			"flushPendingInsertsStdDevMS": rounded(summary.flushPendingInsertsStdDevMS),
			"flushPendingInsertsCoefficientOfVariationPercent": rounded(summary.flushPendingInsertsCoefficientOfVariationPercent),
			"serviceMeanMS": summary.serviceMeanMS.map(rounded) ?? NSNull(),
			"replayMeanMS": rounded(summary.replayMeanMS),
			"deltaLoopMeanMS": rounded(summary.deltaLoopMeanMS),
			"flushPendingInsertsMeanMS": rounded(summary.flushPendingInsertsMeanMS),
			"applyAwaitTrimmedMeanMS": rounded(summary.applyAwaitTrimmedMeanMS),
			"replayWallTrimmedMeanMS": rounded(summary.replayWallTrimmedMeanMS),
			"primaryWallTrimmedMeanMS": rounded(summary.trimmedMeanMS),
			"endToEndWallTrimmedMeanMS": rounded(endToEndWallTrimmedMeanMS),
			"serviceWallTrimmedMeanMS": serviceWallTrimmedMeanMS.map(rounded) ?? NSNull(),
			"rawEventBridgeOverheadTrimmedMeanMS": rawEventBridgeOverheadMS.map(rounded) ?? NSNull(),
			"residentMemoryDeltaTrimmedMeanMB": residentMemoryDeltaMean.map(rounded) ?? NSNull(),
			"residentMemoryDeltaP95MB": residentMemoryDeltaP95.map(rounded) ?? NSNull(),
			"mallocMemoryDeltaTrimmedMeanMB": mallocMemoryDeltaMean.map(rounded) ?? NSNull(),
			"mallocMemoryDeltaP95MB": mallocMemoryDeltaP95.map(rounded) ?? NSNull(),
			"memoryTelemetryNote": "best-effort per-iteration apply/replay delta; retained/regression signal only, not an assertion",
			"ignoreOutcomeEvaluationCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeEvaluationCount)),
			"ignorePatternVisitCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.patternVisitCount)),
			"ignorePatternMatchAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.patternMatchAttemptCount)),
			"ignorePatternPrefilterCheckCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.patternPrefilterCheckCount)),
			"ignorePatternPrefilterSkipCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.patternPrefilterSkipCount)),
			"ignorePatternPrefilterPassCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.patternPrefilterPassCount)),
			"ignoreMaxPatternVisitsPerOutcomeMedian": ignoreCountJSON(ignoreMetricMedianInt(\.maxPatternVisitsPerOutcome)),
			"ignoreMaxPatternAttemptsPerOutcomeMedian": ignoreCountJSON(ignoreMetricMedianInt(\.maxPatternAttemptsPerOutcome)),
			"ignoreOutcomeZeroAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeZeroAttemptCount)),
			"ignoreOutcomeOneAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeOneAttemptCount)),
			"ignoreOutcomeTwoToFourAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeTwoToFourAttemptCount)),
			"ignoreOutcomeFiveToEightAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeFiveToEightAttemptCount)),
			"ignoreOutcomeNineToSixteenAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeNineToSixteenAttemptCount)),
			"ignoreOutcomeSeventeenToThirtyTwoAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeSeventeenToThirtyTwoAttemptCount)),
			"ignoreOutcomeThirtyThreeToSixtyFourAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeThirtyThreeToSixtyFourAttemptCount)),
			"ignoreOutcomeSixtyFivePlusAttemptCountMedian": ignoreCountJSON(ignoreMetricMedianInt(\.outcomeSixtyFivePlusAttemptCount)),
			"ignoreMeanPatternVisitsPerOutcome": ignoreMetricJSON(ignoreMeanPatternVisitsPerOutcome),
			"ignoreMeanPatternAttemptsPerOutcome": ignoreMetricJSON(ignoreMeanPatternAttemptsPerOutcome),
			"ignorePrefilterSkipRatePercent": ignoreMetricJSON(ignorePrefilterSkipRatePercent),
			"prepareAwaitTrimmedMeanMS": rounded(mean(prepareAwaitValues)),
			"prepareAwaitP95MS": rounded(p95(prepareAwaitValues)),
			"coalesceDurationTrimmedMeanMS": rounded(mean(coalesceDurationValues)),
			"preparationDurationTrimmedMeanMS": rounded(mean(preparationDurationValues)),
			"applyPreparedBatchTrimmedMeanMS": rounded(mean(applyPreparedBatchValues)),
			"applyPreparedBatchP95MS": rounded(p95(applyPreparedBatchValues)),
			"directWallUnattributedTrimmedMeanMS": rounded(mean(directWallUnattributedValues)),
			"deltaLoopTrimmedMeanMS": rounded(mean(deltaLoopValues)),
			"updateFolderStatesTrimmedMeanMS": rounded(mean(updateFolderStateValues)),
			"finalizeReplayRootPassTrimmedMeanMS": rounded(mean(finalizeValues)),
			"chunkApplyUnattributedTrimmedMeanMS": rounded(mean(chunkApplyUnattributedValues)),
			"replayBatchUnattributedTrimmedMeanMS": rounded(mean(replayBatchUnattributedValues)),
			"pendingInsertFlushInvocationCountMedian": summary.pendingInsertFlushInvocationCountMedian,
			"pendingInsertFlushEntryCountMedian": summary.pendingInsertFlushEntryCountMedian,
			"pendingInsertFlushMaxParentGroupCountMedian": summary.pendingInsertFlushMaxParentGroupCountMedian,
			"cleanupScanInvocationCountMedian": summary.cleanupScanInvocationCountMedian,
			"cleanupScannedCandidateCountMedian": summary.cleanupScannedCandidateCountMedian,
			"updateFolderStatesMeanMS": rounded(summary.updateFolderStatesMeanMS),
			"publishedDeltaCountMedian": summary.publishedDeltaCountMedian,
			"rawDeltaCountMedian": summary.rawDeltaCountMedian ?? NSNull(),
			"serviceEventUnknownRegularFileDecisionCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.unknownRegularFileDecisionCount)),
			"serviceEventParentStateCacheHitCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.parentStateCacheHitCount)),
			"serviceEventParentStateCacheMissCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.parentStateCacheMissCount)),
			"serviceEventExactParentStateCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.exactParentStateCount)),
			"serviceEventUnsupportedParentStateCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.unsupportedParentStateCount)),
			"serviceEventDirectLeafCheckCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.directLeafCheckCount)),
			"serviceEventDirectLeafIgnoredCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.directLeafIgnoredCount)),
			"serviceEventFallbackFullTargetIgnoreCheckCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.fallbackFullTargetIgnoreCheckCount)),
			"serviceEventFallbackFullTargetIgnoredCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.fallbackFullTargetIgnoredCount)),
			"serviceEventExactFullTargetIgnoreCheckCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.exactFullTargetIgnoreCheckCount)),
			"serviceEventSkippedKnownOrControlTargetIgnoreCheckCountMedian": serviceEventIgnoreCountJSON(serviceEventIgnoreMedianInt(\.skippedKnownOrControlTargetIgnoreCheckCount)),
			"serviceEventPathMappingRawPathCountMedian": serviceEventPathMappingCountJSON(serviceEventPathMappingMedianInt(\.rawPathCount)),
			"serviceEventPathMappingFastStandardRootHitCountMedian": serviceEventPathMappingCountJSON(serviceEventPathMappingMedianInt(\.fastStandardRootHitCount)),
			"serviceEventPathMappingFastCanonicalRootHitCountMedian": serviceEventPathMappingCountJSON(serviceEventPathMappingMedianInt(\.fastCanonicalRootHitCount)),
			"serviceEventPathMappingFallbackStandardizationCountMedian": serviceEventPathMappingCountJSON(serviceEventPathMappingMedianInt(\.fallbackStandardizationCount)),
			"serviceEventPathMappingRejectedUnsafePathCountMedian": serviceEventPathMappingCountJSON(serviceEventPathMappingMedianInt(\.rejectedUnsafePathCount)),
			"chunkCountMedian": summary.chunkCountMedian,
			"fileAddedCountMedian": summary.fileAddedCountMedian,
			"fileAddHandleNewFileCountMedian": summary.fileAddHandleNewFileCountMedian ?? NSNull(),
			"fileAddNewFileCountMedian": summary.fileAddNewFileCountMedian ?? NSNull(),
			"fileAddExistingFileCountMedian": summary.fileAddExistingFileCountMedian ?? NSNull(),
			"fileAddFindExistingFileLookupCountMedian": summary.fileAddFindExistingFileLookupCountMedian ?? NSNull(),
			"fileAddFindExistingStandardizedFastPathCountMedian": summary.fileAddFindExistingStandardizedFastPathCountMedian ?? NSNull(),
			"fileAddNewlyCreatedMarkerEmptySetSkipCountMedian": summary.fileAddNewlyCreatedMarkerEmptySetSkipCountMedian ?? NSNull(),
			"fileAddNewlyCreatedMarkerKeyBuildCountMedian": summary.fileAddNewlyCreatedMarkerKeyBuildCountMedian ?? NSNull(),
			"fileAddNewlyCreatedMarkerConsumedCountMedian": summary.fileAddNewlyCreatedMarkerConsumedCountMedian ?? NSNull(),
			"fileAddParentLookupCountMedian": summary.fileAddParentLookupCountMedian ?? NSNull(),
			"fileAddParentLookupHitCountMedian": summary.fileAddParentLookupHitCountMedian ?? NSNull(),
			"fileAddParentLookupMissCountMedian": summary.fileAddParentLookupMissCountMedian ?? NSNull(),
			"fileAddParentLookupRootReturnCountMedian": summary.fileAddParentLookupRootReturnCountMedian ?? NSNull(),
			"fileAddUniqueParentPathCountMedian": summary.fileAddUniqueParentPathCountMedian ?? NSNull(),
			"fileAddInsertFileCountMedian": summary.fileAddInsertFileCountMedian ?? NSNull(),
			"fileAddInsertParentDerivationCountMedian": summary.fileAddInsertParentDerivationCountMedian ?? NSNull(),
			"fileAddInsertParentLookupHitCountMedian": summary.fileAddInsertParentLookupHitCountMedian ?? NSNull(),
			"fileAddInsertParentLookupMissCountMedian": summary.fileAddInsertParentLookupMissCountMedian ?? NSNull(),
			"fileAddCreateMissingParentFolderCallCountMedian": summary.fileAddCreateMissingParentFolderCallCountMedian ?? NSNull(),
			"fileAddCreateMissingParentFolderCreatedCountMedian": summary.fileAddCreateMissingParentFolderCreatedCountMedian ?? NSNull(),
			"fileAddFileHierarchyInsertFileCountMedian": summary.fileAddFileHierarchyInsertFileCountMedian ?? NSNull(),
			"fileAddEligibilityDurationTrimmedMeanMS": metricJSON(eligibilityDurationMS),
			"fileAddEligibilityCountMedian": countJSON(eligibilityCountMedian),
			"fileAddEligibilityEligibleCountMedian": countJSON(metricMedianInt(\.eligibilityEligibleCount)),
			"fileAddEligibilityIneligibleCountMedian": countJSON(metricMedianInt(\.eligibilityIneligibleCount)),
			"fileAddEligibilityMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: eligibilityDurationMS, count: eligibilityCountMedian)),
			"fileAddEligibilityMaxDurationMS": metricJSON(keptFileAddMetrics.map(\.eligibilityCheckMaxDurationMS).max() ?? 0),
			"fileAddEligibilityBatchRawInputCountMedian": countJSON(metricMedianInt(\.eligibilityBatchRawInputCount)),
			"fileAddEligibilityBatchUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityBatchUniquePathCount)),
			"fileAddEligibilityBatchResultCountMedian": countJSON(metricMedianInt(\.eligibilityBatchResultCount)),
			"fileAddEligibilityPreparedFastPathAttemptCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathAttemptCount)),
			"fileAddEligibilityPreparedFastPathUsedCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathUsedCount)),
			"fileAddEligibilityPreparedFastPathFallbackCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathFallbackCount)),
			"fileAddEligibilityPreparedFastPathInputCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathInputCount)),
			"fileAddEligibilityPreparedFastPathGroupedEntryCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathGroupedEntryCount)),
			"fileAddEligibilityPreparedFastPathParentReuseHitCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathParentReuseHitCount)),
			"fileAddEligibilityPreparedFastPathParentReuseMissCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedFastPathParentReuseMissCount)),
			"fileAddEligibilityBatchParentGroupCountMedian": countJSON(metricMedianInt(\.eligibilityBatchParentGroupCount)),
			"fileAddEligibilityBatchMaxParentGroupSizeMedian": countJSON(metricMedianInt(\.eligibilityBatchMaxParentGroupSize)),
			"fileAddEligibilityStandardizeGroupDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityStandardizeAndGroupDurationMS)),
			"fileAddEligibilityParentProcessingDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityParentProcessingDurationMS)),
			"fileAddEligibilityParentScanDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityDirectoryScanDurationMS)),
			"fileAddEligibilityDirectoryScanGroupCountMedian": countJSON(metricMedianInt(\.eligibilityDirectoryScanGroupCount)),
			"fileAddEligibilityDirectoryScanFailureGroupCountMedian": countJSON(metricMedianInt(\.eligibilityDirectoryScanFailureGroupCount)),
			"fileAddEligibilityDirectoryEntryCountMedian": countJSON(metricMedianInt(\.eligibilityDirectoryEntryCount)),
			"fileAddEligibilityEntriesMapDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityEntriesMapBuildDurationMS)),
			"fileAddEligibilityCanonicalParentDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityCanonicalParentResolveDurationMS)),
			"fileAddEligibilityPreparedIgnoreRulesDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityPreparedIgnoreRulesDurationMS)),
			"fileAddEligibilityPreparedIgnoreRulesGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedIgnoreRulesGroupCount)),
			"fileAddEligibilityPreparedIgnoreRulesFailureGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedIgnoreRulesFailureGroupCount)),
			"fileAddEligibilityPreparedIgnoreRulesCacheHitDirectoryCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedIgnoreRulesCacheHitDirectoryCount)),
			"fileAddEligibilityPreparedIgnoreRulesCacheMissDirectoryCountMedian": countJSON(metricMedianInt(\.eligibilityPreparedIgnoreRulesCacheMissDirectoryCount)),
			"fileAddEligibilityHierarchicalIgnoreDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityHierarchicalIgnoreDurationMS)),
			"fileAddEligibilityHierarchicalIgnoreCountMedian": countJSON(metricMedianInt(\.eligibilityHierarchicalIgnoreCheckCount)),
			"fileAddEligibilityHierarchicalIgnoreNoOpParentGroupCountMedian": countJSON(metricMedianInt(\.eligibilityHierarchicalIgnoreNoOpParentGroupCount)),
			"fileAddEligibilityHierarchicalIgnoreSkippedLeafCheckCountMedian": countJSON(metricMedianInt(\.eligibilityHierarchicalIgnoreSkippedLeafCheckCount)),
			"fileAddEligibilityHierarchicalIgnoreMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: metricMean(\.eligibilityHierarchicalIgnoreDurationMS), count: metricMedianInt(\.eligibilityHierarchicalIgnoreCheckCount))),
			"fileAddEligibilityPrefixIgnoreDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityPrefixIgnoreDurationMS)),
			"fileAddEligibilityPrefixIgnoreCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixIgnoreCheckCount)),
			"fileAddEligibilityPrefixIgnoreNoOpParentGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixIgnoreNoOpParentGroupCount)),
			"fileAddEligibilityPrefixIgnoreSkippedLeafCheckCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixIgnoreSkippedLeafCheckCount)),
			"fileAddEligibilityPrefixDirectLeafFastPathParentGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixDirectLeafFastPathParentGroupCount)),
			"fileAddEligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCount)),
			"fileAddEligibilityPrefixDirectLeafFastPathLeafCheckCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixDirectLeafFastPathLeafCheckCount)),
			"fileAddEligibilityPrefixDirectLeafFastPathIgnoredLeafCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixDirectLeafFastPathIgnoredLeafCount)),
			"fileAddEligibilityPrefixDirectLeafFastPathCandidatePatternCountMaxMedian": countJSON(metricMedianInt(\.eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax)),
			"fileAddEligibilityPrefixDirectLeafFastPathDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilityPrefixDirectLeafFastPathDurationMS)),
			"fileAddEligibilityPrefixParentRuleShapeGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixParentRuleShapeGroupCount)),
			"fileAddEligibilityPrefixParentRuleDepthTotalMedian": countJSON(metricMedianInt(\.eligibilityPrefixParentRuleDepthTotal)),
			"fileAddEligibilityPrefixParentRuleDepthMaxMedian": countJSON(metricMedianInt(\.eligibilityPrefixParentRuleDepthMax)),
			"fileAddEligibilityPrefixParentActivePatternCountTotalMedian": countJSON(metricMedianInt(\.eligibilityPrefixParentActivePatternCountTotal)),
			"fileAddEligibilityPrefixParentActivePatternCountMaxMedian": countJSON(metricMedianInt(\.eligibilityPrefixParentActivePatternCountMax)),
			"fileAddEligibilityPrefixParentHasNegativePatternGroupCountMedian": countJSON(metricMedianInt(\.eligibilityPrefixParentHasNegativePatternGroupCount)),
			"fileAddEligibilityPrefixIgnoreMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: metricMean(\.eligibilityPrefixIgnoreDurationMS), count: prefixDecisionCountMedian)),
			"fileAddEligibilityPrefixFullMatcherMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: max(0, metricMean(\.eligibilityPrefixIgnoreDurationMS) - metricMean(\.eligibilityPrefixDirectLeafFastPathDurationMS)), count: metricMedianInt(\.eligibilityPrefixIgnoreCheckCount))),
			"fileAddEligibilitySingleFileFallbackUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilitySingleFileFallbackUniquePathCount)),
			"fileAddEligibilitySingleFileFallbackDurationTrimmedMeanMS": metricJSON(metricMean(\.eligibilitySingleFileFallbackDurationMS)),
			"fileAddEligibilitySingleFileFallbackMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: metricMean(\.eligibilitySingleFileFallbackDurationMS), count: metricMedianInt(\.eligibilitySingleFileFallbackUniquePathCount))),
			"fileAddEligibilityFallbackParentSymlinkCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackParentSymlinkCount)),
			"fileAddEligibilityFallbackDirectoryScanFailureCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackDirectoryScanFailureCount)),
			"fileAddEligibilityFallbackMissingEntryCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackMissingEntryCount)),
			"fileAddEligibilityFallbackUnknownEntryMetadataCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackUnknownEntryMetadataCount)),
			"fileAddEligibilityFallbackPreparedRulesFailureCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackPreparedRulesFailureCount)),
			"fileAddEligibilityFallbackPreparedRuleMissCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackPreparedRuleMissCount)),
			"fileAddEligibilityFallbackInvalidLeafNameCountMedian": countJSON(metricMedianInt(\.eligibilityFallbackInvalidLeafNameCount)),
			"fileAddEligibilityEligibleUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityEligibleUniquePathCount)),
			"fileAddEligibilityIgnoredUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityIgnoredUniquePathCount)),
			"fileAddEligibilityMissingOrDirectoryUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityMissingOrDirectoryUniquePathCount)),
			"fileAddEligibilitySymbolicLinkUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilitySymbolicLinkUniquePathCount)),
			"fileAddEligibilityNonRegularFileUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityNonRegularFileUniquePathCount)),
			"fileAddEligibilitySymlinkComponentUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilitySymlinkComponentUniquePathCount)),
			"fileAddEligibilityOutsideCanonicalRootUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityOutsideCanonicalRootUniquePathCount)),
			"fileAddEligibilityInvalidRelativePathUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityInvalidRelativePathUniquePathCount)),
			"fileAddEligibilityOutsideRootUniquePathCountMedian": countJSON(metricMedianInt(\.eligibilityOutsideRootUniquePathCount)),
			"fileAddEligibilityInternalAccountedDurationTrimmedMeanMS": metricJSON(eligibilityInternalAccountedMS),
			"fileAddEligibilityInternalUnattributedDurationTrimmedMeanMS": metricJSON(eligibilityInternalUnattributedMS),
			"fileAddParentContextDurationTrimmedMeanMS": metricJSON(metricMean(\.parentContextDurationMS)),
			"fileAddParentContextCallCountMedian": countJSON(metricMedianInt(\.parentContextCallCount)),
			"fileAddParentContextCacheHitCountMedian": countJSON(metricMedianInt(\.parentContextCacheHitCount)),
			"fileAddParentContextCacheMissCountMedian": countJSON(metricMedianInt(\.parentContextCacheMissCount)),
			"fileAddParentContextOrderedReuseHitCountMedian": countJSON(metricMedianInt(\.parentContextOrderedReuseHitCount)),
			"fileAddParentContextOrderedReuseMissCountMedian": countJSON(metricMedianInt(\.parentContextOrderedReuseMissCount)),
			"fileAddParentContextParentStringBuildCountMedian": countJSON(metricMedianInt(\.parentContextParentStringBuildCount)),
			"fileAddReplayPathMetadataDurationTrimmedMeanMS": metricJSON(metricMean(\.replayPathMetadataDurationMS)),
			"fileAddReplayPathMetadataCountMedian": countJSON(metricMedianInt(\.replayPathMetadataCount)),
			"fileAddHandleNewFileDurationTrimmedMeanMS": metricJSON(handleNewFileDurationMS),
			"fileAddHandleNewFileMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: handleNewFileDurationMS, count: handleNewFileCountMedian)),
			"fileAddHandleNewFileMaxDurationMS": metricJSON(keptFileAddMetrics.map(\.handleNewFileMaxDurationMS).max() ?? 0),
			"fileAddFindExistingLookupDurationTrimmedMeanMS": metricJSON(metricMean(\.findExistingFileLookupDurationMS)),
			"fileAddFileViewModelConstructionDurationTrimmedMeanMS": metricJSON(fileViewModelConstructionDurationMS),
			"fileAddFileViewModelConstructionCountMedian": countJSON(fileViewModelConstructionCountMedian),
			"fileAddFileViewModelConstructionMeanPerCallUS": metricJSON(meanPerCallUS(totalMS: fileViewModelConstructionDurationMS, count: fileViewModelConstructionCountMedian)),
			"fileAddSelectionCallbackAttachDurationTrimmedMeanMS": metricJSON(metricMean(\.selectionCallbackAttachDurationMS)),
			"fileAddHierarchyInsertDurationTrimmedMeanMS": metricJSON(metricMean(\.fileHierarchyInsertFileDurationMS)),
			"fileAddInsertFileDurationTrimmedMeanMS": metricJSON(metricMean(\.insertFileDurationMS)),
			"fileAddEnqueueDurationTrimmedMeanMS": metricJSON(metricMean(\.enqueueInsertDurationMS)),
			"fileAddEnqueueCountMedian": countJSON(metricMedianInt(\.enqueueInsertCount)),
			"fileAddParentMetadataLookupDurationTrimmedMeanMS": metricJSON(parentMetadataLookupDurationMS),
			"fileAddHierarchyInsertEnqueueDurationTrimmedMeanMS": metricJSON(hierarchyInsertEnqueueDurationMS),
			"fileAddHandleNewFileUnattributedTrimmedMeanMS": metricJSON(handleNewFileUnattributedMS),
			"fileAddDeltaLoopUnattributedTrimmedMeanMS": metricJSON(deltaLoopUnattributedMS),
			"notes": "\(benchmarkTelemetryProfile.name) telemetry profile; headline wall metric kept range \(rounded(summary.minKeptMS))-\(rounded(summary.maxKeptMS)) ms; flush kept range \(rounded(summary.flushPendingInsertsMinKeptMS))-\(rounded(summary.flushPendingInsertsMaxKeptMS)) ms"
		]
		if !hasServiceEventIgnoreDiagnostics {
			for key in serviceEventIgnorePayloadKeys {
				payload.removeValue(forKey: key)
			}
		}
		if !hasServiceEventPathMappingDiagnostics {
			for key in serviceEventPathMappingPayloadKeys {
				payload.removeValue(forKey: key)
			}
		}
		if !benchmarkTelemetryProfile.includeVerbosePayload {
			for key in verboseBenchmarkPayloadKeys {
				payload.removeValue(forKey: key)
			}
		}
		let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		let line = "COLLAPSE_REPLAY_BENCHMARK_RESULT \(String(data: data, encoding: .utf8)!)"
		print(line)
		appendBenchmarkResultLineForLocalCollection(line)
	}

	private func appendBenchmarkResultLineForLocalCollection(_ line: String) {
		let outputURL = URL(fileURLWithPath: "/tmp/repoprompt-replay-v2-benchmark-results.jsonl")
		let payload = Data((line + "\n").utf8)
		if FileManager.default.fileExists(atPath: outputURL.path),
			let handle = try? FileHandle(forWritingTo: outputURL) {
			defer { try? handle.close() }
			do {
				try handle.seekToEnd()
				try handle.write(contentsOf: payload)
			} catch {
				// Best-effort local collection; XCTest assertions remain the source of correctness.
			}
		} else {
			try? payload.write(to: outputURL)
		}
	}

	private func syntheticFolderName(index: Int) -> String {
		"Folder\(index)-\(String(repeating: "f", count: namePayloadLength))"
	}

	private func syntheticFileName(parentIndex: Int, fileIndex: Int) -> String {
		"File\(parentIndex)-\(fileIndex)-\(String(repeating: "x", count: namePayloadLength)).swift"
	}

	private func benchmarkTimestampMS() -> Double {
		CFAbsoluteTimeGetCurrent() * 1_000
	}

	private func benchmarkElapsedMS(since startMS: Double) -> Double {
		benchmarkTimestampMS() - startMS
	}

	private func mean(_ values: [Double]) -> Double {
		guard !values.isEmpty else { return 0 }
		return values.reduce(0, +) / Double(values.count)
	}

	private func meanOptional(_ values: [Double?]) -> Double? {
		let compact = values.compactMap { $0 }
		guard !compact.isEmpty else { return nil }
		return mean(compact)
	}

	private func median(_ values: [Double]) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return 0 }
		let middle = sorted.count / 2
		if sorted.count.isMultiple(of: 2) {
			return (sorted[middle - 1] + sorted[middle]) / 2
		}
		return sorted[middle]
	}

	private func medianInt(_ values: [Int]) -> Int {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return 0 }
		return sorted[sorted.count / 2]
	}

	private func percentile(sortedValues: [Double], percentile: Double) -> Double {
		guard !sortedValues.isEmpty else { return 0 }
		let index = min(sortedValues.count - 1, max(0, Int(ceil(percentile * Double(sortedValues.count))) - 1))
		return sortedValues[index]
	}

	private func standardDeviation(_ values: [Double], mean: Double) -> Double {
		guard values.count > 1 else { return 0 }
		let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
		return sqrt(variance)
	}

	private func rounded(_ value: Double) -> Double {
		(value * 1000).rounded() / 1000
	}

	private enum TestFailure: Error {
		case timeoutWaitingForReplaySample
	}
}
#endif
