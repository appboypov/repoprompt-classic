//
//  KeyboardShortcutsSettingsView.swift
//  RepoPrompt
//

import SwiftUI
import KeyboardShortcuts

// MARK: - Catalog

/// Single source of truth for global `KeyboardShortcuts` bindings shown in Settings
/// (actions are registered in `GlobalKeyboardShortcutsCoordinator`).
enum KeyboardShortcutCatalog {
	static let sections: [KeyboardShortcutCatalogSection] = [
		KeyboardShortcutCatalogSection(
			id: "agent-layout",
			title: "Agent & layout",
			blurb: "Agent shortcuts apply when a real workspace is open. New chat matches the titlebar New Session button.",
			bindings: [
				.init(id: "agent-new", title: "New Agent chat", detail: nil, name: .agentNewChat),
				.init(id: "toggle-mode", title: "Switch IDE / Agent mode", detail: "Switch between IDE and Agent mode.", name: .toggleAgentIDEMode),
				.init(id: "toggle-sidebar", title: "Toggle sidebar", detail: "File tree in IDE mode; session list in Agent mode.", name: .toggleNavigationSidebar)
			]
		),
		KeyboardShortcutCatalogSection(
			id: "workspace-presets",
			title: "Workspace & presets",
			blurb: "Save and navigate the active workspace. Preset shortcuts jump to the numbered preset in the workspace manager.",
			bindings: workspaceAndPresetBindings
		),
		KeyboardShortcutCatalogSection(
			id: "compose-tabs",
			title: "Compose tabs",
			blurb: "Manage instruction compose tabs. In Agent mode, ⌘1–9 follow the session sidebar order when it differs from tab order.",
			bindings: composeBindings
		),
		KeyboardShortcutCatalogSection(
			id: "display",
			title: "Display",
			blurb: "Adjust prompt and transcript text size globally.",
			bindings: [
				.init(id: "font-up", title: "Increase font size", detail: nil, name: .increaseFontScale),
				.init(id: "font-down", title: "Decrease font size", detail: nil, name: .decreaseFontScale)
			]
		),
		KeyboardShortcutCatalogSection(
			id: "file-tree",
			title: "File tree",
			blurb: "Applies to the IDE file tree for the focused window.",
			bindings: [
				.init(id: "collapse-all", title: "Toggle collapse / expand all folders", detail: nil, name: .cmdOptionC)
			]
		)
	]

	private static var workspaceAndPresetBindings: [KeyboardShortcutCatalogBinding] {
		var rows: [KeyboardShortcutCatalogBinding] = [
			.init(id: "save-ws", title: "Save workspace", detail: nil, name: .cmdS),
			.init(id: "save-exit", title: "Save workspace and switch to system workspace", detail: nil, name: .cmdShiftS),
			.init(id: "save-preset-or-create", title: "Save current preset (or create preset if none)", detail: nil, name: .cmdOptionS),
			.init(id: "create-preset", title: "Create new preset", detail: nil, name: .cmdOptionP)
		]
		let presetNames: [KeyboardShortcuts.Name] = [
			.switchToPreset1, .switchToPreset2, .switchToPreset3, .switchToPreset4, .switchToPreset5,
			.switchToPreset6, .switchToPreset7, .switchToPreset8, .switchToPreset9
		]
		for index in 0..<9 {
			let n = index + 1
			rows.append(
				KeyboardShortcutCatalogBinding(
					id: "preset-\(n)",
					title: "Switch to preset \(n)",
					detail: nil,
					name: presetNames[index]
				)
			)
		}
		return rows
	}

	private static var composeBindings: [KeyboardShortcutCatalogBinding] {
		var rows: [KeyboardShortcutCatalogBinding] = [
			.init(id: "compose-new", title: "New compose tab", detail: nil, name: .newComposeTab),
			.init(id: "compose-close", title: "Close active compose tab", detail: nil, name: .closeComposeTab),
			.init(id: "compose-next", title: "Next compose tab", detail: nil, name: .nextComposeTab),
			.init(id: "compose-prev", title: "Previous compose tab", detail: nil, name: .previousComposeTab)
		]
		let tabNames: [KeyboardShortcuts.Name] = [
			.switchToComposeTab1, .switchToComposeTab2, .switchToComposeTab3, .switchToComposeTab4, .switchToComposeTab5,
			.switchToComposeTab6, .switchToComposeTab7, .switchToComposeTab8, .switchToComposeTab9
		]
		for index in 0..<9 {
			let n = index + 1
			rows.append(
				KeyboardShortcutCatalogBinding(
					id: "compose-tab-\(n)",
					title: "Focus compose tab \(n)",
					detail: nil,
					name: tabNames[index]
				)
			)
		}
		return rows
	}
}

struct KeyboardShortcutCatalogSection: Identifiable {
	let id: String
	let title: String
	let blurb: String
	let bindings: [KeyboardShortcutCatalogBinding]
}

struct KeyboardShortcutCatalogBinding: Identifiable {
	let id: String
	let title: String
	let detail: String?
	let name: KeyboardShortcuts.Name
}

// MARK: - Settings view

struct KeyboardShortcutsSettingsView: View {
	// Canonical storage lives in GlobalSettingsStore; the legacy
	// `enableKeyboardShortcuts` UserDefaults key is mirrored during the
	// rollback window so non-settings consumers keep observing the same
	// value (e.g. `WindowStateManager` still reads the raw key).
	@ObservedObject private var globalSettings = GlobalSettingsStore.shared

	private var enableKeyboardShortcuts: Bool {
		globalSettings.enableKeyboardShortcuts()
	}

	private var enableKeyboardShortcutsBinding: Binding<Bool> {
		Binding(
			get: { globalSettings.enableKeyboardShortcuts() },
			set: { globalSettings.setEnableKeyboardShortcuts($0) }
		)
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				SettingSection(
					title: "Keyboard Shortcuts",
					description: "Customize global hotkeys. Bindings are stored per-app; conflicts with the menu bar or other apps may prevent shortcuts from firing."
				) {
					SettingToggle(
						title: "Enable keyboard shortcuts",
						description: "When disabled, none of these shortcuts run (your custom bindings stay saved).",
						isOn: enableKeyboardShortcutsBinding
					)
				}

				if !enableKeyboardShortcuts {
					Text("Turn on “Enable keyboard shortcuts” to use the bindings below.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}

				ForEach(KeyboardShortcutCatalog.sections) { section in
					Divider()
						.padding(.horizontal, -16)

					SettingSection(title: section.title, description: section.blurb) {
						VStack(alignment: .leading, spacing: 10) {
							ForEach(section.bindings) { binding in
								ShortcutPreferenceRow(
									title: binding.title,
									subtitle: binding.detail,
									shortcut: binding.name
								)
								.opacity(enableKeyboardShortcuts ? 1 : 0.45)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
					}
				}

				Spacer()
			}
			.padding()
			.frame(maxWidth: .infinity, alignment: .topLeading)
		}
	}
}

// MARK: - Row

struct ShortcutPreferenceRow: View {
	let title: String
	var subtitle: String? = nil
	let shortcut: KeyboardShortcuts.Name

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(alignment: .firstTextBaseline) {
				Text(title)
					.frame(minWidth: 220, alignment: .leading)
				Spacer(minLength: 12)
				KeyboardShortcuts.Recorder(for: shortcut)
			}
			if let subtitle, !subtitle.isEmpty {
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}
