#if DEBUG

import XCTest
@testable import RepoPrompt
import Foundation
import MCP

@MainActor
final class SixAgentFileSearchOptimizationLoopTests: XCTestCase {
	func testSixParallelScopedPathFileSearchBenchmark() async throws {
		let fixture = try await makeFixture()
		defer { try? FileManager.default.removeItem(at: fixture.tempParentURL) }
		addTeardownBlock {
			await fixture.windowState.tearDown()
			MCPFileSearchPerfDiagnostics.setProcessOverrideEnabled(nil)
			MCPFileSearchPerfDiagnostics.clear()
		}

		MCPFileSearchPerfDiagnostics.setProcessOverrideEnabled(true)
		MCPFileSearchPerfDiagnostics.clear()

		let serialReplies = try await runSerialRequests(fixture.requests, mcpServer: fixture.windowState.mcpServer, labelPrefix: "serial")
		let expectedSignatures = serialReplies.map(SearchSignature.init)
		XCTAssertEqual(expectedSignatures.count, 6)
		XCTAssertTrue(expectedSignatures.allSatisfy { $0.totalMatches > 0 }, "Fixture should produce path matches for every scoped request")

		let warmupCount = 3
		let measuredCount = 15
		for iteration in 0..<warmupCount {
			_ = try await measureSample(
				kind: "warmup",
				iteration: iteration,
				fixture: fixture,
				expectedSignatures: expectedSignatures
			)
		}

		var measuredSamples: [BenchmarkSample] = []
		measuredSamples.reserveCapacity(measuredCount)
		for iteration in 0..<measuredCount {
			let sample = try await measureSample(
				kind: "measured",
				iteration: iteration,
				fixture: fixture,
				expectedSignatures: expectedSignatures
			)
			measuredSamples.append(sample)
		}

		let report = BenchmarkReport(
			fixture: fixture.description,
			warmups: warmupCount,
			measured: measuredCount,
			trim: "drop fastest 1 + slowest 2 by group wall-clock",
			samples: measuredSamples
		)
		let payload = try Self.reportPayload(report)
		print("SIX_AGENT_FILE_SEARCH_BENCHMARK_JSON=\(payload)")
		let attachment = XCTAttachment(string: payload)
		attachment.name = "six-agent-file-search-benchmark.json"
		attachment.lifetime = XCTAttachment.Lifetime.keepAlways
		add(attachment)
		try? (payload + "\n").appendLine(to: URL(fileURLWithPath: "/tmp/repoprompt-six-agent-file-search-benchmark-results.jsonl"))
	}

	private func measureSample(
		kind: String,
		iteration: Int,
		fixture: BenchmarkFixture,
		expectedSignatures: [SearchSignature]
	) async throws -> BenchmarkSample {
		MCPFileSearchPerfDiagnostics.clear()
		let startMS = MCPFileSearchPerfDiagnostics.timestampMS()
		let replies = try await runConcurrentRequests(
			fixture.requests,
			mcpServer: fixture.windowState.mcpServer,
			labelPrefix: "\(kind)-\(iteration)"
		)
		let groupWallClockMS = MCPFileSearchPerfDiagnostics.elapsedMS(since: startMS)
		let signatures = replies.map(SearchSignature.init)
		let mismatchCount = zip(signatures, expectedSignatures).filter { $0 != $1 }.count
		let metrics = MCPFileSearchPerfDiagnostics.recentRunMetrics()
		let cancellationCount = metrics.filter(\.scopeFilterCancelled).count
		return BenchmarkSample(
			kind: kind,
			iteration: iteration,
			groupWallClockMS: groupWallClockMS,
			mismatchCount: mismatchCount,
			cancellationCount: cancellationCount,
			metrics: metrics
		)
	}

	private func runSerialRequests(
		_ requests: [SearchRequest],
		mcpServer: MCPServerViewModel,
		labelPrefix: String
	) async throws -> [ToolResultDTOs.SearchResultDTO] {
		var replies: [ToolResultDTOs.SearchResultDTO] = []
		replies.reserveCapacity(requests.count)
		for (index, request) in requests.enumerated() {
			let reply = try await mcpServer.executeFileSearchTool(
				args: request.args,
				diagnosticLabel: "\(labelPrefix)-agent-\(index)"
			)
			replies.append(reply)
		}
		return replies
	}

	private func runConcurrentRequests(
		_ requests: [SearchRequest],
		mcpServer: MCPServerViewModel,
		labelPrefix: String
	) async throws -> [ToolResultDTOs.SearchResultDTO] {
		precondition(requests.count == 6, "Six-agent benchmark requires exactly six requests")
		async let r0 = mcpServer.executeFileSearchTool(args: requests[0].args, diagnosticLabel: "\(labelPrefix)-agent-0")
		async let r1 = mcpServer.executeFileSearchTool(args: requests[1].args, diagnosticLabel: "\(labelPrefix)-agent-1")
		async let r2 = mcpServer.executeFileSearchTool(args: requests[2].args, diagnosticLabel: "\(labelPrefix)-agent-2")
		async let r3 = mcpServer.executeFileSearchTool(args: requests[3].args, diagnosticLabel: "\(labelPrefix)-agent-3")
		async let r4 = mcpServer.executeFileSearchTool(args: requests[4].args, diagnosticLabel: "\(labelPrefix)-agent-4")
		async let r5 = mcpServer.executeFileSearchTool(args: requests[5].args, diagnosticLabel: "\(labelPrefix)-agent-5")
		return try await [r0, r1, r2, r3, r4, r5]
	}

