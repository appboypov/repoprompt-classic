import XCTest
@testable import RepoPrompt

final class CodeScanActorLifecycleTests: XCTestCase {
	private typealias ScanState = (
		acceptedAPIFileIDCount: Int,
		latestFileModDateCount: Int,
		trackedRoots: [String: Int],
		queueCount: Int,
		activeScanCount: Int,
		outstandingScanCount: Int
	)

	private func makeRequest(
		fileID: UUID = UUID(),
		rootFolderPath: String,
		relativePath: String,
		content: String = "struct Sample { func run() {} }\n",
		modificationDate: Date = Date()
	) -> CodeScanActor.ScanRequest {
		CodeScanActor.ScanRequest(
			fileID: fileID,
			modificationDate: modificationDate,
			content: content,
			fileExtension: "swift",
			relativePath: relativePath,
			fullPath: "\(rootFolderPath)/\(relativePath)",
			rootFolderPath: rootFolderPath
		)
	}

	private func waitForState(
		of actor: CodeScanActor,
		timeout: TimeInterval = 5,
		file: StaticString = #filePath,
		line: UInt = #line,
		until predicate: @escaping (ScanState) -> Bool
	) async -> ScanState {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let state = await actor.scanStateForTesting()
			if predicate(state) {
				return state
			}
			try? await Task.sleep(nanoseconds: 50_000_000)
		}

