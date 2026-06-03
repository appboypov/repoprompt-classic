import SwiftUI

/// Always-visible workspace roots section for Agent Mode sidebar.
/// One cohesive rounded card with material background containing:
///   - Workspace header (label, picker, exit)
///   - Folder list with add/remove
///   - Models + Permissions + Settings buttons at the bottom
///
/// SEARCH-HELPER: Agent Mode sidebar bottom bar, Models popover button,
/// Permissions popover button, Agent Mode settings gear, sidebar roots bottom bar
struct AgentWorkspaceRootsSectionView: View {
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var workspaceManager: WorkspaceManagerViewModel
	let promptManager: PromptViewModel
	/// Plain `let` — the roots section forwards the reference into the Models
	/// popover, which reads availability lazily when its menu is opened. The
	/// bottom bar itself does not depend on API settings state.
	let apiSettingsVM: APISettingsViewModel
	let windowID: Int
	let onManageWorkspaces: () -> Void

	@State private var addFolderError: String?
	@State private var hoveredRootID: UUID?
	@State private var showModelsPopover = false
	@State private var showPermissionsPopover = false
	@State private var isAddFolderHovered = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	private static let estimatedFolderRowHeight: CGFloat = 28
	private static let folderListMaxHeight: CGFloat = 118
	private var estimatedFolderRowHeight: CGFloat { fontPreset.scaledMetric(Self.estimatedFolderRowHeight) }
	private var folderListMaxHeight: CGFloat { fontPreset.scaledClamped(Self.folderListMaxHeight, max: 170) }
	private var panelCornerRadius: CGFloat { fontPreset.scaledClamped(16, max: 22) }
	private var panelHorizontalPadding: CGFloat { fontPreset.scaledClamped(6, max: 10) }
	private var panelBottomPadding: CGFloat { fontPreset.scaledClamped(6, max: 10) }
	private var headerHorizontalPadding: CGFloat { fontPreset.scaledClamped(12, max: 18) }
	private var headerTopPadding: CGFloat { fontPreset.scaledClamped(10, max: 14) }
	private var headerBottomPadding: CGFloat { fontPreset.scaledClamped(8, max: 12) }
	private var headerVerticalSpacing: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var headerButtonSpacing: CGFloat { fontPreset.scaledClamped(8, max: 11) }
	private var folderRowSpacing: CGFloat { fontPreset.scaledClamped(2, max: 3) }
	private var folderCardVerticalPadding: CGFloat { fontPreset.scaledClamped(4, max: 6) }
	private var folderCardHorizontalPadding: CGFloat { fontPreset.scaledClamped(2, max: 4) }
	private var rootRowSpacing: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var rootRowHorizontalPadding: CGFloat { fontPreset.scaledClamped(8, max: 12) }
	private var rootRowVerticalPadding: CGFloat { fontPreset.scaledClamped(5, max: 7) }
	private var rootRowCornerRadius: CGFloat { min(estimatedFolderRowHeight / 2, fontPreset.scaledClamped(16, max: 20)) }
	private var addFolderCornerRadius: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var rootIconButtonSize: CGFloat { fontPreset.scaledClamped(20, min: 20, max: 26) }
	private var rootIconButtonIconSize: CGFloat { fontPreset.scaledClamped(9, min: 9, max: 12) }
	private var rootIconButtonCornerRadius: CGFloat { fontPreset.scaledClamped(4, max: 6) }
	private var bottomBarSpacing: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var gearIconSize: CGFloat { fontPreset.scaledClamped(11, max: 14) }
	private var bottomBarHorizontalPadding: CGFloat { fontPreset.scaledClamped(10, max: 14) }
	private var bottomBarBottomPadding: CGFloat { fontPreset.scaledClamped(8, max: 12) }

	private var roots: [FolderViewModel] {
		fileManager.visibleRootFolders
	}

	private var currentWorkspaceLabel: String {
		guard let ws = workspaceManager.activeWorkspace,
				!ws.isSystemWorkspace else { return "No Workspace" }
		let name = ws.name
		return name.count > 16 ? String(name.prefix(16)) + "…" : name
	}

	private var isExitDisabled: Bool {
		workspaceManager.activeWorkspace?.isSystemWorkspace ?? true
	}

	private var estimatedFolderListHeight: CGFloat {
		guard !roots.isEmpty else { return 0 }
		return CGFloat(roots.count) * estimatedFolderRowHeight
			+ CGFloat(max(roots.count - 1, 0)) * folderRowSpacing
	}

	private var shouldScrollFolderList: Bool {
		estimatedFolderListHeight > folderListMaxHeight
	}

