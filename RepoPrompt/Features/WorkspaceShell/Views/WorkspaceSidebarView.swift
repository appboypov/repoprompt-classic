import SwiftUI

/// The workspace list beside the content host: a 220px panel or a 48px rail. Stateless; every event goes up.
struct WorkspaceSidebarView: View {
	static let expandedWidth: CGFloat = 220
	static let collapsedWidth: CGFloat = 48

	let rows: [WorkspaceRowModel]
	let isCollapsed: Bool
	let onSelect: (UUID) -> Void
	let onRename: (UUID) -> Void
	let onRemove: (UUID) -> Void
	let onReorder: ([UUID]) -> Void
	let onAdd: () -> Void
	let onToggleCollapsed: () -> Void

	@ObservedObject private var fontScale = FontScaleManager.shared

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			list
			Divider()
			footer
		}
		.frame(width: isCollapsed ? Self.collapsedWidth : Self.expandedWidth)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	private var header: some View {
		HStack(spacing: 0) {
			if isCollapsed {
				Spacer(minLength: 0)
			} else {
				Text(WorkspaceShellStrings.sidebarTitle)
					.font(fontScale.preset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
					.foregroundColor(.secondary)
					.padding(.leading, 12)
				Spacer(minLength: 0)
			}
			Button(action: onToggleCollapsed) {
				Image(systemName: isCollapsed ? "sidebar.left" : "sidebar.leading")
					.font(.system(size: 12, weight: .medium))
					.frame(width: 24, height: 24)
			}
			.buttonStyle(CustomButtonStyle())
			.hoverTooltip(isCollapsed ? WorkspaceShellStrings.expandSidebar : WorkspaceShellStrings.collapseSidebar, .right)
			if isCollapsed {
				Spacer(minLength: 0)
			}
		}
		.padding(.horizontal, isCollapsed ? 0 : 6)
		.frame(height: 36)
	}

	private var list: some View {
		List {
			ForEach(rows) { row in
				WorkspaceSidebarRow(
					model: row,
					isCollapsed: isCollapsed,
					onSelect: { onSelect(row.id) },
					onRename: { onRename(row.id) },
					onRemove: { onRemove(row.id) }
				)
				.listRowInsets(EdgeInsets(top: 1, leading: isCollapsed ? 0 : 6, bottom: 1, trailing: isCollapsed ? 0 : 6))
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
			}
			.onMove { source, destination in
				var ids = rows.map(\.id)
				ids.move(fromOffsets: source, toOffset: destination)
				onReorder(ids)
			}
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
	}

	private var footer: some View {
		Button(action: onAdd) {
			HStack(spacing: 6) {
				Image(systemName: "plus")
					.font(.system(size: 12, weight: .medium))
				if !isCollapsed {
					Text(WorkspaceShellStrings.addWorkspace)
						.font(fontScale.preset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
						.lineLimit(1)
				}
			}
			.frame(maxWidth: .infinity)
			.frame(height: 28)
		}
		.buttonStyle(CustomButtonStyle())
		.hoverTooltip(isCollapsed ? WorkspaceShellStrings.addWorkspace : nil, .right)
		.padding(isCollapsed ? 4 : 8)
	}
}

#Preview("Sidebar expanded") {
	WorkspaceSidebarView(
		rows: WorkspaceRowModel.previewFixtures, isCollapsed: false,
		onSelect: { _ in }, onRename: { _ in }, onRemove: { _ in }, onReorder: { _ in }, onAdd: {}, onToggleCollapsed: {}
	)
	.frame(height: 360)
}

#Preview("Sidebar collapsed") {
	WorkspaceSidebarView(
		rows: WorkspaceRowModel.previewFixtures, isCollapsed: true,
		onSelect: { _ in }, onRename: { _ in }, onRemove: { _ in }, onReorder: { _ in }, onAdd: {}, onToggleCollapsed: {}
	)
	.frame(height: 360)
}

#Preview("Sidebar empty") {
	WorkspaceSidebarView(
		rows: [], isCollapsed: false,
		onSelect: { _ in }, onRename: { _ in }, onRemove: { _ in }, onReorder: { _ in }, onAdd: {}, onToggleCollapsed: {}
	)
	.frame(height: 360)
}
