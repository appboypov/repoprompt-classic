import SwiftUI
import os

/// The one window's content: sidebar beside the content host, the app-wide approval overlays on top,
/// and the add, rename and remove sheets. Every sidebar event dispatches through the action service.
struct WorkspaceShellRootView: View {
	@ObservedObject var shellViewModel: WorkspaceShellViewModel
	let actionService: WorkspaceShellActionService
	@ObservedObject private var workspaceApprovalManager = WorkspaceApprovalManager.shared

	@State private var isAddSheetPresented = false
	@State private var renameTarget: WorkspaceRowModel?
	// Toolbar popover state lives here so it survives toolbar re-evaluation.
	@State private var showMCPServerPopover = false
	@State private var showRecommendationsPopover = false

	private let logger = Logger(subsystem: "com.repoprompt.workspace", category: "shell")

	var body: some View {
		ZStack {
			HStack(spacing: 0) {
				WorkspaceSidebarView(
					rows: shellViewModel.snapshot.workspaces.map(WorkspaceRowModel.init(summary:)),
					isCollapsed: shellViewModel.snapshot.isWorkspaceSidebarCollapsed,
					onSelect: { id in dispatch(.select(SelectWorkspacePayload(workspaceID: id))) },
					onRename: { id in
						renameTarget = shellViewModel.snapshot.workspaces.first(where: { $0.id == id }).map(WorkspaceRowModel.init(summary:))
					},
					onRemove: { id in dispatch(.remove(RemoveWorkspacePayload(workspaceID: id, source: .user))) },
					onReorder: { ids in dispatch(.reorder(ReorderWorkspacesPayload(workspaceIDs: ids))) },
					onAdd: { isAddSheetPresented = true },
					onToggleCollapsed: {
						dispatch(.setSidebarCollapsed(SetSidebarCollapsedPayload(isCollapsed: !shellViewModel.snapshot.isWorkspaceSidebarCollapsed)))
					}
				)
				Divider()
				WorkspaceContentHostView(shellViewModel: shellViewModel, onAdd: { isAddSheetPresented = true })
			}

			// The host runtime mirrors the shared MCP approval stream, so it answers for the whole app.
			if let host = shellViewModel.hostRuntime {
				MCPApprovalHostView(server: host.mcpServer)
					.zIndex(1000)
			}

			if let request = workspaceApprovalManager.pendingRequest, workspaceApprovalManager.isApprovalOverlayVisible {
				WorkspaceApprovalOverlayView(approvalManager: workspaceApprovalManager, request: request)
					.transition(.opacity.combined(with: .scale(scale: 0.95)))
					.zIndex(1001)
			}
		}
		.background(WindowAccessor { window in
			guard let window else { return }
			shellViewModel.attachNativeWindow(window)
		})
		.toolbar {
			if let runtime = shellViewModel.contentRuntime {
				WorkspaceRuntimeToolbar(
					windowState: runtime,
					showMCPServerPopover: $showMCPServerPopover,
					showRecommendationsPopover: $showRecommendationsPopover
				)
			}
		}
		.onChange(of: shellViewModel.contentRuntime?.windowID) { _, _ in
			// Popovers belong to the runtime they opened on; a switch closes them.
			showMCPServerPopover = false
			showRecommendationsPopover = false
		}
		.onReceive(NotificationCenter.default.publisher(for: .showMCPServerPopover)) { note in
			guard targetsShownRuntime(note) else { return }
			showMCPServerPopover = true
		}
		.onReceive(NotificationCenter.default.publisher(for: .showRecommendationWizard)) { note in
			guard targetsShownRuntime(note) else { return }
			shellViewModel.contentRuntime?.recommendationWizardViewModel.refresh(navigation: .resetToIntro)
			showRecommendationsPopover = true
		}
		.sheet(isPresented: $isAddSheetPresented) {
			WorkspaceAddSheet(
				onAdd: { name, folderPath in
					isAddSheetPresented = false
					dispatch(.add(AddWorkspacePayload(name: name, folderPath: folderPath, makeVisible: true, source: .user)))
				},
				onCancel: { isAddSheetPresented = false }
			)
		}
		.sheet(item: $renameTarget) { target in
			WorkspaceRenameSheet(
				currentName: target.name,
				onSave: { name in
					renameTarget = nil
					dispatch(.rename(RenameWorkspacePayload(workspaceID: target.id, name: name)))
				},
				onCancel: { renameTarget = nil }
			)
		}
		.sheet(item: Binding(get: { shellViewModel.pendingRemoval }, set: { _ in })) { prompt in
			WorkspaceRemoveConfirmationView(
				workspaceName: prompt.workspaceName,
				hasRunningAgents: prompt.hasRunningAgents,
				onConfirm: { prompt.resume(true) },
				onCancel: { prompt.resume(false) }
			)
			.interactiveDismissDisabled()
		}
	}

	/// A notification without a window id targets the shown runtime; one with an id must match it.
	/// Without a shown runtime there is no toolbar to anchor a popover, so nothing is latched.
	private func targetsShownRuntime(_ note: Notification) -> Bool {
		guard let shown = shellViewModel.contentRuntime else { return false }
		guard let id = note.userInfo?["windowID"] as? Int else { return true }
		return id == shown.windowID
	}

	private func dispatch(_ payload: WorkspaceShellActionPayload) {
		Task { @MainActor in
			do {
				_ = try await actionService.dispatch(payload)
			} catch WorkspaceShellError.cancelled {
				// The user backed out of a confirmation.
			} catch {
				logger.error("\(payload.actionName.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
}

/// Observes the host's MCP server and shows the client approval overlay when a request is pending.
private struct MCPApprovalHostView: View {
	@ObservedObject var server: MCPServerViewModel

	var body: some View {
		if let clientID = server.pendingClientID, server.isApprovalOverlayVisible {
			MCPApprovalOverlayView(clientID: clientID)
				.environmentObject(server)
				.transition(.opacity.combined(with: .scale(scale: 0.95)))
		}
	}
}
