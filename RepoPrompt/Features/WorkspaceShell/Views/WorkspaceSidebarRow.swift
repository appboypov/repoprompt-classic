import SwiftUI

/// One workspace in the sidebar: a dense row when expanded, an initials tile when collapsed.
struct WorkspaceSidebarRow: View {
	let model: WorkspaceRowModel
	let isCollapsed: Bool
	let onSelect: () -> Void
	let onRename: () -> Void
	let onRemove: () -> Void

	@ObservedObject private var fontScale = FontScaleManager.shared
	@State private var isHovering = false

	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		Button(action: onSelect) {
			Group {
				if isCollapsed {
					collapsedBody
				} else {
					expandedBody
				}
			}
			.contentShape(RoundedRectangle(cornerRadius: 6))
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(backgroundColor)
			)
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.contextMenu {
			Button(WorkspaceShellStrings.rename, action: onRename)
			Button(WorkspaceShellStrings.remove, role: .destructive, action: onRemove)
		}
		.accessibilityLabel(model.name)
		.accessibilityAddTraits(model.isVisible ? .isSelected : [])
	}

	private var backgroundColor: Color {
		if model.isVisible { return Color.accentColor.opacity(0.12) }
		if isHovering { return Color.secondary.opacity(0.1) }
		return .clear
	}

	private var expandedBody: some View {
		HStack(spacing: 8) {
			initialsTile(size: 24, fontSize: 9)
			VStack(alignment: .leading, spacing: 1) {
				Text(model.name)
					.font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: model.isVisible ? .semibold : .regular))
					.foregroundColor(.primary)
					.lineLimit(1)
					.truncationMode(.tail)
				Text(WorkspaceShellStrings.folderCount(model.rootCount))
					.font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .regular))
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 4)
			HStack(spacing: 6) {
				if model.hasRunningAgents {
					WorkspaceBadge(kind: .runningAgent, size: .label)
				}
				if !model.isAvailable {
					WorkspaceBadge(kind: .unavailable, size: .label)
				}
			}
			.fixedSize()
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var collapsedBody: some View {
		initialsTile(size: 32, fontSize: 12)
			.overlay(alignment: .topTrailing) {
				HStack(spacing: -3) {
					if !model.isAvailable {
						WorkspaceBadge(kind: .unavailable, size: .dot)
					}
					if model.hasRunningAgents {
						WorkspaceBadge(kind: .runningAgent, size: .dot)
					}
				}
				.offset(x: 3, y: -3)
			}
			.padding(.vertical, 4)
			.frame(maxWidth: .infinity)
			.hoverTooltip(WorkspaceShellStrings.rowTooltip(name: model.name, rootCount: model.rootCount), .right)
	}

	private func initialsTile(size: CGFloat, fontSize: CGFloat) -> some View {
		Text(model.initials)
			.font(fontPreset.swiftUIFont(sizeAtNormal: fontSize, weight: .semibold))
			.foregroundColor(model.isVisible ? .accentColor : .secondary)
			.frame(width: size, height: size)
			.background(
				RoundedRectangle(cornerRadius: size / 4, style: .continuous)
					.fill(model.isVisible ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
			)
			.opacity(model.isAvailable ? 1 : 0.6)
	}
}

extension WorkspaceRowModel {
	/// Preview fixtures covering every row state.
	static let previewFixtures: [WorkspaceRowModel] = [
		WorkspaceRowModel(name: "Repo Prompt", rootCount: 2, isVisible: true),
		WorkspaceRowModel(name: "Shared Kernel Library", rootCount: 1),
		WorkspaceRowModel(name: "Archived Client Site", rootCount: 3, isAvailable: false),
		WorkspaceRowModel(name: "Agents", rootCount: 5, hasRunningAgents: true)
	]
}

#Preview("Rows expanded") {
	VStack(spacing: 2) {
		ForEach(WorkspaceRowModel.previewFixtures) { model in
			WorkspaceSidebarRow(model: model, isCollapsed: false, onSelect: {}, onRename: {}, onRemove: {})
		}
	}
	.frame(width: 220)
	.padding(8)
}

#Preview("Rows collapsed") {
	VStack(spacing: 2) {
		ForEach(WorkspaceRowModel.previewFixtures) { model in
			WorkspaceSidebarRow(model: model, isCollapsed: true, onSelect: {}, onRename: {}, onRemove: {})
		}
	}
	.frame(width: 48)
	.padding(.vertical, 8)
}
