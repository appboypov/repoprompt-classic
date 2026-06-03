import XCTest
@testable import RepoPrompt

final class CodexModelPollingServiceTests: XCTestCase {
	private actor StubClient: CodexModelListingClient {
		enum Response {
			case success([CodexAppServerClient.RemoteModel])
			case failure(TestError)
			case waitThenSuccess([CodexAppServerClient.RemoteModel])
		}

		enum TestError: Error, Sendable {
			case transient
		}

		private var responses: [Response]
		private var callCount = 0
		private var stopCount = 0
		private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

		init(responses: [Response]) {
			self.responses = responses
		}

		func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
			callCount += 1
			guard !responses.isEmpty else { return [] }
			switch responses.removeFirst() {
			case .success(let models):
				return models
			case .failure(let error):
				throw error
			case .waitThenSuccess(let models):
				await withCheckedContinuation { continuation in
					waitingContinuations.append(continuation)
				}
				return models
			}
		}

		func stop() async {
			stopCount += 1
		}

		func snapshotCallCount() -> Int {
			callCount
		}

		func snapshotStopCount() -> Int {
			stopCount
		}

		func releaseBlockedCalls() {
			let continuations = waitingContinuations
			waitingContinuations.removeAll()
			for continuation in continuations {
				continuation.resume()
			}
		}
	}

	private actor SnapshotCollector {
		private(set) var snapshots: [CodexModelPollingService.Snapshot] = []

		func append(_ snapshot: CodexModelPollingService.Snapshot) {
			snapshots.append(snapshot)
		}
	}

	override func tearDown() async throws {
		AgentCodexModelRegistry.shared.updateLiveModels([])
		try await super.tearDown()
	}

	func testRefreshNowKeepsLastSnapshotAcrossTransientFailure() async {
		let firstModels = [makeModel(id: "first")]
		let secondModels = [makeModel(id: "second")]
		let client = StubClient(responses: [
			.success(firstModels),
			.failure(.transient),
			.success(secondModels)
		])
		let service = CodexModelPollingService(client: client, intervalNanos: 3_600_000_000_000)

		await service.refreshNow()
		let firstSnapshot = await service.latestSnapshot()
		XCTAssertEqual(firstSnapshot?.models, firstModels)

		await service.refreshNow()
		let snapshotAfterFailure = await service.latestSnapshot()
		XCTAssertEqual(snapshotAfterFailure?.models, firstModels)

		await service.refreshNow()
		let recoveredSnapshot = await service.latestSnapshot()
		XCTAssertEqual(recoveredSnapshot?.models, secondModels)
	}

	func testConcurrentRefreshNowCoalescesSingleClientCall() async {
		let client = StubClient(responses: [.waitThenSuccess([])])
		let service = CodexModelPollingService(client: client, intervalNanos: 3_600_000_000_000)

		async let first: Void = service.refreshNow()
		async let second: Void = service.refreshNow()
		try? await Task.sleep(nanoseconds: 100_000_000)

		let callCountBeforeRelease = await client.snapshotCallCount()
		XCTAssertEqual(callCountBeforeRelease, 1, "Concurrent refreshes should coalesce into one client call")

		await client.releaseBlockedCalls()
		_ = await (first, second)
	}

	func testRegistryIgnoresSemanticallyEquivalentUpdates() {
		let initialModels = [
			makeModel(
				id: "gpt-5.3-codex",
				description: "Frontier coding model",
				supportedReasoningEfforts: [
					(reasoningEffort: "medium", description: "Medium effort"),
					(reasoningEffort: "xhigh", description: "XHigh effort")
				],
				defaultReasoningEffort: "xhigh"
			)
		]
		let semanticallyEquivalentModels = [
			makeModel(
				id: "  gpt-5.3-codex  ",
				model: " gpt-5.3-codex ",
				displayName: "  gpt-5.3-codex  ",
				description: "  Frontier coding model  ",
				supportedReasoningEfforts: [
					(reasoningEffort: "unsupported", description: "Ignored"),
					(reasoningEffort: " X-HIGH ", description: " XHigh effort "),
					(reasoningEffort: " medium ", description: " Medium effort ")
				],
				defaultReasoningEffort: " X-HIGH "
			)
		]

		XCTAssertTrue(AgentCodexModelRegistry.shared.updateLiveModels(initialModels))
		XCTAssertFalse(AgentCodexModelRegistry.shared.updateLiveModels(semanticallyEquivalentModels))
	}

	func testSubscribeSkipsBroadcastForSemanticallyUnchangedRefresh() async {
		let initialModels = [
			makeModel(
				id: "gpt-5.3-codex",
				displayName: "GPT-5.3 Codex",
				description: "Frontier coding model",
				supportedReasoningEfforts: [
					(reasoningEffort: "medium", description: "Medium effort"),
					(reasoningEffort: "xhigh", description: "XHigh effort")
				],
				defaultReasoningEffort: "xhigh"
			)
		]
		let semanticallyEquivalentModels = [
			makeModel(
				id: " gpt-5.3-codex ",
				model: "gpt-5.3-codex",
				displayName: " GPT-5.3 Codex ",
				description: " Frontier coding model ",
				supportedReasoningEfforts: [
					(reasoningEffort: "unsupported", description: "Ignored"),
					(reasoningEffort: "X-HIGH", description: "XHigh effort"),
					(reasoningEffort: "medium", description: "Medium effort")
				],
				defaultReasoningEffort: " X-HIGH "
			)
		]
		let client = StubClient(responses: [
			.success(initialModels),
			.success(semanticallyEquivalentModels)
		])
		let service = CodexModelPollingService(client: client, intervalNanos: 3_600_000_000_000)

		await service.refreshNow()
		let stream = await service.subscribe()
		let collector = SnapshotCollector()
		let reader = Task {
			for await snapshot in stream {
				await collector.append(snapshot)
			}
		}

		try? await Task.sleep(nanoseconds: 300_000_000)

		let snapshots = await collector.snapshots
		XCTAssertEqual(snapshots.count, 1)
		XCTAssertEqual(snapshots.first?.models, initialModels)

		let callCount = await client.snapshotCallCount()
		XCTAssertEqual(callCount, 2, "Polling should still perform the refresh even when it becomes a no-op update")

		let latest = await service.latestSnapshot()
		XCTAssertEqual(latest?.models, initialModels)
		await service.shutdown(finishSubscribers: true)
		await reader.value
	}

	func testShutdownFinishesSubscriberStream() async {
		let client = StubClient(responses: [.success([makeModel(id: "live")])])
		let service = CodexModelPollingService(client: client, intervalNanos: 3_600_000_000_000)
		let stream = await service.subscribe()
		let ended = expectation(description: "stream ended")

		let reader = Task {
			for await _ in stream {}
			ended.fulfill()
		}

		await service.shutdown(finishSubscribers: true)
		await fulfillment(of: [ended], timeout: 1.0)
		reader.cancel()
	}

	func testShutdownStopsOwnedClient() async {
		let client = StubClient(responses: [])
		let service = CodexModelPollingService(
			client: client,
			intervalNanos: 3_600_000_000_000,
			stopClientOnShutdown: true
		)

		await service.shutdown(finishSubscribers: true)
		let stopCount = await client.snapshotStopCount()
		XCTAssertEqual(stopCount, 1)
	}

	func testShutdownDoesNotStopBorrowedClient() async {
		let client = StubClient(responses: [])
		let service = CodexModelPollingService(
			client: client,
			intervalNanos: 3_600_000_000_000,
			stopClientOnShutdown: false
		)

		await service.shutdown(finishSubscribers: true)
		let stopCount = await client.snapshotStopCount()
		XCTAssertEqual(stopCount, 0)
	}

	func testShutdownDropsLateRefreshResults() async {
		let lateModel = makeModel(id: "late")
		let client = StubClient(responses: [.waitThenSuccess([lateModel])])
		let service = CodexModelPollingService(client: client, intervalNanos: 3_600_000_000_000)
		_ = await service.subscribe()

		try? await Task.sleep(nanoseconds: 100_000_000)
		let callCount = await client.snapshotCallCount()
		XCTAssertEqual(callCount, 1)
		await service.shutdown(finishSubscribers: true)
		await client.releaseBlockedCalls()
		try? await Task.sleep(nanoseconds: 100_000_000)

		let latest = await service.latestSnapshot()
		XCTAssertNil(latest, "Blocked refresh results should be dropped after shutdown")
		XCTAssertTrue(AgentCodexModelRegistry.shared.currentLiveModels().isEmpty)
	}

	private func makeModel(
		id: String,
		model: String? = nil,
		displayName: String? = nil,
		description: String = "test",
		isDefault: Bool = false,
		supportedReasoningEfforts: [(reasoningEffort: String, description: String)] = [],
		defaultReasoningEffort: String? = nil
	) -> CodexAppServerClient.RemoteModel {
		CodexAppServerClient.RemoteModel(
			id: id,
			model: model ?? id,
			displayName: displayName ?? id,
			description: description,
			isDefault: isDefault,
			supportedReasoningEfforts: supportedReasoningEfforts.map {
				CodexAppServerClient.RemoteReasoningEffort(
					reasoningEffort: $0.reasoningEffort,
					description: $0.description
				)
			},
			defaultReasoningEffort: defaultReasoningEffort
		)
	}
}
