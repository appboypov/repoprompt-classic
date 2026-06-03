//
//  FolderReplayOptimizationLoopTests.swift
//  RepoPromptTests
//

#if DEBUG
import Combine
import XCTest
@testable import RepoPrompt

@MainActor
final class FolderReplayOptimizationLoopTests: XCTestCase {
	private let folderCount = 400
	private let warmupCount = 3
	private let measuredCount = 15
	private let namePayloadLength = 64
	private let initialBaseTime: TimeInterval = 2_000_000
	private let legacyBaseTime: TimeInterval = 3_000_000
	private let unchangedScenarioVarianceLimitPercent = 15.0
	private let legacyScenarioVarianceLimitPercent = 20.0

	private enum ScenarioKind: String, CaseIterable {
		case legacySyntheticDates = "legacy_synthetic_dates"
		case stableUnchangedMTime = "stable_unchanged_mtime"
		case stableSameOrderChangedMTime = "stable_same_order_changed_mtime"
	}

	private struct BenchmarkSample {
		let primaryMS: Double
		let replayWallMS: Double
		let folderModifiedCount: Int
		let carriedDateCount: Int
		let fallbackStatSuccessCount: Int
		let skippedNoDateCount: Int
		let dateSortRepositionCount: Int
		let dateSortAlreadySortedCount: Int
		let parentObjectWillChangeCount: Int
		let rootPassPublisherCount: Int
		let statPathCount: Int?
	}

	private struct BenchmarkSummary {
		let scenario: String
		let keptSamples: [BenchmarkSample]
		let allMeasuredSamples: [BenchmarkSample]
		let medianMS: Double
		let trimmedMeanMS: Double
		let p90MS: Double
		let minKeptMS: Double
		let maxKeptMS: Double
		let stdDevMS: Double
		let coefficientOfVariationPercent: Double
		let replayMeanMS: Double
		let folderModifiedCountMedian: Int
		let carriedDateCountMedian: Int
		let fallbackStatSuccessCountMedian: Int
		let skippedNoDateCountMedian: Int
		let dateSortRepositionCountMedian: Int
		let dateSortAlreadySortedCountMedian: Int
		let parentObjectWillChangeCountMedian: Int
		let rootPassPublisherCountMedian: Int
		let statPathCountMedian: Int?
		let verdict: String
	}

	private struct FolderReplayScenario {
		let rootURL: URL
		let rootFolder: FolderViewModel
		let service: FileSystemService
		let folderNames: [String]
		let initialDates: [Date]
		let deltas: [FileSystemDelta]
		let expectedDatesByName: [String: Date]
	}

	private final class CounterBox {
		var value = 0
	}

	private final class DateSortMutationRecorder {
		let parentID: UUID
		var repositionCount = 0
		var alreadySortedCount = 0
		var resortedDirtyStorageCount = 0

		init(parentID: UUID) {
			self.parentID = parentID
		}

		func record(_ event: FolderViewModel.FolderDateSortMutationEvent) {
			guard event.parentID == parentID, event.childKind == .folder else { return }
			switch event.outcome {
			case .alreadySorted:
				alreadySortedCount += 1
			case .repositioned:
				repositionCount += 1
			case .resortedDirtyStorage:
				resortedDirtyStorageCount += 1
			}
		}
	}

	func testFolderModificationReplayLoopBenchmark() async throws {
		for kind in ScenarioKind.allCases {
			let summary = try await runBenchmark(scenario: kind.rawValue) { iteration in
				let scenario = try await makeScenario(kind: kind, iteration: iteration)
				defer { try? FileManager.default.removeItem(at: scenario.rootURL) }
				return try await measureScenario(scenario)
			}
			printBenchmarkSummary(summary)
		}
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

	private func makeScenario(kind: ScenarioKind, iteration: Int) async throws -> FolderReplayScenario {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FolderReplayBenchmark-\(UUID().uuidString)-\(iteration)", isDirectory: true)
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
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date(timeIntervalSince1970: initialBaseTime)),
			rootPath: rootURL.path,
			isExpanded: true,
			sortMethod: .dateNewest
		)

