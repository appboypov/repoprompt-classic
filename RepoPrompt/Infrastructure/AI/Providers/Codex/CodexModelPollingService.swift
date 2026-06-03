import Foundation

protocol CodexModelListingClient: Sendable {
	func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel]
	func stop() async
}

extension CodexAppServerClient: CodexModelListingClient {}

// SEARCH-HELPER: Codex model polling, centralized, shared client, model list, subscribe
/// Centralized polling service for Codex dynamic models.
///
/// Replaces duplicated polling logic previously spread across:
/// - `CodexAgentModeCoordinator`
/// - `DiscoverAgentViewModel`
/// - `APISettingsViewModel` (one-shot refresh)
///
/// Owns:
/// - A single polling loop using a dedicated `CodexAppServerClient`
/// - Broadcasting model snapshots to subscribers via `AsyncStream`
/// - Updating `AgentCodexModelRegistry` as the single canonical writer
///
/// Related:
/// - CodexProviderHelpers.makeOwnedNonAgentAppServerClient() (dedicated polling transport)
/// - AgentCodexModelRegistry (canonical registry updated by this service)
/// - AgentModelCatalog (consumes registry for model option resolution)
actor CodexModelPollingService {
	static let shared = CodexModelPollingService(
		client: CodexProviderHelpers.makeOwnedNonAgentAppServerClient(),
		stopClientOnShutdown: true
	)

	struct Snapshot: Sendable, Equatable {
		let models: [CodexAppServerClient.RemoteModel]
		let fetchedAt: Date
	}

	private let client: any CodexModelListingClient
	private let intervalNanos: UInt64
	private let stopClientOnShutdown: Bool

	private var pollingTask: Task<Void, Never>?
	private var inFlightRefresh: Task<Void, Never>?
	private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
	private var latest: Snapshot?
	private var isShutdown = false

	init(
		client: any CodexModelListingClient,
		intervalNanos: UInt64 = 60_000_000_000,
		stopClientOnShutdown: Bool = false
	) {
		self.client = client
		self.intervalNanos = intervalNanos
		self.stopClientOnShutdown = stopClientOnShutdown
	}

	/// Returns the most recent snapshot if available (non-blocking).
	func latestSnapshot() -> Snapshot? {
		latest
	}

	/// Subscribe to model snapshot updates.
	///
	/// - Immediately yields the latest snapshot if one exists.
	/// - Starts the polling loop if not already running.
	/// - When the last subscriber detaches, the polling loop is cancelled.
	func subscribe() -> AsyncStream<Snapshot> {
		guard !isShutdown else {
			return AsyncStream { continuation in
				continuation.finish()
			}
		}
		let id = UUID()
		let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
		continuations[id] = continuation

		// Yield latest immediately so UI populates without waiting for the first tick.
		if let latest {
			continuation.yield(latest)
		}

		continuation.onTermination = { [weak self] _ in
			Task { await self?.removeSubscriber(id) }
		}

		startPollingIfNeeded()
		return stream
	}

	/// Force an immediate model refresh (e.g. after connectivity test succeeds).
	/// Updates the registry and only broadcasts when the normalized model payload changes.
	/// Coalesces with any in-flight refresh to avoid overlapping network/process calls.
	func refreshNow() async {
		guard !isShutdown else { return }
		if let existing = inFlightRefresh {
			await existing.value
			return
		}
		await performRefresh()
	}

	func shutdown(finishSubscribers: Bool = true) async {
		isShutdown = true
		pollingTask?.cancel()
		pollingTask = nil
		inFlightRefresh?.cancel()
		inFlightRefresh = nil
		if finishSubscribers {
			let activeContinuations = continuations
			continuations.removeAll()
			for continuation in activeContinuations.values {
				continuation.finish()
			}
		}
		if stopClientOnShutdown {
			await client.stop()
		}
	}

	// MARK: - Internal

	private func startPollingIfNeeded() {
		guard !isShutdown else { return }
		guard pollingTask == nil else { return }
		pollingTask = Task { [weak self] in
			guard let self else { return }
			while !Task.isCancelled {
				await self.performRefresh()
				do {
					try await Task.sleep(nanoseconds: await self.intervalNanos)
				} catch {
					break
				}
			}
		}
	}

	private func stopPollingIfIdle() {
		guard continuations.isEmpty else { return }
		pollingTask?.cancel()
		pollingTask = nil
	}

	private func removeSubscriber(_ id: UUID) {
		continuations.removeValue(forKey: id)
		stopPollingIfIdle()
	}

	private func performRefresh() async {
		guard !isShutdown else { return }
		// Single-flight: if a refresh is already running, await it instead of starting another.
		if let existing = inFlightRefresh {
			await existing.value
			return
		}
		let task = Task { [weak self] in
			guard let self else { return }
			do {
				let models = try await self.client.listModels(limit: 100)
				guard !Task.isCancelled else { return }
				let snapshot = Snapshot(models: models, fetchedAt: Date())
				await self.applyRefreshResult(snapshot)
			} catch {
				// Keep existing cache when refresh fails; callers fall back to static list when empty.
			}
		}
		inFlightRefresh = task
		defer { inFlightRefresh = nil }
		await task.value
	}

	private func applyRefreshResult(_ snapshot: Snapshot) {
		guard !isShutdown else { return }

		// Single canonical registry update — no other call site should write to the registry.
		let didChange = AgentCodexModelRegistry.shared.updateLiveModels(snapshot.models)
		guard didChange else { return }
		latest = snapshot

		for continuation in continuations.values {
			continuation.yield(snapshot)
		}
	}
}
