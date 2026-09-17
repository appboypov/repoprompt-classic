import AppKit
import Foundation
import os

/// The single handler per shell action. UI, CLI, MCP and deep links all reach the same code here.
/// Mutating actions run one after another on the view model's mutation queue; reads answer at once.
@MainActor
final class WorkspaceShellActionService {
	let viewModel: WorkspaceShellViewModel
	private let windowStatesManager: WindowStatesManager
	private let approvalManager: WorkspaceApprovalManager
	private let logger = Logger(subsystem: "com.repoprompt.workspace", category: "shell")
	private var registry: [WorkspaceShellActionName: (WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot] = [:]

	init(
		viewModel: WorkspaceShellViewModel,
		windowStatesManager: WindowStatesManager = .shared,
		approvalManager: WorkspaceApprovalManager = .shared
	) {
		self.viewModel = viewModel
		self.windowStatesManager = windowStatesManager
		self.approvalManager = approvalManager
		registry = [
			.select: { [unowned self] in try await self.handleSelect($0) },
			.add: { [unowned self] in try await self.handleAdd($0) },
			.rename: { [unowned self] in try await self.handleRename($0) },
			.reorder: { [unowned self] in try await self.handleReorder($0) },
			.remove: { [unowned self] in try await self.handleRemove($0) },
			.setSidebarCollapsed: { [unowned self] in try await self.handleSetSidebarCollapsed($0) },
			.openRoute: { [unowned self] in try await self.handleOpenRoute($0) },
			.capture: { [unowned self] in try await self.handleCapture($0) },
			.state: { [unowned self] _ in self.viewModel.snapshot }
		]
		viewModel.switchForwarder = { [weak self] model in
			guard let self else { return .blocked("Workspace shell is not available") }
			return await self.forwardSwitch(model)
		}
	}

	/// Every action name with a handler; the parity test holds this equal to `WorkspaceShellActionName.allCases`.
	var registeredActionNames: Set<WorkspaceShellActionName> { Set(registry.keys) }

	// MARK: - Dispatch

	func dispatch(_ name: WorkspaceShellActionName, payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		precondition(payload.actionName == name, "payload \(payload.actionName) does not match action \(name)")
		guard let handler = registry[name] else {
			preconditionFailure("no handler registered for \(name)")
		}
		guard name.isMutating else {
			return try await handler(payload)
		}
		return try await enqueue { try await handler(payload) }
	}

	func dispatch(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		try await dispatch(payload.actionName, payload: payload)
	}

	private func enqueue<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
		try await viewModel.serialized(work)
	}

	// MARK: - Handlers

	private func handleSelect(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .select(let select) = payload else { preconditionFailure() }
		logger.debug("select workspaceID=\(select.workspaceID.uuidString, privacy: .public)")
		try await viewModel.select(select.workspaceID)
		viewModel.publish()
		return viewModel.snapshot
	}

	private func handleAdd(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .add(let add) = payload else { preconditionFailure() }
		if case .tool(let clientID) = add.source {
			let result = await approvalManager.requestCreateWorkspaceApproval(
				clientID: clientID,
				workspaceName: add.name,
				windowID: windowStatesManager.shellWindowID
			)
			guard case .approved = result else { throw WorkspaceShellError.approvalDenied }
		}
		let id = try await viewModel.add(name: add.name, folderPath: add.folderPath, makeVisible: add.makeVisible)
		logger.info("add workspaceID=\(id.uuidString, privacy: .public) makeVisible=\(add.makeVisible)")
		viewModel.publish()
		return viewModel.snapshot
	}

	private func handleRename(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .rename(let rename) = payload else { preconditionFailure() }
		try await viewModel.rename(id: rename.workspaceID, name: rename.name)
		logger.info("rename workspaceID=\(rename.workspaceID.uuidString, privacy: .public)")
		viewModel.publish()
		return viewModel.snapshot
	}

	private func handleReorder(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .reorder(let reorder) = payload else { preconditionFailure() }
		try await viewModel.reorder(ids: reorder.workspaceIDs)
		logger.info("reorder count=\(reorder.workspaceIDs.count)")
		viewModel.publish()
		return viewModel.snapshot
	}

	/// Confirms with the user (sidebar) or the approval overlay (tool), stops the runtime's agents, then removes.
	private func handleRemove(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .remove(let remove) = payload else { preconditionFailure() }
		let id = remove.workspaceID
		guard let summary = viewModel.snapshot.workspaces.first(where: { $0.id == id }) else {
			throw WorkspaceShellError.unknownWorkspace(id)
		}
		let workspaceName = summary.name
		let hasRunningAgents = viewModel.runtime(for: id).map { !$0.agentModeViewModel.tabsWithActiveAgentRun.isEmpty } ?? false

		switch remove.source {
		case .user:
			let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
				viewModel.pendingRemoval = RemovalPrompt(
					id: id,
					workspaceName: workspaceName,
					hasRunningAgents: hasRunningAgents,
					resume: { [weak viewModel] confirmed in
						viewModel?.pendingRemoval = nil
						continuation.resume(returning: confirmed)
					}
				)
			}
			guard confirmed else { throw WorkspaceShellError.cancelled }
		case .tool(let clientID):
			let result = await approvalManager.requestDeleteWorkspaceApproval(
				clientID: clientID,
				workspaceName: workspaceName,
				workspaceID: id,
				windowID: windowStatesManager.shellWindowID,
				hasRunningAgents: hasRunningAgents
			)
			guard case .approved = result else {
				throw hasRunningAgents ? WorkspaceShellError.cancelled : WorkspaceShellError.approvalDenied
			}
		}