		let finalState = await actor.scanStateForTesting()
		XCTFail("Timed out waiting for CodeScanActor state: \(finalState)", file: file, line: line)
		return finalState
	}

	private func waitForResultContinuation(
		of actor: CodeScanActor,
		minimumCount: Int = 1,
		timeout: TimeInterval = 2,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await actor.resultContinuationCountForTesting() >= minimumCount {
				return
			}
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		let finalCount = await actor.resultContinuationCountForTesting()
		XCTFail("Timed out waiting for result continuation; count=\(finalCount)", file: file, line: line)
	}

	private func collectScanResults(
		from stream: AsyncStream<[CodeScanActor.ScanResult]>,
		expectedCount: Int,
		timeout: TimeInterval = 5,
		file: StaticString = #filePath,
		line: UInt = #line
	) async -> [CodeScanActor.ScanResult] {
		await withTaskGroup(of: [CodeScanActor.ScanResult]?.self) { group in
			group.addTask {
				var iterator = stream.makeAsyncIterator()
				var results: [CodeScanActor.ScanResult] = []
				while results.count < expectedCount {
					guard let batch = await iterator.next() else { break }
					results.append(contentsOf: batch)
				}
				return results
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				return nil
			}

			guard let first = await group.next() else {
				XCTFail("Timed out waiting for \(expectedCount) scan results", file: file, line: line)
				return []
			}
			group.cancelAll()

			guard let results = first else {
				XCTFail("Timed out waiting for \(expectedCount) scan results", file: file, line: line)
				return []
			}
			if results.count < expectedCount {
				XCTFail("Expected \(expectedCount) scan results, got \(results.count)", file: file, line: line)
			}
			return results
		}
	}

	private func makeCacheEntry(
		rootFolderPath: String,
		relativePath: String,
		content: String,
		modificationDate: Date,
		typeName: String
	) -> CodeMapCacheFileEntry {
		let fullPath = "\(rootFolderPath)/\(relativePath)"
		let cachedAPI = FileAPI(
			filePath: fullPath,
			imports: [],
			classes: [ClassInfo(name: typeName, methods: [], properties: [])],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: []
		)
		return CodeMapCacheFileEntry(
			modificationDate: modificationDate,
			contentFingerprint: CodeMapContentFingerprint(content: content),
			fileAPI: cachedAPI
		)
	}

	func testCancelAndUnloadScansRemovesTrackedEntriesForRoot() async {
		let actor = CodeScanActor()
		let root = "/tmp/rootA"
		let canonicalRoot = (root as NSString).standardizingPath

		await actor.requestScans([
			makeRequest(rootFolderPath: root, relativePath: "A.swift"),
			makeRequest(rootFolderPath: root, relativePath: "B.swift")
		])

		let loadedState = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 2 && state.outstandingScanCount == 0
		}
		XCTAssertEqual(loadedState.trackedRoots[canonicalRoot], 2)

		await actor.cancelAndUnloadScans(forRootFolder: root)

		let unloadedState = await actor.scanStateForTesting()
		XCTAssertEqual(unloadedState.acceptedAPIFileIDCount, 0)
		XCTAssertEqual(unloadedState.latestFileModDateCount, 0)
		XCTAssertNil(unloadedState.trackedRoots[canonicalRoot])
	}

	func testCancelAndUnloadScansForRootFoldersPreservesOtherRoots() async {
		let actor = CodeScanActor()
		let rootA = "/tmp/rootA"
		let rootB = "/tmp/rootB"
		let canonicalRootA = (rootA as NSString).standardizingPath
		let canonicalRootB = (rootB as NSString).standardizingPath

		await actor.requestScans([
			makeRequest(rootFolderPath: rootA, relativePath: "A.swift"),
			makeRequest(rootFolderPath: rootB, relativePath: "B.swift")
		])

		let loadedState = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 2 && state.outstandingScanCount == 0
		}
		XCTAssertEqual(loadedState.trackedRoots[canonicalRootA], 1)
		XCTAssertEqual(loadedState.trackedRoots[canonicalRootB], 1)

		await actor.cancelAndUnloadScans(forRootFolders: [rootA])

		let remainingState = await actor.scanStateForTesting()
		XCTAssertEqual(remainingState.acceptedAPIFileIDCount, 1)
		XCTAssertEqual(remainingState.latestFileModDateCount, 1)
		XCTAssertNil(remainingState.trackedRoots[canonicalRootA])
		XCTAssertEqual(remainingState.trackedRoots[canonicalRootB], 1)
	}

	func testCancelAndUnloadScansDropsBufferedResultsForUnloadedRoots() async {
		let actor = CodeScanActor()
		let rootA = "/tmp/rootA"
		let rootB = "/tmp/rootB"

		await actor.appendBufferedResultForTesting(
			makeRequest(rootFolderPath: rootA, relativePath: "A.swift"),
			fileAPI: nil
		)
		let initialSingleRootBufferedCount = await actor.resultBatchBufferCountForTesting()
		XCTAssertEqual(initialSingleRootBufferedCount, 1)

		await actor.cancelAndUnloadScans(forRootFolder: rootA)
		let afterSingleUnloadCount = await actor.resultBatchBufferCountForTesting()
		XCTAssertEqual(afterSingleUnloadCount, 0)

		await actor.appendBufferedResultForTesting(
			makeRequest(rootFolderPath: rootA, relativePath: "A.swift"),
			fileAPI: nil
		)
		await actor.appendBufferedResultForTesting(
			makeRequest(rootFolderPath: rootB, relativePath: "B.swift"),
			fileAPI: nil
		)
		let initialMultiRootBufferedCount = await actor.resultBatchBufferCountForTesting()
		XCTAssertEqual(initialMultiRootBufferedCount, 2)

		await actor.cancelAndUnloadScans(forRootFolders: [rootA, rootB])
		let afterMultiUnloadCount = await actor.resultBatchBufferCountForTesting()
		XCTAssertEqual(afterMultiUnloadCount, 0)
	}

	func testConcurrentScansCompleteThroughTreeSitterLimiter() async {
		let actor = CodeScanActor(maxConcurrentScans: 6)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorLimiterTests-\(UUID().uuidString)", isDirectory: true)
			.path
		await actor.clearAllCaches(rootFolders: [root])

		let requests = (0..<12).map { index in
			makeRequest(
				fileID: UUID(),
				rootFolderPath: root,
				relativePath: "Concurrent\(index).swift",
				content: """
				final class ConcurrentType\(index) {
					func run\(index)() -> Int { \(index) }
				}
				""",
				modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
			)
		}

		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		await actor.requestScans(requests)

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == requests.count &&
				state.outstandingScanCount == 0 &&
				state.activeScanCount == 0
		}
		let maxObservedTreeSitterPermits = await actor.treeSitterParseLimiterMaxObservedPermitsForTesting()
		XCTAssertEqual(maxObservedTreeSitterPermits, 1)

		let results = await collectScanResults(from: stream, expectedCount: requests.count)
		let resultsByFileID = Dictionary(uniqueKeysWithValues: results.map { ($0.fileID, $0) })
		for request in requests {
			let apiDescription = resultsByFileID[request.fileID]?.fileAPI?.getFullAPIDescription() ?? ""
			XCTAssertTrue(apiDescription.contains((request.relativePath as NSString).deletingPathExtension.replacingOccurrences(of: "Concurrent", with: "ConcurrentType")))
		}

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testScanResultStreamEmitsContentFreeMetadataPayload() async {
		let actor = CodeScanActor()
		let root = "/tmp/rootA"
		let fileID = UUID()
		let request = makeRequest(
			fileID: fileID,
			rootFolderPath: root,
			relativePath: "A.swift",
			content: String(repeating: "let value = 1\n", count: 10_000),
			modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let stream = actor.subscribeToScanResults()
		let nextBatchTask = Task<[CodeScanActor.ScanResult]?, Never> {
			var iterator = stream.makeAsyncIterator()
			return await iterator.next()
		}

		let deadline = Date().addingTimeInterval(2)
		while (await actor.resultContinuationCountForTesting()) == 0 && Date() < deadline {
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		let continuationCount = await actor.resultContinuationCountForTesting()
		XCTAssertEqual(continuationCount, 1)
		guard continuationCount == 1 else {
			nextBatchTask.cancel()
			return
		}

		await actor.appendBufferedResultForTesting(request, fileAPI: nil)
		await actor.flushResultBatchForTesting()

		let batch = await nextBatchTask.value
		let result = try? XCTUnwrap(batch?.first)
		XCTAssertEqual(batch?.count, 1)
		XCTAssertEqual(result?.fileID, fileID)
		XCTAssertEqual(result?.modificationDate, request.modificationDate)
		XCTAssertEqual(result?.fileExtension, request.fileExtension)
		XCTAssertEqual(result?.relativePath, request.relativePath)
		XCTAssertEqual(result?.fullPath, request.fullPath)
		XCTAssertEqual(result?.rootFolderPath, request.rootFolderPath)
		XCTAssertNil(result?.fileAPI)
	}

	func testDiskCacheContentFingerprintRegeneratesWhenMTimeIsBackdatedAndRootPathReused() async {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorLifecycleTests-\(UUID().uuidString)", isDirectory: true)
			.path
		let relativePath = "A.swift"
		let originalModDate = Date(timeIntervalSince1970: 1_700_000_000)
		let oldContent = """
		final class OldType {
			func oldMethod() {}
		}
		"""
		let newContent = """
		final class NewType {
			func newMethod() {}
		}
		"""

		await actor.clearAllCaches(rootFolders: [root])

		let oldID = UUID()
		let oldStream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		let oldRequest = makeRequest(
			fileID: oldID,
			rootFolderPath: root,
			relativePath: relativePath,
			content: oldContent,
			modificationDate: originalModDate
		)
		await actor.requestScans([oldRequest])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let oldResults = await collectScanResults(from: oldStream, expectedCount: 1)
		XCTAssertTrue(oldResults.first?.fileAPI?.getFullAPIDescription().contains("OldType") == true)

		await actor.cancelAndUnloadScans(forRootFolder: root)

		let newID = UUID()
		let previousContinuationCount = await actor.resultContinuationCountForTesting()
		let newStream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor, minimumCount: previousContinuationCount + 1)
		_ = oldStream // Keep the first stream alive until the second continuation has registered.
		let newRequest = makeRequest(
			fileID: newID,
			rootFolderPath: root,
			relativePath: relativePath,
			content: newContent,
			modificationDate: originalModDate.addingTimeInterval(-60)
		)
		await actor.requestScans([newRequest])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let newResults = await collectScanResults(from: newStream, expectedCount: 1)
		let newDescription = newResults.first?.fileAPI?.getFullAPIDescription() ?? ""
		XCTAssertFalse(newDescription.contains("OldType"))
		XCTAssertTrue(newDescription.contains("NewType"))

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testCleanRootCacheEvictedAfterFlushAndCachedAPIReloadsFromDisk() async {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorRootCacheEvictionTests-\(UUID().uuidString)", isDirectory: true)
			.path
		let relativePath = "Cached.swift"
		let fullPath = "\(root)/\(relativePath)"
		let modDate = Date(timeIntervalSince1970: 1_700_000_000)
		let content = """
		final class CachedType {
			func cachedMethod() {}
		}
		"""
		let cachedAPI = FileAPI(
			filePath: fullPath,
			imports: [],
			classes: [ClassInfo(name: "CachedType", methods: [], properties: [])],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: []
		)
		let cacheEntry = CodeMapCacheFileEntry(
			modificationDate: modDate,
			contentFingerprint: CodeMapContentFingerprint(content: content),
			fileAPI: cachedAPI
		)

		await actor.clearAllCaches(rootFolders: [root])
		await actor.installCacheEntryForTesting(
			rootFolderPath: root,
			relativePath: relativePath,
			entry: cacheEntry
		)

		let dirtyCounters = await actor.codemapMemoryCounters()
		XCTAssertEqual(dirtyCounters.rootCacheFileEntryCount, 1)
		XCTAssertEqual(dirtyCounters.dirtyRootCount, 1)

		await actor.flushCachesForTesting()

		let flushedCounters = await actor.codemapMemoryCounters()
		XCTAssertEqual(flushedCounters.rootCacheFileEntryCount, 0)
		XCTAssertEqual(flushedCounters.rootCacheRootCount, 0)
		XCTAssertEqual(flushedCounters.dirtyRootCount, 0)

		let fileID = UUID()
		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		let request = makeRequest(
			fileID: fileID,
			rootFolderPath: root,
			relativePath: relativePath,
			content: content,
			modificationDate: modDate
		)
		await actor.requestScans([request])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let results = await collectScanResults(from: stream, expectedCount: 1)
		let reloadedAPI = results.first?.fileAPI
		XCTAssertEqual(StandardizedPath.absolute(reloadedAPI?.filePath ?? ""), StandardizedPath.absolute(fullPath))
		XCTAssertTrue(reloadedAPI?.getFullAPIDescription().contains("CachedType") == true)

		let finalCounters = await actor.codemapMemoryCounters()
		XCTAssertEqual(finalCounters.rootCacheFileEntryCount, 0)
		XCTAssertEqual(finalCounters.dirtyRootCount, 0)

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testInitialRootLoadCacheHitDoesNotDirtyOrSaveCleanRootCache() async {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorInitialRootCleanHitTests-\(UUID().uuidString)", isDirectory: true)
			.path
		let relativePath = "Sources/Cached.swift"
		let modDate = Date(timeIntervalSince1970: 1_700_000_000)
		let content = """
		final class CachedType {
			func cachedMethod() {}
		}
		"""

		await actor.clearAllCaches(rootFolders: [root])
		await actor.installCacheEntryForTesting(
			rootFolderPath: root,
			relativePath: relativePath,
			entry: makeCacheEntry(
				rootFolderPath: root,
				relativePath: relativePath,
				content: content,
				modificationDate: modDate,
				typeName: "CachedType"
			)
		)
		await actor.flushCachesForTesting()
		await actor.cancelAndUnloadScans(forRootFolder: root)
		await actor.resetRootCacheDiskLoadCountersForTesting()
		await actor.resetRootCacheDiskSaveCountersForTesting()

		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		let request = makeRequest(
			rootFolderPath: root,
			relativePath: relativePath,
			content: content,
			modificationDate: modDate
		)
		await actor.requestScans([request], purpose: .initialRootLoad, rootFolderPaths: [root])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let results = await collectScanResults(from: stream, expectedCount: 1)
		XCTAssertTrue(results.first?.fileAPI?.getFullAPIDescription().contains("CachedType") == true)

		let loadCounters = await actor.rootCacheDiskLoadCountersForTesting()
		let saveCounters = await actor.rootCacheDiskSaveCountersForTesting()
		let memoryCounters = await actor.codemapMemoryCounters()
		XCTAssertEqual(loadCounters.count, 1)
		XCTAssertEqual(saveCounters.count, 0)
		XCTAssertEqual(memoryCounters.dirtyRootCount, 0)

		let diskCache = await CodeMapCacheManager().loadRootFolderCacheAsync(rootFolderPath: root)
		XCTAssertEqual(diskCache?.files.count, 1)
		XCTAssertNotNil(diskCache?.files[relativePath])

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testInitialRootLoadPrunesRemovedCacheEntriesAndSavesOnlyWhenNeeded() async {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorInitialRootPruneTests-\(UUID().uuidString)", isDirectory: true)
			.path
		let keptRelativePath = "Sources/Kept.swift"
		let removedRelativePath = "Sources/Removed.swift"
		let modDate = Date(timeIntervalSince1970: 1_700_000_000)
		let keptContent = """
		final class KeptType {
			func keptMethod() {}
		}
		"""
		let removedContent = """
		final class RemovedType {
			func removedMethod() {}
		}
		"""

		await actor.clearAllCaches(rootFolders: [root])
		await actor.installCacheEntryForTesting(
			rootFolderPath: root,
			relativePath: keptRelativePath,
			entry: makeCacheEntry(
				rootFolderPath: root,
				relativePath: keptRelativePath,
				content: keptContent,
				modificationDate: modDate,
				typeName: "KeptType"
			)
		)
		await actor.installCacheEntryForTesting(
			rootFolderPath: root,
			relativePath: removedRelativePath,
			entry: makeCacheEntry(
				rootFolderPath: root,
				relativePath: removedRelativePath,
				content: removedContent,
				modificationDate: modDate,
				typeName: "RemovedType"
			)
		)
		await actor.flushCachesForTesting()
		await actor.cancelAndUnloadScans(forRootFolder: root)
		await actor.resetRootCacheDiskSaveCountersForTesting()

		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		let keptRequest = makeRequest(
			rootFolderPath: root,
			relativePath: keptRelativePath,
			content: keptContent,
			modificationDate: modDate
		)
		await actor.requestScans([keptRequest], purpose: .initialRootLoad, rootFolderPaths: [root])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let results = await collectScanResults(from: stream, expectedCount: 1)
		XCTAssertTrue(results.first?.fileAPI?.getFullAPIDescription().contains("KeptType") == true)

		var saveCounters = await actor.rootCacheDiskSaveCountersForTesting()
		XCTAssertEqual(saveCounters.count, 1)
		XCTAssertEqual(saveCounters.savedFileEntryCount, 1)

		var diskCache = await CodeMapCacheManager().loadRootFolderCacheAsync(rootFolderPath: root)
		XCTAssertEqual(Set(diskCache?.files.keys.map { $0 } ?? []), [keptRelativePath])

		await actor.cancelAndUnloadScans(forRootFolder: root)
		await actor.resetRootCacheDiskSaveCountersForTesting()

		let secondStream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor, minimumCount: 2)
		let secondRequest = makeRequest(
			rootFolderPath: root,
			relativePath: keptRelativePath,
			content: keptContent,
			modificationDate: modDate
		)
		await actor.requestScans([secondRequest], purpose: .initialRootLoad, rootFolderPaths: [root])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		_ = await collectScanResults(from: secondStream, expectedCount: 1)

		saveCounters = await actor.rootCacheDiskSaveCountersForTesting()
		XCTAssertEqual(saveCounters.count, 0)
		diskCache = await CodeMapCacheManager().loadRootFolderCacheAsync(rootFolderPath: root)
		XCTAssertEqual(Set(diskCache?.files.keys.map { $0 } ?? []), [keptRelativePath])

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testInitialRootLoadRegeneratesAndSavesStaleRequestedCacheEntry() async {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorInitialRootStaleEntryTests-\(UUID().uuidString)", isDirectory: true)
			.path
		let relativePath = "Sources/Changed.swift"
		let modDate = Date(timeIntervalSince1970: 1_700_000_000)
		let oldContent = """
		final class OldType {
			func oldMethod() {}
		}
		"""
		let newContent = """
		final class NewType {
			func newMethod() {}
		}
		"""

		await actor.clearAllCaches(rootFolders: [root])
		await actor.installCacheEntryForTesting(
			rootFolderPath: root,
			relativePath: relativePath,
			entry: makeCacheEntry(
				rootFolderPath: root,
				relativePath: relativePath,
				content: oldContent,
				modificationDate: modDate,
				typeName: "OldType"
			)
		)
		await actor.flushCachesForTesting()
		await actor.cancelAndUnloadScans(forRootFolder: root)
		await actor.resetRootCacheDiskSaveCountersForTesting()

		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		let request = makeRequest(
			rootFolderPath: root,
			relativePath: relativePath,
			content: newContent,
			modificationDate: modDate
		)
		await actor.requestScans([request], purpose: .initialRootLoad, rootFolderPaths: [root])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let results = await collectScanResults(from: stream, expectedCount: 1)
		let regeneratedDescription = results.first?.fileAPI?.getFullAPIDescription() ?? ""
		XCTAssertFalse(regeneratedDescription.contains("OldType"))
		XCTAssertTrue(regeneratedDescription.contains("NewType"))

		let saveCounters = await actor.rootCacheDiskSaveCountersForTesting()
		XCTAssertEqual(saveCounters.count, 1)
		XCTAssertEqual(saveCounters.savedFileEntryCount, 1)

		let diskCache = await CodeMapCacheManager().loadRootFolderCacheAsync(rootFolderPath: root)
		let diskDescription = diskCache?.files[relativePath]?.fileAPI.getFullAPIDescription() ?? ""
		XCTAssertFalse(diskDescription.contains("OldType"))
		XCTAssertTrue(diskDescription.contains("NewType"))

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testCachedAPIWithDifferentAbsolutePathIsRejectedAndRegenerated() async {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorPathProvenanceTests-\(UUID().uuidString)", isDirectory: true)
			.path
		let relativePath = "A.swift"
		let currentPath = "\(root)/\(relativePath)"
		let oldPath = "\(root)-old/\(relativePath)"
		let modDate = Date(timeIntervalSince1970: 1_700_000_000)
		let content = """
		final class NewType {
			func newMethod() {}
		}
		"""
		let mismatchedCachedAPI = FileAPI(
			filePath: oldPath,
			imports: [],
			classes: [ClassInfo(name: "OldType", methods: [], properties: [])],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: []
		)
		let cacheEntry = CodeMapCacheFileEntry(
			modificationDate: modDate.addingTimeInterval(60),
			contentFingerprint: CodeMapContentFingerprint(content: content),
			fileAPI: mismatchedCachedAPI
		)

		await actor.clearAllCaches(rootFolders: [root])
		await actor.installCacheEntryForTesting(
			rootFolderPath: root,
			relativePath: relativePath,
			entry: cacheEntry
		)
		await actor.flushCachesForTesting()
		await actor.cancelAndUnloadScans(forRootFolder: root)

		let fileID = UUID()
		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		let request = makeRequest(
			fileID: fileID,
			rootFolderPath: root,
			relativePath: relativePath,
			content: content,
			modificationDate: modDate
		)
		await actor.requestScans([request])

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == 1 && state.outstandingScanCount == 0 && state.activeScanCount == 0
		}
		let results = await collectScanResults(from: stream, expectedCount: 1)
		let regeneratedAPI = results.first?.fileAPI
		let regeneratedDescription = regeneratedAPI?.getFullAPIDescription() ?? ""
		XCTAssertEqual(StandardizedPath.absolute(regeneratedAPI?.filePath ?? ""), StandardizedPath.absolute(currentPath))
		XCTAssertFalse(regeneratedDescription.contains("OldType"))
		XCTAssertTrue(regeneratedDescription.contains("NewType"))

		await actor.clearAllCaches(rootFolders: [root])
	}

	func testRootCacheEvictionCacheHitPerformanceSmoke() async throws {
		let runEnvironmentKey = "REPOPROMPT_RUN_CODEMAP_CACHE_EVICTION_BENCHMARKS"
		let markerPath = "/tmp/repoprompt-run-codemap-cache-eviction-benchmarks"
		guard Self.environmentFlagEnabled(runEnvironmentKey) || FileManager.default.fileExists(atPath: markerPath) else {
			throw XCTSkip("Set \(runEnvironmentKey)=1 or create \(markerPath) to run the root-cache eviction cache-hit performance smoke.")
		}

		let fileCount = Self.environmentInt("REPOPROMPT_CODEMAP_CACHE_EVICTION_FILE_COUNT", defaultValue: 3_500)
		let requestCount = Self.environmentInt("REPOPROMPT_CODEMAP_CACHE_EVICTION_REQUESTS", defaultValue: 20)
		let measuredSamples = Self.environmentInt("REPOPROMPT_CODEMAP_CACHE_EVICTION_SAMPLES", defaultValue: 5)
		let modDate = Date(timeIntervalSince1970: 1_700_000_000)
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("CodeScanActorCacheEvictionPerf-\(UUID().uuidString)", isDirectory: true)
		let root = rootURL.path
		let fixture = Self.makeRootCacheFixture(root: root, fileCount: fileCount, modDate: modDate)
		let cacheManager = CodeMapCacheManager()
		let cleanupActor = CodeScanActor(maxConcurrentScans: 1)
		await cleanupActor.clearAllCaches(rootFolders: [root])
		XCTAssertTrue(cacheManager.saveRootFolderCache(root, rootEntry: fixture.rootCache))
		defer {
			cacheManager.removeRootFolder(root)
			try? FileManager.default.removeItem(at: rootURL)
		}

		var individualMeasurements: [RootCacheHitMeasurement] = []
		var batchMeasurements: [RootCacheHitMeasurement] = []
		individualMeasurements.reserveCapacity(measuredSamples)
		batchMeasurements.reserveCapacity(measuredSamples)

		var reportRows: [String] = []
		reportRows.append("Codemap root-cache eviction cache-hit performance smoke")
		reportRows.append("cacheEntries=\(fileCount), requestsPerSample=\(requestCount), measuredSamples=\(measuredSamples), plus one warm-up sample")
		reportRows.append("env \(runEnvironmentKey)=\(ProcessInfo.processInfo.environment[runEnvironmentKey] ?? "<unset>"), marker=\(FileManager.default.fileExists(atPath: markerPath) ? markerPath : "<absent>")")
		reportRows.append("")

		for sampleIndex in 0...measuredSamples {
			let includeInMedian = sampleIndex != 0
			let label = includeInMedian ? "sample-\(sampleIndex)" : "warm-up"
			let individual = try await measureRootCacheHitPhase(
				label: "\(label)-individual",
				mode: .individual,
				root: root,
				fixture: fixture,
				requestCount: requestCount,
				modDate: modDate
			)
			let batch = try await measureRootCacheHitPhase(
				label: "\(label)-batch",
				mode: .batch,
				root: root,
				fixture: fixture,
				requestCount: requestCount,
				modDate: modDate
			)
			reportRows.append(Self.reportLine(measurement: individual, includeInMedian: includeInMedian))
			reportRows.append(Self.reportLine(measurement: batch, includeInMedian: includeInMedian))
			if includeInMedian {
				individualMeasurements.append(individual)
				batchMeasurements.append(batch)
			}
		}

		reportRows.append("")
		reportRows.append(Self.summaryLine(label: "individual requestScan cache hits", measurements: individualMeasurements))
		reportRows.append(Self.summaryLine(label: "batch requestScans cache hits", measurements: batchMeasurements))
		if let individualMedian = Self.median(individualMeasurements.map(\.wallMilliseconds)),
			let batchMedian = Self.median(batchMeasurements.map(\.wallMilliseconds)) {
			reportRows.append("batchVsIndividualWallMedianRatio=\(Self.formatDouble(batchMedian / individualMedian))")
		}

		let report = reportRows.joined(separator: "\n")
		let reportURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("repoprompt-codemap-root-cache-eviction-performance-smoke-report.txt")
		try? report.write(to: reportURL, atomically: true, encoding: .utf8)
		print("\n\(report)\n")
		XCTContext.runActivity(named: "Codemap root-cache eviction cache-hit performance smoke report") { activity in
			activity.add(XCTAttachment(string: report))
		}
	}

	private enum RootCacheHitMode {
		case individual
		case batch
	}

	private struct RootCacheFixture {
		let rootCache: CodeMapCacheRootFolder
		let relativePaths: [String]
		let contents: [String]
	}

	private struct RootCacheHitMeasurement {
		let label: String
		let mode: RootCacheHitMode
		let requestCount: Int
		let wallMilliseconds: Double
		let diskLoadCount: Int
		let diskLoadMilliseconds: Double
		let loadedFileEntryCount: Int
		let finalRootCacheFileEntryCount: Int
		let finalDirtyRootCount: Int
	}

	private static func makeRootCacheFixture(
		root: String,
		fileCount: Int,
		modDate: Date
	) -> RootCacheFixture {
		var files: [String: CodeMapCacheFileEntry] = [:]
		var relativePaths: [String] = []
		var contents: [String] = []
		files.reserveCapacity(fileCount)
		relativePaths.reserveCapacity(fileCount)
		contents.reserveCapacity(fileCount)

		for index in 0..<fileCount {
			let relativePath = "Sources/Cached\(index).swift"
			let content = """
			final class Cached\(index) {
				func value\(index)() -> Int { \(index) }
			}
			"""
			let fullPath = "\(root)/\(relativePath)"
			let fileAPI = FileAPI(
				filePath: fullPath,
				imports: [],
				classes: [ClassInfo(name: "Cached\(index)", methods: [], properties: [])],
				functions: [],
				enums: [],
				globalVars: [],
				macros: [],
				referencedTypes: []
			)
			files[relativePath] = CodeMapCacheFileEntry(
				modificationDate: modDate,
				contentFingerprint: CodeMapContentFingerprint(content: content),
				fileAPI: fileAPI
			)
			relativePaths.append(relativePath)
			contents.append(content)
		}

		return RootCacheFixture(
			rootCache: CodeMapCacheRootFolder(files: files),
			relativePaths: relativePaths,
			contents: contents
		)
	}

	private func measureRootCacheHitPhase(
		label: String,
		mode: RootCacheHitMode,
		root: String,
		fixture: RootCacheFixture,
		requestCount: Int,
		modDate: Date
	) async throws -> RootCacheHitMeasurement {
		let actor = CodeScanActor(maxConcurrentScans: 1)
		let stream = actor.subscribeToScanResults()
		await waitForResultContinuation(of: actor)
		await actor.resetRootCacheDiskLoadCountersForTesting()

		let requests = (0..<requestCount).map { index in
			let fixtureIndex = index % fixture.relativePaths.count
			let relativePath = fixture.relativePaths[fixtureIndex]
			return makeRequest(
				fileID: UUID(),
				rootFolderPath: root,
				relativePath: relativePath,
				content: fixture.contents[fixtureIndex],
				modificationDate: modDate
			)
		}

		let start = DispatchTime.now().uptimeNanoseconds
		switch mode {
		case .individual:
			for request in requests {
				await actor.requestScan(request)
			}
		case .batch:
			await actor.requestScans(requests)
		}
		let elapsed = DispatchTime.now().uptimeNanoseconds - start

		_ = await waitForState(of: actor) { state in
			state.acceptedAPIFileIDCount == requestCount &&
				state.outstandingScanCount == 0 &&
				state.activeScanCount == 0
		}
		await actor.flushResultBatchForTesting()
		let results = await collectScanResults(from: stream, expectedCount: requestCount)
		XCTAssertEqual(results.count, requestCount)
		XCTAssertTrue(results.allSatisfy { $0.fileAPI != nil })

		let diskLoadCounters = await actor.rootCacheDiskLoadCountersForTesting()
		let memoryCounters = await actor.codemapMemoryCounters()
		XCTAssertEqual(memoryCounters.queuedCount, 0)
		XCTAssertEqual(memoryCounters.activeScanCount, 0)
		XCTAssertEqual(memoryCounters.outstandingScanCount, 0)
		XCTAssertEqual(memoryCounters.cacheProcessingCount, 0)
		XCTAssertGreaterThanOrEqual(diskLoadCounters.count, 1)

		return RootCacheHitMeasurement(
			label: label,
			mode: mode,
			requestCount: requestCount,
			wallMilliseconds: Self.milliseconds(elapsed),
			diskLoadCount: diskLoadCounters.count,
			diskLoadMilliseconds: diskLoadCounters.duration * 1_000,
			loadedFileEntryCount: diskLoadCounters.loadedFileEntryCount,
			finalRootCacheFileEntryCount: memoryCounters.rootCacheFileEntryCount,
			finalDirtyRootCount: memoryCounters.dirtyRootCount
		)
	}

	private static func reportLine(measurement: RootCacheHitMeasurement, includeInMedian: Bool) -> String {
		let modeLabel: String = measurement.mode == .individual ? "individual" : "batch"
		return "\(measurement.label) | include=\(includeInMedian ? "yes" : "no") | mode=\(modeLabel) | requests=\(measurement.requestCount) | wall=\(formatDouble(measurement.wallMilliseconds)) ms | diskLoads=\(measurement.diskLoadCount) | diskLoad=\(formatDouble(measurement.diskLoadMilliseconds)) ms | loadedEntries=\(measurement.loadedFileEntryCount) | finalRootCacheEntries=\(measurement.finalRootCacheFileEntryCount) | dirtyRoots=\(measurement.finalDirtyRootCount)"
	}

	private static func summaryLine(label: String, measurements: [RootCacheHitMeasurement]) -> String {
		let walls = measurements.map(\.wallMilliseconds)
		let diskDurations = measurements.map(\.diskLoadMilliseconds)
		let diskCounts = measurements.map { Double($0.diskLoadCount) }
		return "\(label) summary | wallMedian=\(formatOptional(median(walls))) ms | wallP90=\(formatOptional(percentile(walls, 0.9))) ms | diskLoadCountMedian=\(formatOptional(median(diskCounts))) | diskLoadDurationMedian=\(formatOptional(median(diskDurations))) ms"
	}

	private static func environmentFlagEnabled(_ key: String) -> Bool {
		guard let rawValue = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
			return false
		}
		return ["1", "true", "yes", "on"].contains(rawValue)
	}

	private static func environmentInt(_ key: String, defaultValue: Int) -> Int {
		guard let rawValue = ProcessInfo.processInfo.environment[key], let parsed = Int(rawValue) else {
			return defaultValue
		}
		return max(parsed, 1)
	}

	private static func milliseconds(_ nanoseconds: UInt64) -> Double {
		Double(nanoseconds) / 1_000_000.0
	}

	private static func median(_ values: [Double]) -> Double? {
		percentile(values, 0.5)
	}

	private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
		guard !values.isEmpty else { return nil }
		let sorted = values.sorted()
		let clampedFraction = min(max(fraction, 0), 1)
		let index = Int((Double(sorted.count - 1) * clampedFraction).rounded(.up))
		return sorted[index]
	}

	private static func formatOptional(_ value: Double?) -> String {
		guard let value else { return "n/a" }
		return formatDouble(value)
	}

	private static func formatDouble(_ value: Double) -> String {
		String(format: "%.2f", value)
	}
}