	private func makeFixture() async throws -> BenchmarkFixture {
		let rootCount = 3
		let agentScopeCount = 6
		let filesPerScope = Self.intEnvironment("SIX_AGENT_FILE_SEARCH_FILES_PER_SCOPE", defaultValue: 1_000)
		let tempParentURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-SixAgentFileSearch-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: tempParentURL, withIntermediateDirectories: true)
		let rootURLs = try (0..<rootCount).map { rootIndex in
			let rootURL = tempParentURL.appendingPathComponent("SixAgentRoot\(rootIndex)", isDirectory: true)
			try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
			return rootURL
		}

		let windowState = WindowState()
		await windowState.workspaceManager.awaitInitialized()
		let tabID = UUID()
		let workspace = WorkspaceModel(
			name: "Six Agent File Search Benchmark",
			repoPaths: rootURLs.map(\.path),
			customStoragePath: tempParentURL,
			composeTabs: [
				ComposeTabState(id: tabID, name: "Benchmark", lastModified: Date())
			],
			activeComposeTabID: tabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)

		for rootURL in rootURLs {
			let service = try await FileSystemService(
				path: rootURL.path,
				respectGitignore: false,
				skipSymlinks: true,
				isTestMode: true
			)
			let rootFolder = FolderViewModel(
				folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
				rootPath: rootURL.path,
				isExpanded: true
			)
			for scopeIndex in 0..<agentScopeCount {
				let folderURL = rootURL.appendingPathComponent("AgentScope\(scopeIndex)", isDirectory: true)
				let subfolder = FolderViewModel(
					folder: Folder(name: folderURL.lastPathComponent, path: folderURL.path, modificationDate: Date()),
					rootPath: rootURL.path,
					hierarchyLevel: 1,
					isExpanded: true
				)
				for fileIndex in 0..<filesPerScope {
					let fileURL = folderURL.appendingPathComponent(String(format: "File-%04d.swift", fileIndex))
					let file = FileViewModel(
						file: File(name: fileURL.lastPathComponent, path: fileURL.path, modificationDate: Date()),
						rootPath: rootURL.path,
						hierarchyLevel: 2,
						rootIdentifier: rootFolder.id,
						rootFolderPath: rootURL.path,
						fileSystemService: service,
						parentFolder: subfolder
					)
					subfolder.addFile(file)
				}
				rootFolder.addSubfolder(subfolder)
			}
			windowState.fileManager.registerRootFolderForTesting(rootFolder, service: service)
		}
		guard !windowState.fileManager.rootFolders.isEmpty else {
			throw XCTSkip("Synthetic benchmark fixture failed to register root folders")
		}

		let requests = (0..<agentScopeCount).map { agentIndex in
			SearchRequest(scopePath: "SixAgentRoot\(agentIndex % rootCount)/AgentScope\(agentIndex)/")
		}
		return BenchmarkFixture(
			windowState: windowState,
			tempParentURL: tempParentURL,
			requests: requests,
			description: "3 roots / \(rootCount * agentScopeCount * filesPerScope) files / 6 requests / max_results 500"
		)
	}

	private static func reportPayload(_ report: BenchmarkReport) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(report.summary())
		return String(decoding: data, as: UTF8.self)
	}

	private static func intEnvironment(_ name: String, defaultValue: Int) -> Int {
		guard let raw = ProcessInfo.processInfo.environment[name], let value = Int(raw), value > 0 else {
			return defaultValue
		}
		return value
	}
}

private struct BenchmarkFixture {
	let windowState: WindowState
	let tempParentURL: URL
	let requests: [SearchRequest]
	let description: String
}

private struct SearchRequest {
	let scopePath: String

	var args: [String: Value] {
		[
			"pattern": .string("*.swift"),
			"mode": .string("path"),
			"regex": .bool(false),
			"max_results": .int(500),
			"filter": .object([
				"paths": .array([.string(scopePath)])
			])
		]
	}
}

private struct SearchSignature: Equatable, Codable {
	let totalMatches: Int
	let pathMatches: Int
	let contentMatches: Int
	let matchedFiles: Int?
	let searchedFiles: Int?
	let limitHit: Bool

	init(_ dto: ToolResultDTOs.SearchResultDTO) {
		totalMatches = dto.totalMatches
		pathMatches = dto.pathMatches
		contentMatches = dto.contentMatches
		matchedFiles = dto.matchedFiles
		searchedFiles = dto.searchedFiles
		limitHit = dto.limitHit
	}
}

