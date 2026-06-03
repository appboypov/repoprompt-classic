//
//  ServerController.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//


import Foundation
import SwiftUI
import AppKit
import OSLog
import Logging
import Darwin

#if DEBUG
private var serverControllerDebugLoggingEnabled = false
private func serverControllerDebugLog(_ message: @autoclosure () -> String) {
	guard serverControllerDebugLoggingEnabled else { return }
	print("[ServerController] \(message())")
}
#else
private func serverControllerDebugLog(_ message: @autoclosure () -> String) {}
#endif

private let log = Logger(label: "com.repoprompt.mcp.servercontroller")

// ---------------------------------------------------------------------
//  SwiftUI facing controller – own instance lives at the app level
// ---------------------------------------------------------------------
/// Controller visible from SwiftUI
final actor ServerController: ObservableObject {

    // ──────────  Singleton  ──────────
    static let shared = ServerController()

	// –––––  Internal state (no longer @Published since we're not on @MainActor)  –––––
	private var serverStatus      : String  = "Starting…"
	private var pendingConnectionID: String?
	weak var mcpService: MCPService?
    

    @AppStorage("mcpLaunchAllowed") private var launchAllowed = true

    // ──────────  NEW: persistent allow-list of client IDs  ──────────
    private static let alwaysAllowedKey = "mcp.alwaysAllowedClients"
	/// Built-in always-allowed clients (do not require manual approval).
	private static let defaultAlwaysAllowedClients: Set<String> = [
		"claude-code",
		"codex-mcp-client",
		"gemini-cli-mcp-client",
		"cursor",
		"cursor-mcp-client",
		"claude-ai"
	]
    /// In-memory copy (always mutate on MainActor)
    private var alwaysAllowedClients: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: alwaysAllowedKey) ?? []
        return Set(saved).union(ServerController.defaultAlwaysAllowedClients)
    }()

    // –––––  Private implementation helpers  –––––
    private let networkManager = ServerNetworkManager.shared
    private var activeApprovalDialogs : Set<String> = []
    private var pendingApprovals      : [(String, () -> Void, () -> Void)] = []
    
    // –––––  Injected callbacks for approval flow  –––––
    nonisolated(unsafe) var onApprovalRequest  : ((String) async -> Void)?
    nonisolated(unsafe) var onApprovalResolved : ((Bool) -> Void)?

	/// Activity token used to disable App Nap while the server runs.
	private var powerActivity: NSObjectProtocol?
	private var wakeObserver: NSObjectProtocol?
    
	/// Set the approval callback
	func setApprovalCallback(_ callback: @escaping (String) async -> Void) {
		onApprovalRequest = callback
	}
	
	func setMCPService(_ service: MCPService?) {
		mcpService = service
	}
	
	// –––––  Init: wire approval-flow & kick off the listener  –––––
	init() {
		Task { [weak self] in
			await self?.bootstrapCallbacks()
		}
    }

	private func bootstrapCallbacks() async {
		// Wire up dashboard update callback to notify MCPService
		await ServerNetworkManager.shared.setOnDashboardUpdate { [weak self] in
			guard let self else { return }
			Task {
				guard let service = await self.mcpService else { return }
				await service.notifyDashboardUpdate()
			}
		}

		// Wire up identity escalation callback
		await ServerNetworkManager.shared.setOnIdentityEscalation { [weak self] reason in
			guard let self else { return }
			Task {
				guard let service = await self.mcpService else { return }
				let diag = MCPDiagnostics(
					issue: .identityRecoveryDegraded(message: reason),
					lastEventAt: Date(),
					listenerStateDescription: "Bootstrap socket connection issue"
				)
				await service.updateDiagnostics(diag)
			}
		}

		// Set up approval handler
		await networkManager.setConnectionApprovalHandler { [weak self]
			connectionID, client in
			guard let self else { return false }

			serverControllerDebugLog("Approval handler called for client: '\(client.name)' connectionID: \(connectionID)")

			// Reserve a slot BEFORE any UI to avoid stampedes
			guard await self.networkManager.tryReserveConnectionSlot(
				connectionID: connectionID, clientID: client.name
			) else {
				log.warning("Failed to reserve connection slot for '\(client.name)'")
				return false
			}

			// Global auto-approve: skip UI for all new clients
			if await self.autoApproveAllClients {
				serverControllerDebugLog("Auto-approving '\(client.name)' (global auto-approve enabled)")
				if let service = await self.mcpService {
					await service.clientConnectedSuccessfully(name: client.name)
				}
				return true
			}

			// Per-client auto-approve when whitelisted
			if await self.isClientAlwaysAllowed(clientID: client.name) {
				serverControllerDebugLog("Auto-approving '\(client.name)' (in allow-list)")
				if let service = await self.mcpService {
					await service.clientConnectedSuccessfully(name: client.name)
				}
				return true
			}

			// Built-in auto-approve for RepoPrompt's own CLI clients.
			//
			// SECURITY NOTE: This trusts the MCP clientInfo.name from the initialize request,
			// which can be spoofed by any local process connecting to the socket. This is
			// acceptable under a same-user trust model (all processes running as the same
			// user are trusted). For stronger security, consider validating the connecting
			// process via:
			//   - proc_pidpath() to verify executable path matches our CLI binary
			//   - SecCodeCopyGuestWithAttributes() to verify code signature/team ID
			//   - LOCAL_PEERCRED / audit token on the unix socket
			//
			// The prefix match allows versioned CLI names like "RepoPrompt CLI 1.2.3".
			let isRepoCLI = client.name.hasPrefix("RepoPrompt CLI")
			if isRepoCLI, await self.isBundledRepoPromptCLIConnection(connectionID: connectionID) {
				serverControllerDebugLog("Auto-approving '\(client.name)' (RepoPrompt bundled CLI verified)")
				if let service = await self.mcpService {
					await service.clientConnectedSuccessfully(name: client.name)
				}
				return true
			} else if isRepoCLI {
				log.warning("RepoPrompt CLI name matched but executable path verification failed for connectionID=\(connectionID)")
			}

			// Otherwise request approval through the callback
			let approved = await withCheckedContinuation { c in
				Task {
					await self.requestApproval(
						clientID: client.name,
						approve: { c.resume(returning: true) },
						deny: { c.resume(returning: false) }
					)
				}
			}
			if !approved {
				await self.networkManager.terminateConnection(
					connectionID,
					reason: .approvalDenied,
					message: "Denied by user"
				)
			} else {
				// Client manually approved - clear any previous errors for this client
				if let service = await self.mcpService {
					await service.clientConnectedSuccessfully(name: client.name)
				}
			}
			return approved
		}

		// Register wake observer if not already registered
		guard wakeObserver == nil else { return }
		let networkMgr = networkManager
		let observer = await MainActor.run {
			NSWorkspace.shared.notificationCenter.addObserver(
				forName: NSWorkspace.didWakeNotification,
				object: nil,
				queue: nil
			) { _ in
				Task {
					await networkMgr.ensureBootstrapHealthy(force: true)
				}
			}
		}
		wakeObserver = observer
	}
	
	deinit {
		// No cleanup needed - callbacks are weak self
    }

    // MARK: – Allow-list helpers –

	/// Checks if a client is in the always-allowed list.
    ///
    /// Supports both exact matches and prefix matches. Prefix matching allows entries
    /// like "gemini-cli" to match "gemini-cli-mcp-client" or versioned variants.
    ///
    /// NOTE: Prefix matching broadens what gets auto-approved. Consider making this
    /// opt-in per entry if stricter control is needed in the future.
	private func isClientAlwaysAllowed(clientID: String) -> Bool {
		if isDefaultAlwaysAllowed(clientID) {
			return true
		}
		if alwaysAllowedClients.contains(where: { MCPClientIdentity.matches($0, clientID) }) {
			return true
		}
		return false
	}
	
	private func isDefaultAlwaysAllowed(_ clientID: String) -> Bool {
		Self.defaultAlwaysAllowedClients.contains(where: { MCPClientIdentity.matches($0, clientID) })
	}

	/// Returns true iff the connecting process matches the app-bundled `repoprompt-mcp` executable.
	private func isBundledRepoPromptCLIConnection(connectionID: UUID) async -> Bool {
		guard let expectedURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") else {
			return false
		}
		guard let peerPID = await networkManager.peerPID(for: connectionID) else {
			return false
		}
		guard let actualPath = Self.executablePath(forPID: peerPID) else {
			return false
		}
		let expected = expectedURL.resolvingSymlinksInPath().standardizedFileURL.path
		let actual = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().standardizedFileURL.path
		return actual == expected
	}

	private nonisolated static func executablePath(forPID pid: Int) -> String? {
		var buffer = [CChar](repeating: 0, count: 4096)
		let result = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
		guard result > 0 else { return nil }
		return String(cString: buffer)
	}

    private func addAlwaysAllowed(clientID: String) {
        guard !alwaysAllowedClients.contains(where: { MCPClientIdentity.matches($0, clientID) }) else { return }
        alwaysAllowedClients.insert(clientID)
        UserDefaults.standard.set(Array(alwaysAllowedClients),
                                  forKey: Self.alwaysAllowedKey)
    }

	// MARK: - Dashboard & Auto-Approve Management
	
	/// Returns the list of always-allowed client IDs
	func alwaysAllowedClientIDs() -> [String] {
		var seen = Set<String>()
		var values: [String] = []
		for clientID in alwaysAllowedClients.sorted() {
			let dedupeKey = MCPClientIdentity.storageKey(clientID) ?? clientID
			guard seen.insert(dedupeKey).inserted else { continue }
			values.append(clientID)
		}
		return values
    }
	
	/// Add or remove a client from the persistent allow-list
	func setAlwaysAllowed(clientID: String, allowed: Bool) async {
		if !allowed, isDefaultAlwaysAllowed(clientID) {
			return
		}
        if allowed {
			addAlwaysAllowed(clientID: clientID)
        } else {
			alwaysAllowedClients = alwaysAllowedClients.filter {
				!MCPClientIdentity.matches($0, clientID) || isDefaultAlwaysAllowed($0)
			}
			UserDefaults.standard.set(Array(alwaysAllowedClients),
									forKey: Self.alwaysAllowedKey)
        }
		// Notify dashboard to refresh the UI
		await mcpService?.notifyDashboardUpdate()
    }
	
	/// Key for auto-approve all clients setting
	private static let autoApproveAllClientsKey = "mcpAutoApproveAllClients"
	
	/// Whether to auto-approve all new clients without user confirmation
	private var autoApproveAllClients: Bool {
		get { UserDefaults.standard.bool(forKey: Self.autoApproveAllClientsKey) }
		set { UserDefaults.standard.set(newValue, forKey: Self.autoApproveAllClientsKey) }
	}
	
	func getAutoApproveAllClients() -> Bool {
		autoApproveAllClients
    }
    
	func setAutoApproveAllClients(_ enabled: Bool) async {
		autoApproveAllClients = enabled
		// Notify dashboard to refresh the UI
		await mcpService?.notifyDashboardUpdate()
    }
    
	/// Forcefully disconnect a specific connection (legacy - use terminateConnection instead)
	func bootConnection(id: UUID) async {
		await terminateConnection(id: id, reason: .userBootFromDashboard)
    }
    
	/// Terminates a connection with explicit kill semantics.
	/// CLI will exit without retrying.
	func terminateConnection(id: UUID, reason: TerminationReason, message: String? = nil) async {
		await networkManager.terminateConnection(id, reason: reason, message: message)
	}
    
	/// Snapshot of the server state for dashboard display
	struct ServerDashboardSnapshot: Sendable {
		let serverStatus: String
		let diagnostics: MCPDiagnostics
		let connections: NetworkDashboardSnapshot
		let alwaysAllowedClients: [String]
		let autoApproveAllClients: Bool
    }
    
	/// Returns a complete dashboard snapshot
	func dashboardSnapshot(currentDiagnostics: MCPDiagnostics) async -> ServerDashboardSnapshot {
		let connSnapshot = await networkManager.dashboardSnapshot()
		return ServerDashboardSnapshot(
			serverStatus: serverStatus,
			diagnostics: currentDiagnostics,
			connections: connSnapshot,
			alwaysAllowedClients: alwaysAllowedClientIDs(),
			autoApproveAllClients: autoApproveAllClients
		)
	}

    // MARK: – public API –
    /// Request to start (or re-enable) the MCP listener.
    func startServer() async {
        guard launchAllowed else {
            updateServerStatus("Disabled")
            return
        }

        if await networkManager.isRunning() {
            await networkManager.setEnabled(true)            // expose tools only
			await networkManager.ensureBootstrapHealthy(force: true)
        } else {
            await networkManager.start()                     // cold start once
        }
        beginPowerActivity()
        updateServerStatus("Running")
    }

    /// Disable the listener.
    func stopServer() async {
        await networkManager.setEnabled(false)
        endPowerActivity()
        updateServerStatus("Disabled")
    }

    /// Completely shut down the listener.
    func fullShutdown() async {
        await networkManager.stop()
        endPowerActivity()
        updateServerStatus("Stopped")
    }

    /// Global preference toggled from Settings → "Allow MCP server"
    func setLaunchAllowed(_ allowed: Bool) async {
        launchAllowed = allowed
        if allowed {
            await startServer()
        } else {
            await fullShutdown()
        }
    }

    // This method will be used to enable/disable all tools at once.
    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        if enabled {
            beginPowerActivity()
			await networkManager.ensureBootstrapHealthy(force: true)
        } else {
            endPowerActivity()
        }
        updateServerStatus(enabled ? "Running" : "Disabled")
    }
    
    // This is no longer needed as there are no individual service toggles.
    // func updateServiceBindings(_ b: [String: Binding<Bool>]) async {
    //     await networkManager.updateServiceBindings(b)
    // }

    // MARK: – helpers ––––––––––––––––––––––––––––––––––––––––––––––––––
    
	/// Timeout for approval dialogs (auto-deny after this duration)
	private let approvalTimeout: TimeInterval = 300
	/// Monotonic generation for the active approval request.
	/// Prevents stale timeout tasks from auto-denying a newer request.
	private var approvalGeneration: UInt64 = 0
	/// Timeout watchdog for the currently active approval request.
	/// Cancelled when approval resolves or is superseded.
	private var approvalTimeoutTask: Task<Void, Never>?
    
    private func updateServerStatus(_ s: String) {
        serverControllerDebugLog("Server status ➜ \(s)")
        serverStatus = s
    }
    
    private func beginPowerActivity() {
        guard powerActivity == nil else { return }
        powerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Maintain realtime MCP server connection"
        )
    }
    
    private func endPowerActivity() {
        guard let activity = powerActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        powerActivity = nil
    }

	/// Request approval through the callback system instead of showing NSAlert directly.
	/// Approval requests are handled in strict FIFO order: exactly one active request at a time.
	private func requestApproval(
		clientID: String,
		approve : @escaping () -> Void,
		deny    : @escaping () -> Void
	) async {
		// Single-flight guard: queue while another approval is active.
		if currentApprovalCallbacks != nil {
			pendingApprovals.append((clientID, approve, deny))
			return
		}
		await beginApprovalRequest(clientID: clientID, approve: approve, deny: deny)
	}

	/// Starts a single active approval request and schedules its timeout watchdog.
	private func beginApprovalRequest(
		clientID: String,
		approve: @escaping () -> Void,
		deny: @escaping () -> Void
	) async {
		approvalTimeoutTask?.cancel()
		approvalTimeoutTask = nil
		pendingConnectionID = clientID
		activeApprovalDialogs.insert(clientID)
		currentApprovalCallbacks = (approve, deny)
		approvalGeneration &+= 1

		let expectedClientID = clientID
		let expectedGeneration = approvalGeneration
		let timeout = approvalTimeout
		approvalTimeoutTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(timeout))
			guard let self else { return }
			await self.handleApprovalTimeout(
				clientID: expectedClientID,
				expectedGeneration: expectedGeneration
			)
		}

		await onApprovalRequest?(clientID)
	}

	/// Starts the next queued approval request, if any.
	private func activateNextQueuedApprovalIfNeeded() async {
		guard currentApprovalCallbacks == nil else { return }
		guard pendingConnectionID == nil else { return }
		guard !pendingApprovals.isEmpty else { return }
		let (nextClientID, approve, deny) = pendingApprovals.removeFirst()
		await beginApprovalRequest(clientID: nextClientID, approve: approve, deny: deny)
	}
	
	/// Handle approval timeout - auto-deny the active request and any queued duplicates for that client.
	private func handleApprovalTimeout(clientID: String, expectedGeneration: UInt64) async {
		guard let (_, deny) = currentApprovalCallbacks,
				pendingConnectionID == clientID,
				approvalGeneration == expectedGeneration else { return }
		
		approvalTimeoutTask?.cancel()
		approvalTimeoutTask = nil
		currentApprovalCallbacks = nil
		pendingConnectionID = nil
		activeApprovalDialogs.remove(clientID)
		deny()

		// Also auto-deny queued requests for the same client to avoid backlog/slot buildup.
		while let idx = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
			let (_, _, queuedDeny) = pendingApprovals.remove(at: idx)
			queuedDeny()
		}

		onApprovalResolved?(false)
		
		if let service = mcpService {
			let diag = MCPDiagnostics(
				issue: .lastClientApprovalTimedOut(clientID: clientID),
				lastEventAt: Date(),
				listenerStateDescription: "Last client was auto-denied after approval timeout"
			)
			Task { await service.updateDiagnostics(diag) }
		}

		await activateNextQueuedApprovalIfNeeded()
	}
    
    // Store current approval callbacks
    private var currentApprovalCallbacks: (() -> Void, () -> Void)?
    
	/// Called by MCPService when the UI has made a decision.
	func resolvePendingApproval(allow: Bool, alwaysAllow: Bool = false) async {
		guard let (approve, deny) = currentApprovalCallbacks else { return }
		let resolvedClientID = pendingConnectionID
		approvalTimeoutTask?.cancel()
		approvalTimeoutTask = nil
		
		if !allow, let clientID = resolvedClientID, let service = mcpService {
			let diag = MCPDiagnostics(
				issue: .lastClientApprovalDenied(clientID: clientID),
				lastEventAt: Date(),
				listenerStateDescription: "Last client was denied"
			)
			Task { await service.updateDiagnostics(diag) }
		}
		
		if allow {
			// If user selected "always allow", add to the persistent list
			if alwaysAllow, let clientID = resolvedClientID {
				addAlwaysAllowed(clientID: clientID)
			}
            approve()
        } else {
            deny()
        }
        
        // Process any queued approvals for the same client.
        // Coalescing same-client decisions prevents continuation leaks on reconnect storms.
        if let clientID = resolvedClientID {
            while let idx = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
                let (_, a, d) = pendingApprovals.remove(at: idx)
                allow ? a() : d()
            }
            activeApprovalDialogs.remove(clientID)
        }
        
        currentApprovalCallbacks = nil
        pendingConnectionID = nil
        
        // Notify resolution callback if needed
        onApprovalResolved?(allow)
		await activateNextQueuedApprovalIfNeeded()
    }
}
