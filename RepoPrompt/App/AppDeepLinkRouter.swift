import AppKit
import Foundation

@MainActor
final class AppDeepLinkRouter {
	static let shared = AppDeepLinkRouter()

	private let windowStatesManager: WindowStatesManager

	private init() {
		self.windowStatesManager = WindowStatesManager.shared
	}

	init(windowStatesManager: WindowStatesManager) {
		self.windowStatesManager = windowStatesManager
	}

	func route(url: URL) async {
		await route(url: url, preferredLegacyWindow: nil)
	}

	func route(url: URL, preferredLegacyWindow: WindowState?) async {
		switch AppDeepLinkRoute.parse(url: url) {
		case .route(.legacyURL(let legacyURL)):
			routeLegacyURL(legacyURL, preferredWindow: preferredLegacyWindow)
		case .route(.agentSession(let route)):
			await routeAgentSession(route)
		case .invalidScopedRoute:
			NSApp.activate(ignoringOtherApps: true)
		case .unsupported:
			return
		}
	}

	func route(notificationUserInfo userInfo: [AnyHashable: Any]) async {
		guard let route = AppDeepLinkRoute.parse(notificationUserInfo: userInfo) else {
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		switch route {
		case .agentSession(let agentRoute):
			await self.route(notificationRoute: agentRoute)
		case .legacyURL:
			NSApp.activate(ignoringOtherApps: true)
		}
	}

	func route(notificationRoute route: AgentSessionDeepLinkRoute?) async {
		guard let route else {
			NSApp.activate(ignoringOtherApps: true)
			return
		}
		await routeAgentSession(route)
	}

	private func routeLegacyURL(_ url: URL, preferredWindow: WindowState?) {
		let targetWindow: WindowState?
		if let preferredWindow, !preferredWindow.isClosing {
			targetWindow = preferredWindow
		} else {
			targetWindow = legacyTargetWindow(for: url)
		}

		guard let targetWindow else {
			windowStatesManager.pendingURLs.append(url)
			return
		}
		targetWindow.handleIncomingURL(url)
	}

	private func legacyTargetWindow(for url: URL) -> WindowState? {
		switch Self.legacyWindowPreference(for: url) {
		case .earliest:
			return windowStatesManager.allWindows.first
		case .latest:
			return windowStatesManager.latestWindowState
		}
	}

	private func routeAgentSession(_ route: AgentSessionDeepLinkRoute) async {
		NSApp.activate(ignoringOtherApps: true)
		let liveWindows = windowStatesManager.allWindows.filter { !$0.isClosing }
		var attemptedWindowIDs = Set<Int>()

		for candidate in Self.agentSessionPreferredExistingWindows(for: route, in: liveWindows) {
			attemptedWindowIDs.insert(candidate.windowID)
			let result = await routeAgentSession(route, on: candidate)
			if result == .routed || !Self.shouldTryNextAgentSessionWindow(after: result) {
				return
			}
		}

		for candidate in Self.agentSessionFallbackExistingWindows(for: route, in: liveWindows)
			where !attemptedWindowIDs.contains(candidate.windowID) {
			let result = await routeAgentSession(route, on: candidate)
			if result == .routed || !Self.shouldTryNextAgentSessionWindow(after: result) {
				return
			}
		}
	}

	private func routeAgentSession(_ route: AgentSessionDeepLinkRoute, on targetWindow: WindowState) async -> AgentSessionRouteResult {
		if let window = targetWindow.nsWindow {
			window.makeKeyAndOrderFront(nil)
		} else {
			targetWindow.focusWindowIfPossible()
		}

		return await targetWindow.routeToAgentSession(route)
	}

	@MainActor
	static func agentSessionPreferredExistingWindows(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> [WindowState] {
		var ordered: [WindowState] = []
		var seenWindowIDs = Set<Int>()

		if let windowID = route.windowID,
			let sourceWindow = liveWindows.first(where: { $0.windowID == windowID }) {
			ordered.append(sourceWindow)
			seenWindowIDs.insert(sourceWindow.windowID)
		}

		for window in liveWindows where window.workspaceManager.activeWorkspace?.id == route.workspaceID {
			guard !seenWindowIDs.contains(window.windowID) else { continue }
			ordered.append(window)
			seenWindowIDs.insert(window.windowID)
		}

		return ordered
	}

	@MainActor
	static func agentSessionPreferredExistingWindow(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> WindowState? {
		agentSessionPreferredExistingWindows(for: route, in: liveWindows).first
	}

	@MainActor
	static func agentSessionFallbackExistingWindows(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> [WindowState] {
		liveWindows.filter { window in
			window.workspaceManager.workspace(withID: route.workspaceID) != nil
		}
	}

	@MainActor
	static func agentSessionFallbackExistingWindow(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> WindowState? {
		agentSessionFallbackExistingWindows(for: route, in: liveWindows).first
	}

	nonisolated static func shouldTryNextAgentSessionWindow(after result: AgentSessionRouteResult) -> Bool {
		switch result {
		case .workspaceUnavailable, .workspaceSwitchBlocked, .tabUnavailable:
			return true
		case .routed, .sessionUnavailable, .sessionMismatch, .blockedByActiveDifferentSession:
			return false
		}
	}

	nonisolated static func legacyWindowPreference(for url: URL) -> LegacyWindowPreference {
		if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.host?.lowercased() == "prompt" {
			return .earliest
		}
		return .latest
	}

	enum LegacyWindowPreference: Equatable {
		case earliest
		case latest
	}
}