private struct BenchmarkSample: Codable {
	let kind: String
	let iteration: Int
	let groupWallClockMS: Double
	let mismatchCount: Int
	let cancellationCount: Int
	let metrics: [MCPFileSearchPerfDiagnostics.RunMetric]
}

private struct BenchmarkReport {
	let fixture: String
	let warmups: Int
	let measured: Int
	let trim: String
	let samples: [BenchmarkSample]

	func summary() -> BenchmarkSummary {
		let kept = keptSamples()
		let keptMetrics = kept.flatMap(\.metrics)
		return BenchmarkSummary(
			fixture: fixture,
			warmups: warmups,
			measured: measured,
			trim: trim,
			keptSamples: kept.count,
			groupMedianMS: Stats.median(kept.map(\.groupWallClockMS)),
			groupP90MS: Stats.percentile(kept.map(\.groupWallClockMS), 0.90),
			groupP95MS: Stats.percentile(kept.map(\.groupWallClockMS), 0.95),
			groupTrimmedMeanMS: Stats.mean(kept.map(\.groupWallClockMS)),
			groupStdDevMS: Stats.stddev(kept.map(\.groupWallClockMS)),
			keptCVPercent: Stats.cvPercent(kept.map(\.groupWallClockMS)),
			envelopeP50MS: Stats.median(keptMetrics.compactMap(\.totalMS)),
			envelopeP95MS: Stats.percentile(keptMetrics.compactMap(\.totalMS), 0.95),
			scopeFilterP50MS: Stats.median(keptMetrics.compactMap(\.scopeFilteringMS)),
			scopeFilterP95MS: Stats.percentile(keptMetrics.compactMap(\.scopeFilteringMS), 0.95),
			actorP50MS: Stats.median(keptMetrics.compactMap(\.actorSearchMS)),
			actorP95MS: Stats.percentile(keptMetrics.compactMap(\.actorSearchMS), 0.95),
			formatP50MS: Stats.median(keptMetrics.compactMap(\.responseFormattingMS)),
			formatP95MS: Stats.percentile(keptMetrics.compactMap(\.responseFormattingMS), 0.95),
			responseBytesP95: Stats.percentile(keptMetrics.compactMap { $0.responseJSONBytes.map(Double.init) }, 0.95),
			cancellationCount: kept.map(\.cancellationCount).reduce(0, +),
			mismatchCount: kept.map(\.mismatchCount).reduce(0, +),
			rawSamples: samples
		)
	}

	private func keptSamples() -> [BenchmarkSample] {
		guard samples.count > 3 else { return samples }
		let sorted = samples.sorted { $0.groupWallClockMS < $1.groupWallClockMS }
		return Array(sorted.dropFirst().dropLast(2))
	}
}

private struct BenchmarkSummary: Codable {
	let fixture: String
	let warmups: Int
	let measured: Int
	let trim: String
	let keptSamples: Int
	let groupMedianMS: Double?
	let groupP90MS: Double?
	let groupP95MS: Double?
	let groupTrimmedMeanMS: Double?
	let groupStdDevMS: Double?
	let keptCVPercent: Double?
	let envelopeP50MS: Double?
	let envelopeP95MS: Double?
	let scopeFilterP50MS: Double?
	let scopeFilterP95MS: Double?
	let actorP50MS: Double?
	let actorP95MS: Double?
	let formatP50MS: Double?
	let formatP95MS: Double?
	let responseBytesP95: Double?
	let cancellationCount: Int
	let mismatchCount: Int
	let rawSamples: [BenchmarkSample]
}

private enum Stats {
	static func mean(_ values: [Double]) -> Double? {
		guard !values.isEmpty else { return nil }
		return values.reduce(0, +) / Double(values.count)
	}

	static func median(_ values: [Double]) -> Double? {
		percentile(values, 0.50)
	}

	static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
		guard !values.isEmpty else { return nil }
		let sorted = values.sorted()
		let index = min(sorted.count - 1, max(0, Int(ceil(percentile * Double(sorted.count))) - 1))
		return sorted[index]
	}

	static func stddev(_ values: [Double]) -> Double? {
		guard values.count > 1, let average = mean(values) else { return nil }
		let variance = values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count - 1)
		return sqrt(variance)
	}

	static func cvPercent(_ values: [Double]) -> Double? {
		guard let average = mean(values), average > 0, let deviation = stddev(values) else { return nil }
		return deviation / average * 100
	}
}

private extension String {
	func appendLine(to url: URL) throws {
		let data = Data(utf8)
		if FileManager.default.fileExists(atPath: url.path) {
			let handle = try FileHandle(forWritingTo: url)
			defer { try? handle.close() }
			try handle.seekToEnd()
			try handle.write(contentsOf: data)
		} else {
			try data.write(to: url, options: .atomic)
		}
	}
}

#endif