		var folderNames: [String] = []
		var initialDates: [Date] = []
		folderNames.reserveCapacity(folderCount)
		initialDates.reserveCapacity(folderCount)

		for index in 0..<folderCount {
			let folderName = syntheticFolderName(index: index)
			let initialDate = Date(timeIntervalSince1970: initialBaseTime - Double(index * 10))
			let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)
			let subfolder = FolderViewModel(
				folder: Folder(name: folderName, path: folderURL.path, modificationDate: initialDate),
				rootPath: rootURL.path,
				hierarchyLevel: 1,
				isExpanded: true,
				sortMethod: .dateNewest
			)
			rootFolder.addSubfolder(subfolder)
			folderNames.append(folderName)
			initialDates.append(initialDate)
		}

		let targetDates = targetDatesForScenario(kind: kind, initialDates: initialDates)
		let deltas = zip(folderNames, targetDates).map { folderName, targetDate in
			FileSystemDelta.folderModified(folderName, targetDate)
		}
		let expectedDatesByName = Dictionary(uniqueKeysWithValues: zip(folderNames, targetDates))

		return FolderReplayScenario(
			rootURL: rootURL,
			rootFolder: rootFolder,
			service: service,
			folderNames: folderNames,
			initialDates: initialDates,
			deltas: deltas,
			expectedDatesByName: expectedDatesByName
		)
	}

	private func measureScenario(_ scenario: FolderReplayScenario) async throws -> BenchmarkSample {
		let vm = RepoFileManagerViewModel()
		vm.registerRootFolderForTesting(scenario.rootFolder, service: scenario.service)
		vm.setWindowFocused(true)
		vm.setDeltaReplayTuningForTesting(chunkSize: nil, interChunkDelayNanoseconds: nil)
		vm.resetReplayPerfSamplesForTesting()

		let objectWillChangeCounter = CounterBox()
		let rootObjectWillChange = scenario.rootFolder.objectWillChange.sink { _ in
			objectWillChangeCounter.value += 1
		}
		let mutationRecorder = DateSortMutationRecorder(parentID: scenario.rootFolder.id)
		FolderViewModel.dateSortMutationObserverForTesting = { event in
			mutationRecorder.record(event)
		}
		defer {
			rootObjectWillChange.cancel()
			FolderViewModel.dateSortMutationObserverForTesting = nil
		}

		let startMS = benchmarkTimestampMS()
		await vm.receiveLiveFileSystemDeltasForTesting(scenario.deltas, forRootFolder: scenario.rootFolder)
		let replayWallMS = benchmarkElapsedMS(since: startMS)
		let immediateSample = try XCTUnwrap(vm.latestImmediateReplayPerfSampleForTesting())
		try assertScenarioApplied(scenario)

		let chunks = immediateSample.replayedChunks
		return BenchmarkSample(
			primaryMS: replayWallMS,
			replayWallMS: immediateSample.totalDurationMS,
			folderModifiedCount: chunks.reduce(0) { $0 + $1.folderModifiedCount },
			carriedDateCount: chunks.reduce(0) { $0 + $1.folderModifiedCarriedDateCount },
			fallbackStatSuccessCount: chunks.reduce(0) { $0 + $1.folderModifiedFallbackStatSuccessCount },
			skippedNoDateCount: chunks.reduce(0) { $0 + $1.folderModifiedSkippedNoDateCount },
			dateSortRepositionCount: mutationRecorder.repositionCount,
			dateSortAlreadySortedCount: mutationRecorder.alreadySortedCount,
			parentObjectWillChangeCount: objectWillChangeCounter.value,
			rootPassPublisherCount: immediateSample.rootPass?.deltaAppliedPublisherInvocationCount ?? 0,
			statPathCount: nil
		)
	}

	private func assertScenarioApplied(_ scenario: FolderReplayScenario) throws {
		for folder in scenario.rootFolder.subfolders {
			let expectedDate = try XCTUnwrap(scenario.expectedDatesByName[folder.name])
			XCTAssertEqual(folder.modificationDate, expectedDate)
		}
	}

	private func targetDatesForScenario(kind: ScenarioKind, initialDates: [Date]) -> [Date] {
		switch kind {
		case .legacySyntheticDates:
			return initialDates.indices.map { index in
				Date(timeIntervalSince1970: legacyBaseTime + Double(index))
			}
		case .stableUnchangedMTime:
			return initialDates
		case .stableSameOrderChangedMTime:
			return initialDates.map { $0.addingTimeInterval(1) }
		}
	}

	private func summarize(scenario: String, samples: [BenchmarkSample]) -> BenchmarkSummary {
		precondition(samples.count == measuredCount)
		let sorted = samples.sorted { $0.primaryMS < $1.primaryMS }
		let kept = Array(sorted.dropFirst().dropLast(2))
		let keptPrimary = kept.map(\.primaryMS)
		let trimmedMean = mean(keptPrimary)
		let stdDev = standardDeviation(keptPrimary, mean: trimmedMean)
		let allPrimary = sorted.map(\.primaryMS)
		let folderModifiedCountMedian = medianInt(kept.map(\.folderModifiedCount))
		let carriedDateCountMedian = medianInt(kept.map(\.carriedDateCount))
		let fallbackStatSuccessCountMedian = medianInt(kept.map(\.fallbackStatSuccessCount))
		let skippedNoDateCountMedian = medianInt(kept.map(\.skippedNoDateCount))
		let dateSortRepositionCountMedian = medianInt(kept.map(\.dateSortRepositionCount))
		let dateSortAlreadySortedCountMedian = medianInt(kept.map(\.dateSortAlreadySortedCount))
		let parentObjectWillChangeCountMedian = medianInt(kept.map(\.parentObjectWillChangeCount))
		let rootPassPublisherCountMedian = medianInt(kept.map(\.rootPassPublisherCount))
		let statPathCountMedian = medianOptionalInt(kept.map(\.statPathCount))

		return BenchmarkSummary(
			scenario: scenario,
			keptSamples: kept,
			allMeasuredSamples: samples,
			medianMS: median(keptPrimary),
			trimmedMeanMS: trimmedMean,
			p90MS: percentile(sortedValues: allPrimary, percentile: 0.90),
			minKeptMS: keptPrimary.min() ?? 0,
			maxKeptMS: keptPrimary.max() ?? 0,
			stdDevMS: stdDev,
			coefficientOfVariationPercent: trimmedMean > 0 ? (stdDev / trimmedMean) * 100 : 0,
			replayMeanMS: mean(kept.map(\.replayWallMS)),
			folderModifiedCountMedian: folderModifiedCountMedian,
			carriedDateCountMedian: carriedDateCountMedian,
			fallbackStatSuccessCountMedian: fallbackStatSuccessCountMedian,
			skippedNoDateCountMedian: skippedNoDateCountMedian,
			dateSortRepositionCountMedian: dateSortRepositionCountMedian,
			dateSortAlreadySortedCountMedian: dateSortAlreadySortedCountMedian,
			parentObjectWillChangeCountMedian: parentObjectWillChangeCountMedian,
			rootPassPublisherCountMedian: rootPassPublisherCountMedian,
			statPathCountMedian: statPathCountMedian,
			verdict: verdict(
				scenario: scenario,
				folderModifiedCountMedian: folderModifiedCountMedian,
				carriedDateCountMedian: carriedDateCountMedian,
				dateSortRepositionCountMedian: dateSortRepositionCountMedian,
				dateSortAlreadySortedCountMedian: dateSortAlreadySortedCountMedian,
				parentObjectWillChangeCountMedian: parentObjectWillChangeCountMedian,
				coefficientOfVariationPercent: trimmedMean > 0 ? (stdDev / trimmedMean) * 100 : 0
			)
		)
	}

	private func verdict(
		scenario: String,
		folderModifiedCountMedian: Int,
		carriedDateCountMedian: Int,
		dateSortRepositionCountMedian: Int,
		dateSortAlreadySortedCountMedian: Int,
		parentObjectWillChangeCountMedian: Int,
		coefficientOfVariationPercent: Double
	) -> String {
		let varianceLimit = scenario == ScenarioKind.legacySyntheticDates.rawValue
			? legacyScenarioVarianceLimitPercent
			: unchangedScenarioVarianceLimitPercent
		let varianceNote = coefficientOfVariationPercent <= varianceLimit ? "variance-ok" : "variance-high"
		switch scenario {
		case ScenarioKind.stableUnchangedMTime.rawValue:
			let deterministicOK = folderModifiedCountMedian > 0
				&& carriedDateCountMedian == folderModifiedCountMedian
				&& dateSortRepositionCountMedian == 0
				&& parentObjectWillChangeCountMedian == 0
			return deterministicOK ? "pass-net-positive-proof/\(varianceNote)" : "regression-record-only/\(varianceNote)"
		case ScenarioKind.stableSameOrderChangedMTime.rawValue:
			let deterministicOK = dateSortAlreadySortedCountMedian > 0
				&& dateSortRepositionCountMedian == 0
				&& parentObjectWillChangeCountMedian == 0
			return deterministicOK ? "pass-no-op-guard-proof/\(varianceNote)" : "regression-record-only/\(varianceNote)"
		case ScenarioKind.legacySyntheticDates.rawValue:
			let deterministicOK = dateSortRepositionCountMedian > 0
				&& parentObjectWillChangeCountMedian > 0
			return deterministicOK ? "pass-legacy-churn-baseline/\(varianceNote)" : "unexpected-legacy-baseline/\(varianceNote)"
		default:
			return "unknown-scenario/\(varianceNote)"
		}
	}

	private func printBenchmarkSummary(_ summary: BenchmarkSummary) {
		let payload: [String: Any] = [
			"scenario": summary.scenario,
			"warmupCount": warmupCount,
			"measuredCount": measuredCount,
			"discardRule": "drop_fastest_1_slowest_2",
			"medianMS": rounded(summary.medianMS),
			"trimmedMeanMS": rounded(summary.trimmedMeanMS),
			"p90MS": rounded(summary.p90MS),
			"minKeptMS": rounded(summary.minKeptMS),
			"maxKeptMS": rounded(summary.maxKeptMS),
			"stdDevMS": rounded(summary.stdDevMS),
			"coefficientOfVariationPercent": rounded(summary.coefficientOfVariationPercent),
			"replayMeanMS": rounded(summary.replayMeanMS),
			"folderModifiedCountMedian": summary.folderModifiedCountMedian,
			"carriedDateCountMedian": summary.carriedDateCountMedian,
			"fallbackStatSuccessCountMedian": summary.fallbackStatSuccessCountMedian,
			"skippedNoDateCountMedian": summary.skippedNoDateCountMedian,
			"dateSortRepositionCountMedian": summary.dateSortRepositionCountMedian,
			"dateSortAlreadySortedCountMedian": summary.dateSortAlreadySortedCountMedian,
			"parentObjectWillChangeCountMedian": summary.parentObjectWillChangeCountMedian,
			"rootPassPublisherCountMedian": summary.rootPassPublisherCountMedian,
			"statPathCountMedian": summary.statPathCountMedian ?? NSNull(),
			"verdict": summary.verdict,
			"notes": "primary metric kept range \(rounded(summary.minKeptMS))-\(rounded(summary.maxKeptMS)) ms"
		]
		let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		let line = "FOLDER_REPLAY_BENCHMARK_RESULT \(String(data: data, encoding: .utf8)!)"
		print(line)
		appendBenchmarkResultLineForLocalCollection(line)
	}

	private func appendBenchmarkResultLineForLocalCollection(_ line: String) {
		let outputURL = URL(fileURLWithPath: "/tmp/repoprompt-folder-replay-loop-results.jsonl")
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
		"Folder\(String(format: "%04d", index))-\(String(repeating: "f", count: namePayloadLength))"
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

	private func medianOptionalInt(_ values: [Int?]) -> Int? {
		let compact = values.compactMap { $0 }
		guard !compact.isEmpty else { return nil }
		return medianInt(compact)
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
}
#endif
