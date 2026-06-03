import XCTest
@testable import RepoPrompt

final class CodexManagedAuthRecoveryServiceTests: XCTestCase {
	func testRefreshManagedAccountReturnsExecutableUnavailableWhenClientStartFails() async {
		let message = "Codex CLI executable was not found. Install Codex CLI and ensure `codex` is available in your login shell PATH. RepoPrompt searched your login-shell PATH plus common Homebrew, npm/pnpm/yarn/Volta, Bun, Cargo, version-manager shim, and Codex.app locations."
		let client = MockManagedAuthRPCClient(startError: CodexAppServerClient.ClientError.executableUnavailable(message))
		let service = CodexManagedAuthRecoveryService { client }

		let result = await service.refreshManagedAccount()

		XCTAssertEqual(result, .executableUnavailable(message: message))
		let startCallCount = await client.startCallCount()
		XCTAssertEqual(startCallCount, 1)
	}

	func testStartManagedChatgptLoginDoesNotOpenURLWhenExecutableUnavailable() async {
		let message = "Codex CLI resolved to `/missing/codex`, but that file does not exist. Reinstall Codex CLI or fix your shell PATH."
		let client = MockManagedAuthRPCClient(startError: CodexAppServerClient.ClientError.executableUnavailable(message))
		let service = CodexManagedAuthRecoveryService { client }
		let openURLRecorder = await MainActor.run { OpenURLRecorder() }

		let result = await service.startManagedChatgptLogin { url in
			openURLRecorder.record(url)
		}

		XCTAssertEqual(result, .executableUnavailable(message: message))
		let startCallCount = await client.startCallCount()
		XCTAssertEqual(startCallCount, 1)
		let openedURLCount = await MainActor.run { openURLRecorder.urls.count }
		XCTAssertEqual(openedURLCount, 0)
	}
}

@MainActor
private final class OpenURLRecorder {
	private(set) var urls: [URL] = []

	func record(_ url: URL) {
		urls.append(url)
	}
}

private actor MockManagedAuthRPCClient: CodexManagedAuthRPCClient {
	private let startError: Error?
	private var recordedStartCallCount = 0
	private var recordedStopCallCount = 0
	private var queuedResponses: [[String: Any]]

	init(startError: Error? = nil, responses: [[String: Any]] = []) {
		self.startError = startError
		self.queuedResponses = responses
	}

	func startIfNeeded() async throws {
		recordedStartCallCount += 1
		if let startError {
			throw startError
		}
	}

	func stop() async {
		recordedStopCallCount += 1
	}

	func request(
		method: String,
		params: [String: Any]?,
		timeout: TimeInterval?
	) async throws -> [String: Any] {
		_ = method
		_ = params
		_ = timeout
		if queuedResponses.isEmpty {
			throw AIProviderError.invalidResponse(detail: "Unexpected managed auth request in test.")
		}
		return queuedResponses.removeFirst()
	}

	func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
		AsyncStream { continuation in
			continuation.finish()
		}
	}

	func startCallCount() -> Int {
		recordedStartCallCount
	}

	func stopCallCount() -> Int {
		recordedStopCallCount
	}
}
