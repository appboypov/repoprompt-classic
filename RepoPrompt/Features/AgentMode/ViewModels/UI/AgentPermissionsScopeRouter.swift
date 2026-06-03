//
//  AgentPermissionsScopeRouter.swift
//  RepoPrompt
//
//  Shared router that holds a pending `AgentPermissionSettingsScope` for
//  Agent Permissions deep-links posted from anywhere in the app.
//
//  Motivation: deep-linking into the Agent Permissions settings tab is not
//  always in-window. When a popover in the main Agent Mode sidebar triggers
//  the deep-link, the Settings window may need to be created and the
//  `AgentPermissionsSettingsView` mounted before its `.onReceive` subscription
//  for `.setAgentPermissionsScope` is active. Posting scope immediately on a
//  `DispatchQueue.main.async` race can lose the scope on cold settings-window
//  opens. Instead, callers record the requested scope here and the settings
//  view consumes it on `onAppear`. Existing in-settings-window deep-links
//  (from `AgentModeGeneralSettingsView`) keep using the notification path so
//  they don't need to touch the shared store.
//
//  SEARCH-HELPER: AgentPermissionsScopeRouter, Agent Permissions deep link,
//  pending scope, Sub-Agents deep link, Direct Agents deep link,
//  cold settings window scope race
//
//  Related:
//  - Notification path: /RepoPrompt/Notifications/AppNotifications.swift
//  - Settings view:     /RepoPrompt/Views/Settings/AgentPermissionsSettingsView.swift
//  - Popover caller:    /RepoPrompt/Views/AgentMode/AgentPermissionsPopoverView.swift
//

import Foundation

@MainActor
final class AgentPermissionsScopeRouter: ObservableObject {
	static let shared = AgentPermissionsScopeRouter()

	/// Scope requested by a deep-link caller. Consumed (cleared) by the Agent
	/// Permissions settings view on `onAppear`, so a stale request never
	/// applies to a later, unrelated opening of the tab.
	@Published private(set) var pendingScope: AgentPermissionSettingsScope?

	private init() {}

	/// Record a scope to apply the next time the Agent Permissions tab appears.
	func requestScope(_ scope: AgentPermissionSettingsScope) {
		pendingScope = scope
	}

	/// Consume the pending scope (returning it and clearing storage in one step).
	/// Safe to call when nothing is pending — returns `nil`.
	func consumePendingScope() -> AgentPermissionSettingsScope? {
		let scope = pendingScope
		pendingScope = nil
		return scope
	}

	/// Drop any pending scope without applying it. Call from the caller side
	/// if a flow that set a scope is cancelled before the settings tab opens.
	func clearPendingScope() {
		pendingScope = nil
	}
}