	var body: some View {
		VStack(spacing: 0) {
			// ── Header ──────────────────────────────────────
			headerSection
				.padding(.horizontal, headerHorizontalPadding)
				.padding(.top, headerTopPadding)
				.padding(.bottom, headerBottomPadding)

			// ── Folders (add + list) ─────────────────────────
			foldersCard
				.padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
				.padding(.bottom, fontPreset.scaledClamped(6, max: 9))

			// ── Bottom bar: Models + Settings ───────────────
			bottomBar
				.padding(.horizontal, bottomBarHorizontalPadding)
				.padding(.bottom, bottomBarBottomPadding)
		}
		.background(panelBackground)
		.clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
		.shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -2)
		.padding(.horizontal, panelHorizontalPadding)
		.padding(.bottom, panelBottomPadding)
		.alert("Error Adding Folder", isPresented: Binding(
			get: { addFolderError != nil },
			set: { if !$0 { addFolderError = nil } }
		)) {
			Button("OK") { addFolderError = nil }
		} message: {
			if let error = addFolderError {
				Text(error)
			}
		}
	}

	// MARK: - Panel Background

	private var panelBackground: some View {
		ZStack {
			RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
				.fill(.regularMaterial)

			RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
				.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
		}
	}

	// MARK: - Header

	private var headerSection: some View {
		VStack(alignment: .leading, spacing: headerVerticalSpacing) {
			Text("Workspace")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
				.foregroundColor(.secondary)

			HStack(spacing: headerButtonSpacing) {
				workspaceDropdown

				Button(action: {
					Task { await workspaceManager.saveAndExitToFallback() }
				}) {
					HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
						Image(systemName: "rectangle.portrait.and.arrow.right")
						Text("Exit")
							.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
					}
				}
				.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 26))
				.hoverTooltip("Exit Workspace", .top)
				.disabled(isExitDisabled)
				.opacity(isExitDisabled ? 0.5 : 1)

				Spacer()
			}
		}
	}

	// MARK: - Workspace Dropdown

	private var workspaceDropdown: some View {
		WorkspacePickerMenu(
			workspaceManager: workspaceManager,
			onManageWorkspaces: onManageWorkspaces
		) {
			HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
				Text(currentWorkspaceLabel)
					.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
					.lineLimit(1)
				Image(systemName: "chevron.down")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 9))
			}
		}
		.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 26))
		.hoverTooltip("Switch workspace", .top)
	}

	// MARK: - Folders Card

	private var foldersCard: some View {
		VStack(spacing: folderRowSpacing) {
			folderList

			addFolderRow
		}
		.padding(.vertical, folderCardVerticalPadding)
		.padding(.horizontal, folderCardHorizontalPadding)
		.overlay(alignment: .top) {
			Divider().opacity(0.4).padding(.horizontal, fontPreset.scaledClamped(8, max: 12))
		}
	}

	@ViewBuilder
	private var folderList: some View {
		if shouldScrollFolderList {
			ScrollView(.vertical) {
				folderRows
			}
			.frame(maxHeight: folderListMaxHeight)
			.scrollIndicators(.automatic)
		} else {
			folderRows
		}
	}

	private var folderRows: some View {
		VStack(spacing: folderRowSpacing) {
			ForEach(roots, id: \.id) { folder in
				rootRow(folder)
			}
		}
	}

	// MARK: - Add Folder Row

	private var addFolderRow: some View {
		Button(action: {
			Task {
				do {
					try await workspaceManager.pickFolderAndOpenWorkspace(
						title: "Add Folder",
						message: "Choose a folder to add to your workspace.",
						behavior: .addToActiveOrCreateNew
					)
				} catch {
					addFolderError = error.localizedDescription
				}
			}
		}) {
			HStack(spacing: fontPreset.scaledClamped(5, max: 7)) {
				Image(systemName: "plus")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
					.foregroundColor(.secondary)

				Text("Add Folder")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 11))
					.foregroundColor(.secondary)

				Spacer()
			}
			.padding(.horizontal, rootRowHorizontalPadding)
			.padding(.vertical, fontPreset.scaledClamped(4, max: 6))
			.frame(minHeight: estimatedFolderRowHeight)
			.background(
				RoundedRectangle(cornerRadius: addFolderCornerRadius)
					.fill(isAddFolderHovered ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isAddFolderHovered = $0 }
	}

	// MARK: - Root Row

	private var isFirstRoot: UUID? {
		roots.first?.id
	}

	private var isLastRoot: UUID? {
		roots.last?.id
	}

	private func rootRow(_ folder: FolderViewModel) -> some View {
		let isFirst = folder.id == isFirstRoot
		let isLast = folder.id == isLastRoot
		let hasMultipleRoots = roots.count > 1
		let isHovered = hoveredRootID == folder.id

		return HStack(spacing: rootRowSpacing) {
			Image(systemName: "folder.fill")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
				.foregroundColor(.secondary)

			Text(folder.name)
				.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
				.lineLimit(1)
				.truncationMode(.middle)

			if hasMultipleRoots && isFirst {
				Text("PRIMARY")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
					.foregroundColor(.secondary)
					.padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
					.padding(.vertical, fontPreset.scaledClamped(1, max: 2))
					.background(
						Capsule()
							.strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.75)
					)
			}

			Spacer()

			if hasMultipleRoots && isHovered {
				HStack(spacing: fontPreset.scaledClamped(2, max: 3)) {
					RootIconButton(
						systemName: "chevron.up",
						tooltip: "Move up",
						size: rootIconButtonSize,
						iconSize: rootIconButtonIconSize,
						cornerRadius: rootIconButtonCornerRadius
					) {
						fileManager.requestMoveRootFolderUp(path: folder.fullPath)
					}
					.disabled(isFirst)
					.opacity(isFirst ? 0.3 : 1)

					RootIconButton(
						systemName: "chevron.down",
						tooltip: "Move down",
						size: rootIconButtonSize,
						iconSize: rootIconButtonIconSize,
						cornerRadius: rootIconButtonCornerRadius
					) {
						fileManager.requestMoveRootFolderDown(path: folder.fullPath)
					}
					.disabled(isLast)
					.opacity(isLast ? 0.3 : 1)
				}
			}

			RootIconButton(
				systemName: "xmark",
				tooltip: "Remove from workspace",
				size: rootIconButtonSize,
				iconSize: rootIconButtonIconSize,
				cornerRadius: rootIconButtonCornerRadius
			) {
				fileManager.requestUnloadRootFolder(path: folder.fullPath)
			}
			.opacity(isHovered ? 1 : 0)
		}
		.padding(.horizontal, rootRowHorizontalPadding)
		.padding(.vertical, rootRowVerticalPadding)
		.frame(minHeight: estimatedFolderRowHeight)
		.background(
			RoundedRectangle(cornerRadius: rootRowCornerRadius)
				.fill(isHovered ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color.clear)
		)
		.contentShape(Rectangle())
		.onHover { hovered in
			hoveredRootID = hovered ? folder.id : nil
		}
		.hoverTooltip(folder.fullPath, .top)
	}

	// MARK: - Bottom Bar (Models + Permissions + Settings)

	/// Bottom bar for the workspace roots card. Three controls:
	///   - Models popover: Oracle / Plan model, Context Builder agent, sub-agent
	///     role defaults (explore / engineer / pair / design)
	///   - Permissions popover: sub-agent sandbox policy + deep links to the
	///     full Agent Permissions page
	///   - Gear: opens the Agent Mode settings Overview for everything else
	private var bottomBar: some View {
		HStack(spacing: bottomBarSpacing) {
			// Models button (Oracle + Context Builder + Role Defaults)
			Button(action: { showModelsPopover.toggle() }) {
				HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
					Image(systemName: "brain")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 10))
					Text("Models")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
				}
			}
			.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 24))
			.hoverTooltip("Oracle, Context Builder, and sub-agent role models", .top)
			.popover(isPresented: $showModelsPopover, arrowEdge: .trailing) {
				AgentModelsPopoverView(
					promptViewModel: promptManager,
					apiSettingsVM: apiSettingsVM,
					windowID: windowID
				)
			}

			// Permissions button (sub-agent sandbox policy + deep links)
			Button(action: { showPermissionsPopover.toggle() }) {
				HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
					Image(systemName: "lock.shield")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 10))
					Text("Permissions")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
				}
			}
			.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 24))
			.hoverTooltip("Sub-agent sandbox policy and Agent Permissions", .top)
			.popover(isPresented: $showPermissionsPopover, arrowEdge: .trailing) {
				AgentPermissionsPopoverView(
					windowID: windowID
				)
			}

			Spacer()

			// Settings gear — opens Agent Mode Overview for everything else
			Button(action: {
				NotificationCenter.default.post(
					name: .showAgentModeSettingsTab,
					object: nil,
					userInfo: ["windowID": windowID]
				)
			}) {
				Image(systemName: "gearshape")
					.font(.system(size: gearIconSize))
			}
			.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 6, height: 24))
			.hoverTooltip("Agent Mode Settings", .top)
		}
	}
}

// MARK: - Root Icon Button

private struct RootIconButton: View {
	let systemName: String
	let tooltip: String
	let size: CGFloat
	let iconSize: CGFloat
	let cornerRadius: CGFloat
	let action: () -> Void

	@State private var isHovered = false

	var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: iconSize, weight: .semibold))
				.foregroundColor(.secondary)
				.frame(width: size, height: size)
				.contentShape(Rectangle())
				.background(
					RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
						.fill(isHovered ? Color(NSColor.quaternaryLabelColor) : Color.clear)
				)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { isHovered = $0 }
		.hoverTooltip(tooltip, .top)
	}
}
