//
//  AgentPermissionStorageDiagnosticsViewModel.swift
//  RepoPrompt
//
//  Shared diagnostics model for Agent Permissions settings surfaces.
//

import Foundation
import Combine

@MainActor
final class AgentPermissionStorageDiagnosticsViewModel: ObservableObject {
	/// Diagnostics reported by `AgentPermissionSecureStore`. Sanitized — no raw
	/// Keychain identifiers are exposed to UI consumers.
	@Published private(set) var storageDiagnostics: [AgentPermissionStorageDiagnostic] = []
	/// `true` when secure permission storage reports a failure that forces RepoPrompt
	/// onto safe defaults (read/write/integrity/decode/unsupported schema).
	@Published private(set) var isSecurePermissionStorageDegraded: Bool = false
	@Published private(set) var isResettingAgentPermissions: Bool = false
	@Published private(set) var resetFailureMessage: String?

	let securePermissions: AgentPermissionSecureStore?
	private let notificationCenter: NotificationCenter
	private var cancellables: Set<AnyCancellable> = []

	init(
		securePermissions: AgentPermissionSecureStore?,
		notificationCenter: NotificationCenter = .default
	) {
		self.securePermissions = securePermissions
		self.notificationCenter = notificationCenter
		refresh()
		subscribeToSecureStoreChanges()
	}

	func refresh() {
		let diagnostics = securePermissions?.diagnostics() ?? []
		storageDiagnostics = diagnostics
		isSecurePermissionStorageDegraded = diagnostics.contains { Self.isDegrading(kind: $0.kind) }
		if !isSecurePermissionStorageDegraded {
			resetFailureMessage = nil
		}
	}

	@discardableResult
	func resetAgentPermissionsToSafeDefaults() -> Bool {
		guard let securePermissions else {
			storageDiagnostics = []
			isSecurePermissionStorageDegraded = false
			resetFailureMessage = "Agent Permission storage is unavailable in this context."
			return false
		}

		isResettingAgentPermissions = true
		let result = securePermissions.resetAgentPermissionsToSafeDefaults()
		isResettingAgentPermissions = false
		refresh()

		guard result.succeeded else {
			let failedCount = result.failedDomains.count
			let domainLabel = failedCount == 1 ? "permission domain" : "permission domains"
			resetFailureMessage = "RepoPrompt reset the in-app defaults, but could not save \(failedCount) Agent \(domainLabel) to Keychain. Try again, or check macOS Keychain access."
			return false
		}

		resetFailureMessage = nil
		return true
	}

	/// Which diagnostic kinds force the UI into the degraded banner state.
	/// Informational kinds (`migratedFromLegacy`, `legacyScrubFailed`) do not compromise
	/// safety, so they are excluded from the degraded banner.
	static func isDegrading(kind: AgentPermissionStorageDiagnostic.Kind) -> Bool {
		switch kind {
		case .keychainReadFailed,
			.keychainWriteFailed,
			.decodeFailed,
			.integrityCheckFailed,
			.unsupportedFutureSchema:
			return true
		case .migratedFromLegacy, .legacyScrubFailed:
			return false
		}
	}

	private func subscribeToSecureStoreChanges() {
		notificationCenter.publisher(for: .agentPermissionSecureStoreDidChange)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.refresh()
			}
			.store(in: &cancellables)
	}
}
