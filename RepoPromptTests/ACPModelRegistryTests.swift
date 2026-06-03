import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class ACPModelRegistryTests: XCTestCase {
	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		super.tearDown()
	}

	func testUpdateDiscoveredModelsNoOpsForSemanticallyEquivalentSnapshots() {
		let initial = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: " gemini-2.5-pro ",
					displayName: " Gemini 2.5 Pro ",
					description: " Primary ",
					isPlaceholderDefault: false,
					isProviderDefault: true,
					supportedReasoningEfforts: [.high, .low, .high],
					defaultReasoningEffort: .high
				),
				AgentModelOption(
					rawValue: "gemini-2.5-flash",
					displayName: "Gemini 2.5 Flash",
					description: "Fast",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: " gemini-2.5-pro "
		)
		let equivalent = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "GEMINI-2.5-PRO",
					displayName: "Gemini 2.5 Pro",
					description: "Primary",
					isPlaceholderDefault: false,
					isProviderDefault: true,
					supportedReasoningEfforts: [.low, .high],
					defaultReasoningEffort: .high
				),
				AgentModelOption(
					rawValue: "gemini-2.5-pro",
					displayName: "Duplicate should be ignored",
					description: "Duplicate",
					isPlaceholderDefault: false,
					isProviderDefault: false
				),
				AgentModelOption(
					rawValue: "gemini-2.5-flash",
					displayName: "Gemini 2.5 Flash",
					description: "Fast",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: "gemini-2.5-pro"
		)

		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(initial, for: .gemini))
		XCTAssertFalse(AgentACPModelRegistry.shared.updateDiscoveredModels(equivalent, for: .gemini))
		XCTAssertEqual(
			AgentACPModelRegistry.shared.test_snapshot(providerID: .gemini)?.preferredModelRaw,
			"gemini-2.5-pro"
		)
	}

	func testCatalogFallsBackToPersistedStoreAfterAsyncWarm() async {
		let snapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "gemini-2.5-pro",
					displayName: "Gemini 2.5 Pro",
					description: "Primary",
					isPlaceholderDefault: false,
					isProviderDefault: true
				)
			],
			currentModelRaw: "gemini-2.5-pro"
		)

		ACPDynamicModelStore.save(snapshot, for: .gemini)
		XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .gemini))

		await AgentACPModelRegistry.shared.test_warmStandardStore()

		XCTAssertEqual(AgentModelCatalog.options(for: .gemini).map(\.rawValue), ["gemini-2.5-pro"])
		XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .gemini), "gemini-2.5-pro")
	}

	func testCatalogDoesNotSynchronouslyLoadPersistedOpenCodeStoreBeforeWarm() async {
		let cached = Self.openCodeSnapshot(currentModelRaw: "openai/gpt-5")
		ACPDynamicModelStore.save(cached, for: .openCode)
		AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: .openCode)
		let availability = AgentModelCatalog.AvailabilityContext(openCodeAvailable: true, zaiConfigured: false)

		XCTAssertEqual(
			AgentModelCatalog.options(for: .openCode, availability: availability).map(\.rawValue),
			[AgentModel.defaultModel.rawValue]
		)

		await AgentACPModelRegistry.shared.test_warmStandardStore()

		XCTAssertEqual(
			Set(AgentModelCatalog.options(for: .openCode, availability: availability).map(\.rawValue)),
			Set(["openai/gpt-5", "anthropic/claude-sonnet-4"])
		)
		XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .openCode, availability: availability), "openai/gpt-5")
	}

	func testRegistryCanonicalizesOptionOrderLikeCodexStore() {
		let snapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "gemini-2.5-pro",
					displayName: "Gemini 2.5 Pro",
					description: "Primary",
					isPlaceholderDefault: false,
					isProviderDefault: true
				),
				AgentModelOption(
					rawValue: "gemini-2.5-flash",
					displayName: "Gemini 2.5 Flash",
					description: "Fast",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: "gemini-2.5-pro"
		)

		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .gemini))
		XCTAssertEqual(
			AgentACPModelRegistry.shared.test_snapshot(providerID: .gemini)?.options.map(\.rawValue),
			["gemini-2.5-flash", "gemini-2.5-pro"]
		)
		XCTAssertEqual(
			AgentACPModelRegistry.shared.test_snapshot(providerID: .gemini)?.preferredModelRaw,
			"gemini-2.5-pro"
		)
	}

	func testStoreRoundTripsPerProviderSnapshot() {
		let suiteName = "ACPModelRegistryTests-\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			return XCTFail("Failed to create isolated UserDefaults suite")
		}
		defer {
			defaults.removePersistentDomain(forName: suiteName)
		}

		let snapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "gemini-2.5-pro",
					displayName: "Gemini 2.5 Pro",
					description: "Primary",
					isPlaceholderDefault: false,
					isProviderDefault: true,
					supportedReasoningEfforts: [.low, .high],
					defaultReasoningEffort: .high
				),
				AgentModelOption(
					rawValue: "gemini-2.5-flash",
					displayName: "Gemini 2.5 Flash",
					description: "Fast",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: "gemini-2.5-pro"
		)

		ACPDynamicModelStore.save(snapshot, for: .gemini, defaults: defaults)
		let loaded = ACPDynamicModelStore.load(providerID: .gemini, defaults: defaults)
		XCTAssertEqual(loaded?.currentModelRaw, "gemini-2.5-pro")
		XCTAssertEqual(loaded?.options.map(\.rawValue), ["gemini-2.5-flash", "gemini-2.5-pro"])
		XCTAssertEqual(loaded?.options.last?.defaultReasoningEffort, .high)
	}

	func testStoreBatchLoadsGeminiAndOpenCodeSnapshots() {
		let suiteName = "ACPModelRegistryTests-\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			return XCTFail("Failed to create isolated UserDefaults suite")
		}
		defer {
			defaults.removePersistentDomain(forName: suiteName)
		}

		let geminiSnapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "gemini-2.5-pro",
					displayName: "Gemini 2.5 Pro",
					description: nil,
					isPlaceholderDefault: false,
					isProviderDefault: true
				)
			],
			currentModelRaw: "gemini-2.5-pro"
		)
		let openCodeSnapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "openai/gpt-5",
					displayName: "GPT-5 via OpenCode",
					description: nil,
					isPlaceholderDefault: false,
					isProviderDefault: true
				)
			],
			currentModelRaw: "openai/gpt-5"
		)

		ACPDynamicModelStore.save(geminiSnapshot, for: .gemini, defaults: defaults)
		ACPDynamicModelStore.save(openCodeSnapshot, for: .openCode, defaults: defaults)

		let snapshots = ACPDynamicModelStore.loadAll(defaults: defaults)
		XCTAssertEqual(snapshots[.gemini]?.preferredModelRaw, "gemini-2.5-pro")
		XCTAssertEqual(snapshots[.openCode]?.preferredModelRaw, "openai/gpt-5")
		XCTAssertEqual(ACPDynamicModelStore.load(providerID: .gemini, defaults: defaults)?.preferredModelRaw, "gemini-2.5-pro")
		XCTAssertEqual(ACPDynamicModelStore.load(providerID: .openCode, defaults: defaults)?.preferredModelRaw, "openai/gpt-5")
	}

	func testOpenCodePollingServiceUpdatesRegistryAndBroadcastsDiscovery() async {
		let discovered = Self.openCodeSnapshot(currentModelRaw: "openai/gpt-5")
		let client = MockOpenCodeACPModelDiscoveryClient(snapshots: [discovered])
		let service = OpenCodeACPModelPollingService(
			client: client,
			intervalNanos: 60_000_000_000
		)
		let stream = await service.subscribe(workspacePath: "/tmp/opencode-workspace")
		guard let snapshot = await Self.firstOpenCodePollingSnapshot(from: stream) else {
			await service.shutdown()
			return XCTFail("Timed out waiting for OpenCode polling snapshot")
		}
		await service.shutdown()

		XCTAssertEqual(snapshot.models.preferredModelRaw, "openai/gpt-5")
		XCTAssertEqual(
			AgentACPModelRegistry.shared.test_snapshot(providerID: .openCode)?.preferredModelRaw,
			"openai/gpt-5"
		)
		let requestedWorkspacePaths = await client.requestedWorkspacePaths
		XCTAssertEqual(requestedWorkspacePaths, ["/tmp/opencode-workspace"])
	}

	func testOpenCodePollingServiceDiscoverOnceUpdatesRegistryBeforeSubscription() async throws {
		let discovered = Self.openCodeSnapshot(currentModelRaw: "openai/gpt-5")
		let client = MockOpenCodeACPModelDiscoveryClient(snapshots: [discovered])
		let service = OpenCodeACPModelPollingService(
			client: client,
			intervalNanos: 60_000_000_000
		)
		let snapshot = try await service.discoverOnce(workspacePath: "/tmp/opencode-settings")
		await service.shutdown()

		XCTAssertEqual(snapshot?.models.preferredModelRaw, "openai/gpt-5")
		XCTAssertEqual(
			AgentACPModelRegistry.shared.test_snapshot(providerID: .openCode)?.preferredModelRaw,
			"openai/gpt-5"
		)
		let requestedWorkspacePaths = await client.requestedWorkspacePaths
		XCTAssertEqual(requestedWorkspacePaths, ["/tmp/opencode-settings"])
	}

	func testOpenCodePollingServiceYieldsCachedRegistrySnapshotImmediately() async {
		let cached = Self.openCodeSnapshot(currentModelRaw: "anthropic/claude-sonnet-4")
		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(cached, for: .openCode))
		let client = MockOpenCodeACPModelDiscoveryClient(snapshots: [])
		let service = OpenCodeACPModelPollingService(
			client: client,
			intervalNanos: 60_000_000_000
		)
		let stream = await service.subscribe(workspacePath: nil)
		guard let snapshot = await Self.firstOpenCodePollingSnapshot(from: stream) else {
			await service.shutdown()
			return XCTFail("Timed out waiting for cached OpenCode polling snapshot")
		}
		await service.shutdown()

		XCTAssertEqual(snapshot.models.preferredModelRaw, "anthropic/claude-sonnet-4")
	}

	func testOpenCodePollingServiceYieldsPersistedStoreSnapshotAfterAsyncWarm() async {
		let cached = Self.openCodeSnapshot(currentModelRaw: "anthropic/claude-sonnet-4")
		ACPDynamicModelStore.save(cached, for: .openCode)
		AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: .openCode)
		let client = MockOpenCodeACPModelDiscoveryClient(snapshots: [])
		let service = OpenCodeACPModelPollingService(
			client: client,
			intervalNanos: 60_000_000_000
		)
		let stream = await service.subscribe(workspacePath: nil)
		guard let snapshot = await Self.firstOpenCodePollingSnapshot(from: stream) else {
			await service.shutdown()
			return XCTFail("Timed out waiting for persisted OpenCode polling snapshot")
		}
		await service.shutdown()

		XCTAssertEqual(snapshot.models.preferredModelRaw, "anthropic/claude-sonnet-4")
		XCTAssertEqual(Set(snapshot.models.options.map(\.rawValue)), Set(["openai/gpt-5", "anthropic/claude-sonnet-4"]))
	}

	private static func openCodeSnapshot(currentModelRaw: String) -> ACPDiscoveredSessionModels {
		ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "openai/gpt-5",
					displayName: "GPT-5 via OpenCode",
					description: nil,
					isPlaceholderDefault: false,
					isProviderDefault: currentModelRaw == "openai/gpt-5"
				),
				AgentModelOption(
					rawValue: "anthropic/claude-sonnet-4",
					displayName: "Claude Sonnet 4 via OpenCode",
					description: nil,
					isPlaceholderDefault: false,
					isProviderDefault: currentModelRaw == "anthropic/claude-sonnet-4"
				)
			],
			currentModelRaw: currentModelRaw
		)
	}

	private static func firstOpenCodePollingSnapshot(
		from stream: AsyncStream<OpenCodeACPModelPollingService.Snapshot>,
		timeoutNanos: UInt64 = 2_000_000_000
	) async -> OpenCodeACPModelPollingService.Snapshot? {
		await withTaskGroup(of: OpenCodeACPModelPollingService.Snapshot?.self) { group in
			group.addTask {
				var iterator = stream.makeAsyncIterator()
				return await iterator.next()
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: timeoutNanos)
				return nil
			}
			let result = await group.next() ?? nil
			group.cancelAll()
			return result
		}
	}
}

private actor MockOpenCodeACPModelDiscoveryClient: OpenCodeACPModelDiscoveryClient {
	private var snapshots: [ACPDiscoveredSessionModels?]
	private(set) var requestedWorkspacePaths: [String?] = []

	init(snapshots: [ACPDiscoveredSessionModels?]) {
		self.snapshots = snapshots
	}

	func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels? {
		requestedWorkspacePaths.append(workspacePath)
		guard !snapshots.isEmpty else { return nil }
		return snapshots.removeFirst() ?? nil
	}
}
