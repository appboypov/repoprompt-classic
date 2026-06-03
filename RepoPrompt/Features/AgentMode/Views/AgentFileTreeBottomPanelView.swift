import SwiftUI

/// Bottom panel for Agent mode sidebar containing workspace controls and collapsible file tree
struct AgentFileTreeBottomPanelView: View {
	let windowID: Int
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@ObservedObject var workspaceManager: WorkspaceManagerViewModel
	@Binding var collapsedHeight: CGFloat
	
	let onManageWorkspaces: () -> Void
	
	@State private var isExpanded: Bool = false
	@State private var panelHeight: CGFloat = 320
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	private var minBodyHeight: CGFloat { fontPreset.scaledMetric(150) }
	private var maxBodyHeight: CGFloat { fontPreset.scaledClamped(500, max: 640) }
	private var panelCornerRadius: CGFloat { fontPreset.scaledClamped(16, max: 22) }
	private var headerSpacing: CGFloat { fontPreset.scaledClamped(6, max: 8) }
	private var headerHorizontalPadding: CGFloat { fontPreset.scaledClamped(12, max: 18) }
	private var headerVerticalPadding: CGFloat { fontPreset.scaledClamped(10, max: 14) }
	private var headerRowButtonSpacing: CGFloat { fontPreset.scaledClamped(8, max: 11) }
	private var workspaceDropdownSpacing: CGFloat { fontPreset.scaledClamped(4, max: 6) }
	private var chevronButtonSize: CGFloat { fontPreset.scaledClamped(22, min: 22, max: 28) }
	private var chevronIconSize: CGFloat { fontPreset.scaledClamped(10, min: 10, max: 12) }
	
	var body: some View {
		ExpandableBottomPanel(
			isExpanded: $isExpanded,
			collapsedHeight: $collapsedHeight,
			expandedBodyHeight: $panelHeight,
			minBodyHeight: minBodyHeight,
			maxBodyHeight: maxBodyHeight,
			showsDividerWhenExpanded: true,
			cornerRadius: panelCornerRadius,
			isResizable: true,
			header: { isExpanded, toggle in
				panelHeader(isExpanded: isExpanded, toggle: toggle)
			},
			content: {
				fileTreeContent
			}
		)
	}
	
	// MARK: - Header
	
	private func panelHeader(isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
		VStack(alignment: .leading, spacing: headerSpacing) {
			// Row 1: Workspace label + chevron (tappable row)
			HStack {
				Text("Workspace")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
					.foregroundColor(.secondary)
				
				Spacer()
				
				Button(action: toggle) {
					Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
						.font(.system(size: chevronIconSize, weight: .semibold))
						.foregroundColor(.secondary)
				}
				.buttonStyle(SmallRoundButtonStyle(size: chevronButtonSize, iconSize: chevronIconSize))
				.hoverTooltip(isExpanded ? "Collapse" : "Show files", .top)
			}
			.contentShape(Rectangle())
			.onTapGesture { toggle() }
			
			// Row 2: Workspace dropdown + Exit
			HStack(spacing: headerRowButtonSpacing) {
				workspaceDropdown
				
				Button(action: {
					Task { await workspaceManager.saveAndExitToFallback() }
				}) {
					HStack(spacing: workspaceDropdownSpacing) {
						Image(systemName: "rectangle.portrait.and.arrow.right")
						Text("Exit")
							.font(fontPreset.swiftUIFont(sizeAtNormal: 12))
					}
				}
				.buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 26))
				.hoverTooltip("Exit Workspace", .top)
				
				Spacer()
			}
		}
		.padding(.horizontal, headerHorizontalPadding)
		.padding(.vertical, headerVerticalPadding)
	}
	
	// MARK: - Workspace Dropdown
	
	private var workspaceDropdown: some View {
		WorkspacePickerMenu(
			workspaceManager: workspaceManager,
			onManageWorkspaces: onManageWorkspaces
		) {
			HStack(spacing: workspaceDropdownSpacing) {
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
	
	private var currentWorkspaceLabel: String {
		guard let ws = workspaceManager.activeWorkspace,
			  !ws.isSystemWorkspace else { return "No Workspace" }
		let name = ws.name
		return name.count > 12 ? String(name.prefix(12)) + "…" : name
	}
	
	// MARK: - File Tree Content
	
	private var fileTreeContent: some View {
		FileTreeViewWrapper(
			windowID: windowID,
			fileManager: fileManager,
			workspaceManager: workspaceManager
		)
	}
}
