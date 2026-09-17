import AppKit
import Foundation
import os

/// Lands every incoming URL and notification route in the single-window shell.
/// Scoped routes (agent session, workspace) dispatch `openRoute` on the action service;
/// legacy URLs go to the visible runtime. Until the shell has started, URLs queue on
/// `WindowStatesManager.pendingURLs` in arrival order and `WorkspaceShellViewModel.start()` drains them.
@MainActor
final class AppDeepLinkRouter {
	static let shared = AppDeepLinkRouter()

	private let windowStatesManager: WindowStatesManager
	/// Set once by `RepoPromptApp.init`. Routes dispatch through it once the shell has started.
	private(set) var actionService: WorkspaceShellActionService?
	private let logger = Logger(subsystem: "com.repoprompt.workspace", category: "shell")

	private init() {
		self.windowStatesManager = WindowStatesManager.shared
	}

	init(windowStatesManager: WindowStatesManager, actionService: WorkspaceShellActionService? = nil) {
		self.windowStatesManager = windowStatesManager
		self.actionService = actionService
	}

	func configure(actionService: WorkspaceShellActionService) {
		self.actionService = actionService
	}

	private var startedService: WorkspaceShellActionService? {
		guard let actionService, windowStatesManager.shell?.isStarted == true else { return nil }
		return actionService
	}

	func route(url: URL) async {
		switch AppDeepLinkRoute.parse(url: url) {
		case .unsupported:
			return
		case .invalidScopedRoute:
			NSApp.activate(ignoringOtherApps: true)
		case .route(let route):
			guard let service = startedService else {
				logger.debug("shell not started; queued url \(url.absoluteString, privacy: .public)")
				windowStatesManager.pendingURLs.append(url)
				return
			}
			await dispatch(route, url: url, service: service)
		}
	}

	private func dispatch(_ route: AppDeepLinkRoute, url: URL, service: WorkspaceShellActionService) async {
		switch route {
		case .legacyURL(let legacyURL):
			guard let target = windowStatesManager.visibleWindowState else {
				// Shell started but no runtime is shown yet: keep the url for the next drain.
				logger.debug("no visible runtime yet; queued legacy url \(url.absoluteString, privacy: .public)")
				windowStatesManager.pendingURLs.append(url)
				return
			}
			target.handleIncomingURL(legacyURL)
		case .agentSession(let sessionRoute):
			await openRoute(.agentSession(sessionRoute), service: service)
		case .workspace(let workspaceRoute):
			await openRoute(.workspace(id: workspaceRoute.id, name: workspaceRoute.name), service: service)
		}
	}

	private func openRoute(_ target: OpenRouteTarget, service: WorkspaceShellActionService) async {
		do {
			_ = try await service.dispatch(.openRoute, payload: .openRoute(OpenRoutePayload(target: target)))
		} catch WorkspaceShellError.cancelled {
			logger.debug("openRoute cancelled")
		} catch {
			logger.error("openRoute failed: \(error.localizedDescription, privacy: .public)")
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
		case .workspace, .legacyURL:
			NSApp.activate(ignoringOtherApps: true)
		}
	}

	func route(notificationRoute route: AgentSessionDeepLinkRoute?) async {
		guard let route, let service = startedService else {
			NSApp.activate(ignoringOtherApps: true)
			return
		}
		await openRoute(.agentSession(route), service: service)
	}
}