		logger.info("remove workspaceID=\(id.uuidString, privacy: .public) hasRunningAgents=\(hasRunningAgents)")
		await viewModel.disposeRuntime(for: id, reason: .removal)
		viewModel.publish()
		return viewModel.snapshot
	}

	private func handleSetSidebarCollapsed(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .setSidebarCollapsed(let collapsed) = payload else { preconditionFailure() }
		viewModel.setSidebarCollapsed(collapsed.isCollapsed)
		return viewModel.snapshot
	}

	private func handleOpenRoute(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .openRoute(let route) = payload else { preconditionFailure() }
		NSApp.activate(ignoringOtherApps: true)
		switch route.target {
		case .workspace(let id, let name):
			guard let target = resolveWorkspaceID(id: id, name: name) else {
				logger.debug("openRoute workspace unresolved; activated app only")
				return viewModel.snapshot
			}
			try await viewModel.select(target)
			bringShellWindowToFront()
		case .agentSession(let sessionRoute):
			guard viewModel.snapshot.workspaces.contains(where: { $0.id == sessionRoute.workspaceID }) else {
				logger.debug("openRoute agent session workspace unresolved; activated app only")
				return viewModel.snapshot
			}
			try await viewModel.select(sessionRoute.workspaceID)
			bringShellWindowToFront()
			if let runtime = viewModel.runtime(for: sessionRoute.workspaceID) {
				_ = await runtime.routeToAgentSession(sessionRoute)
			}
		}
		viewModel.publish()
		return viewModel.snapshot
	}

	/// The one rule for capture paths: absolute, `.png`, inside an existing directory. Tool and CLI both pass through here.
	nonisolated static func validateCaptureOutputPath(_ rawPath: String) throws -> URL {
		let expanded = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
		guard expanded.hasPrefix("/") else {
			throw WorkspaceShellError.invalidOutputPath("output_path must be an absolute path.")
		}
		guard expanded.lowercased().hasSuffix(".png") else {
			throw WorkspaceShellError.invalidOutputPath("output_path must end in .png.")
		}
		let parent = (expanded as NSString).deletingLastPathComponent
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw WorkspaceShellError.invalidOutputPath("The directory of output_path does not exist: \(parent)")
		}
		return URL(fileURLWithPath: expanded)
	}

	private func handleCapture(_ payload: WorkspaceShellActionPayload) async throws -> WorkspaceShellSnapshot {
		guard case .capture(let capture) = payload else { preconditionFailure() }
		guard let window = windowStatesManager.shellNSWindow, let content = window.contentView else {
			throw WorkspaceShellError.captureFailed("The shell window has no rendered content")
		}
		let bounds = content.bounds
		guard bounds.width > 0, bounds.height > 0,
			let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
			throw WorkspaceShellError.captureFailed("The shell window has no rendered content")
		}
		content.cacheDisplay(in: bounds, to: rep)
		guard let data = rep.representation(using: .png, properties: [:]), !data.isEmpty else {
			throw WorkspaceShellError.captureFailed("The shell window has no rendered content")
		}
		do {
			try data.write(to: capture.outputPath, options: .atomic)
		} catch {
			logger.error("capture write failed: \(error.localizedDescription, privacy: .public)")
			throw WorkspaceShellError.captureFailed(error.localizedDescription)
		}
		return viewModel.snapshot
	}

	// MARK: - Forwarding and lookup

	/// Legacy switch call sites land here. Selecting the visible workspace is a successful no-op.
	func forwardSwitch(_ model: WorkspaceModel) async -> WorkspaceSwitchResult {
		if model.isSystemWorkspace {
			return .blocked("Exiting to the system workspace is not available in the single-window shell")
		}
		do {
			if viewModel.runtime(for: model.id) == nil, !viewModel.snapshot.workspaces.contains(where: { $0.id == model.id }) {
				_ = try await enqueue { [viewModel] in
					_ = await viewModel.adoptRuntime(for: model)
					return ()
				}
			}
			_ = try await dispatch(.select, payload: .select(SelectWorkspacePayload(workspaceID: model.id)))
			return .switched
		} catch WorkspaceShellError.cancelled {
			return .cancelled("Workspace switch was cancelled")
		} catch {
			return .blocked(error.localizedDescription)
		}
	}

	/// The workspace behind sidebar slot `index` (zero-based, visible rows only).
	func catalogIndex(_ index: Int) -> UUID? {
		let visible = viewModel.snapshot.workspaces.filter { !$0.isHidden }
		guard visible.indices.contains(index) else { return nil }
		return visible[index].id
	}

	/// UUID first, then a unique name match. Ambiguity resolves to nil.
	func resolveWorkspaceID(id: UUID?, name: String?) -> UUID? {
		let workspaces = viewModel.snapshot.workspaces
		if let id, workspaces.contains(where: { $0.id == id }) {
			return id
		}
		guard let name else { return nil }
		let matches = workspaces.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
		return matches.count == 1 ? matches[0].id : nil
	}

	private func bringShellWindowToFront() {
		windowStatesManager.shellNSWindow?.makeKeyAndOrderFront(nil)
	}
}
