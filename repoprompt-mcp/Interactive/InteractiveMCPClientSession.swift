//
//  InteractiveMCPClientSession.swift
//  repoprompt-mcp
//
//  Manages the MCP client connection for interactive CLI mode.
//  Handles bootstrap handshake, tool caching, and tool calls.
//

import Foundation
import Logging
import MCP

// MARK: - Progress Notification (CLI-side)

/// MCP notification wrapper for progress updates.
/// Uses RepoPromptProgressParams from shared MCPControlMessages.
struct CLIProgressNotification: MCP.Notification {
    typealias Parameters = RepoPromptProgressParams
    static let name: String = "repoprompt/control/progress"
}

private struct CLIBindContextWorkspace: Decodable {
	let id: UUID
	let name: String
}

private struct CLIBindContextTab: Decodable {
	let contextID: UUID
	let name: String

	private enum CodingKeys: String, CodingKey {
		case contextID = "context_id"
		case name
	}
}

private struct CLIBindContextWindow: Decodable {
	let windowID: Int
	let workspace: CLIBindContextWorkspace?
	let tabs: [CLIBindContextTab]

	private enum CodingKeys: String, CodingKey {
		case windowID = "window_id"
		case workspace
		case tabs
	}
}

struct CLIBindContextBinding: Decodable, Sendable {
	let bindingKind: String
	let windowID: Int?
	let contextID: UUID?
	let workspaceName: String?

	private enum CodingKeys: String, CodingKey {
		case bindingKind = "binding_kind"
		case windowID = "window_id"
		case contextID = "context_id"
		case workspaceName = "workspace_name"
	}
}

private struct CLIBindContextResponse: Decodable {
	let windows: [CLIBindContextWindow]?
	let binding: CLIBindContextBinding
}

/// Manages an interactive MCP client session with the RepoPrompt app.
actor InteractiveMCPClientSession {
    private let sessionToken: String
    private let clientName: String
    private let logger: Logger

    private var client: MCP.Client?
    private var transport: BootstrapSocketMCPTransport?
    private var cachedTools: [MCP.Tool] = []
    private(set) var toolsDirty = false

    /// Server info from initialization
    private(set) var serverName: String?
    private(set) var serverVersion: String?

    /// Current window selection (if any)
    private(set) var selectedWindowID: Int?

    /// Canonical context binding injected on tool calls when set.
    private(set) var selectedContextID: String?

    /// If true, request raw JSON tool output (server skips markdown formatting).
    private var rawJSONEnabled: Bool = false
    
    /// If true, emit progress notifications to stderr (for exec mode).
    private var progressEnabled: Bool = false

    init(sessionToken: String, clientName: String, logger: Logger? = nil) {
        self.sessionToken = sessionToken
        self.clientName = clientName
        self.logger = logger ?? Logger(label: "mcp.interactive.session") { _ in
            SwiftLogNoOpLogHandler()
        }
    }

    // MARK: - Connection

    /// Connects to the RepoPrompt app via bootstrap socket and initializes MCP.
    func connect() async throws {
        logger.debug("InteractiveMCPClientSession connecting...")

        // Perform bootstrap handshake and get connected FD
        let connectedFD = try await performBootstrapHandshake()
        logger.debug("Bootstrap handshake complete, FD=\(connectedFD)")

        // Create transport with the connected FD
        let transport = BootstrapSocketMCPTransport(connectedFD: connectedFD, logger: logger)

        // Create MCP client
        let client = MCP.Client(
            name: clientName,
            version: "1.0"
        )
        self.transport = transport
        self.client = client
        logger.debug("Created MCP client '\(clientName)'")

        do {
            // Register for tool list changed notifications
            await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
                await self?.markToolsDirty()
            }
            
            // Register for progress notifications (emit to stderr only when enabled)
            await client.onNotification(CLIProgressNotification.self) { [weak self] message in
                guard await self?.progressEnabled == true else { return }
                let params = message.params
                fputs("[progress] \(params.tool): \(params.message)\n", stderr)
            }

            logger.debug("Calling MCP client.connect(transport)...")
            // Connect and initialize
            let initResult = try await client.connect(transport: transport)
            logger.debug("MCP client connected successfully")

            // Store server info
            serverName = initResult.serverInfo.name
            serverVersion = initResult.serverInfo.version

            logger.debug("Connected to \(serverName ?? "unknown") v\(serverVersion ?? "?")")

            // Initial tool fetch
            try await refreshTools()
        } catch {
            await client.disconnect()
            await transport.disconnect()
            self.client = nil
            self.transport = nil
            cachedTools = []
            toolsDirty = false
            serverName = nil
            serverVersion = nil
            throw error
        }
    }

    /// Disconnects from the MCP server.
    func disconnect() async {
        await client?.disconnect()
        await transport?.disconnect()
        client = nil
        transport = nil
        cachedTools = []
        logger.debug("Disconnected from MCP server")
    }

    // MARK: - Tools

    /// Refreshes the tool list from the server.
    @discardableResult
    func refreshTools() async throws -> [MCP.Tool] {
        guard let client = client else {
            throw InteractiveSessionError.notConnected
        }

        let result = try await client.listTools()
        cachedTools = result.tools
        toolsDirty = false

        logger.debug("Refreshed tools: \(cachedTools.count) available")
        return cachedTools
    }

    /// Returns the cached tool list.
    func tools() -> [MCP.Tool] {
        return cachedTools
    }

    /// Returns a specific tool by name.
    func tool(named name: String) -> MCP.Tool? {
        return cachedTools.first { $0.name == name }
    }

    /// Marks the tool list as potentially stale.
    private func markToolsDirty() {
        toolsDirty = true
        logger.debug("Tool list marked dirty (server sent notification)")
    }

    /// Clears the dirty flag after user acknowledges.
    func acknowledgeToolsChanged() {
        toolsDirty = false
    }

    // MARK: - Raw JSON Mode

    /// Enables/disables raw JSON output mode for tool calls.
    func setRawJSONEnabled(_ enabled: Bool) {
        rawJSONEnabled = enabled
    }
    
    /// Enables/disables progress notifications to stderr (for exec mode).
    func setProgressEnabled(_ enabled: Bool) {
        progressEnabled = enabled
    }

	// MARK: - Tool Calls

	/// Calls a tool with the given arguments.
	func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
		guard let client = client else {
			throw InteractiveSessionError.notConnected
		}

		// Inject hidden parameters if we have window selection
		var args = arguments ?? [:]
		let suppressWindowInjection = shouldSuppressWindowInjection(toolName: name, args: args)
		let suppressContextInjection = shouldSuppressContextInjection(toolName: name)
		if let windowID = selectedWindowID, !suppressWindowInjection {
			args["_windowID"] = .int(windowID)
		}
		if let selectedContextID, args["context_id"] == nil, !suppressContextInjection {
			args["context_id"] = .string(selectedContextID)
		}

		// Request raw JSON output from server formatter (skip markdown)
		if rawJSONEnabled, args["_rawJSON"] == nil {
			args["_rawJSON"] = .bool(true)
		}

		logger.debug("Calling tool: \(name)")
		let result = try await client.callTool(name: name, arguments: args.isEmpty ? nil : args)

		if result.isError != true, shouldClearWindowSelectionAfterCall(toolName: name, args: args) {
			selectedWindowID = nil
			logger.debug("Cleared window selection after open-in-new-window switch")
		}

		return CallTool.Result(content: result.content, isError: result.isError)
	}

	private func shouldSuppressWindowInjection(toolName: String, args: [String: Value]) -> Bool {
		guard toolName != "bind_context" else { return true }
		guard toolName != "app_settings" else { return true }
		guard toolName == "manage_workspaces" else { return false }
		let action = args["action"]?.stringValue?.lowercased()
		guard action == "switch" || action == "create" else { return false }
		return args["open_in_new_window"]?.boolValue ?? false
	}

	private func shouldSuppressContextInjection(toolName: String) -> Bool {
		toolName == "bind_context" || toolName == "app_settings"
	}
	
	private func shouldClearWindowSelectionAfterCall(toolName: String, args: [String: Value]) -> Bool {
		guard toolName == "manage_workspaces" else { return false }
		return shouldSuppressWindowInjection(toolName: toolName, args: args)
	}

	func setSelectedContextID(_ contextID: String?) {
		selectedContextID = contextID?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: - Window Management

    /// Checks if a tool is available in the cached tools list.
    private func hasTool(named name: String) -> Bool {
        cachedTools.contains { $0.name == name }
    }

	/// Returns true when multiple windows are currently open.
	func isMultiWindowModeAvailable() async -> Bool {
		guard hasTool(named: "bind_context") else { return false }
		guard let state = try? await fetchBindContextState() else { return false }
		return (state.windows?.count ?? 0) > 1
	}

    /// Checks if a result indicates "tool not found" for a specific tool.
    private func isToolNotFoundResult(_ result: CallTool.Result, toolName: String) -> Bool {
        guard result.isError == true else { return false }
        let needle = "Tool not found: \(toolName)"
        return result.content.contains { block in
            if case .text(let t, _, _) = block { return t.contains(needle) }
            return false
        }
    }

    /// Returns a friendly message explaining single-window mode.
    private func singleWindowInfoMessage() -> String {
        """
        RepoPrompt is currently in single-window mode.

        The 'windows' and 'use' commands are only available when multiple
        RepoPrompt windows are open. With a single window, commands run
        directly without needing window selection.

        To use multi-window mode:
        1. Open another RepoPrompt window (⌘N or File > New Window)
        2. Run 'refresh' to update available tools
        3. Then 'windows' will show the available windows
        """
    }

    /// Lists available windows.
    func listWindows() async throws -> CallTool.Result {
        if !hasTool(named: "bind_context") {
            return CallTool.Result(
                content: [.text(singleWindowInfoMessage())],
                isError: false
            )
        }

		return try await callTool(name: "bind_context", arguments: [
			"op": .string("list")
		])
    }

    /// Selects a window for subsequent tool calls.
    func selectWindow(windowID: Int) async throws -> CallTool.Result {
        if !hasTool(named: "bind_context") {
            return CallTool.Result(
                content: [.text(singleWindowInfoMessage())],
                isError: false
            )
        }

        let result = try await callTool(name: "bind_context", arguments: [
			"op": .string("bind"),
            "window_id": .int(windowID)
        ])

        // If successful, remember the selection
        if result.isError != true {
            selectedWindowID = windowID
			selectedContextID = nil
            logger.debug("Selected window \(windowID)")
        }

        return result
    }

	func clearWindowSelection() async throws -> CallTool.Result {
		selectedWindowID = nil
		selectedContextID = nil
		// Return a synthetic success result — unbind was removed server-side
		// because the routing system always re-establishes affinity on the next call.
		return CallTool.Result(content: [.text("Local window/context selection cleared.")], isError: false)
	}

	func bindContextID(_ contextID: String, windowID: Int? = nil) async throws -> CallTool.Result {
		var args: [String: Value] = [
			"op": .string("bind"),
			"context_id": .string(contextID)
		]
		if let windowID {
			args["window_id"] = .int(windowID)
		}
		let result = try await callTool(name: "bind_context", arguments: args)
		if result.isError != true {
			selectedContextID = contextID
			if let response = try? decodeBindContextResponse(from: result) {
				selectedWindowID = response.binding.windowID ?? selectedWindowID ?? windowID
			} else if let windowID {
				selectedWindowID = windowID
			}
		}
		return result
	}

	func bindWorkingDirs(_ dirs: [String], windowID: Int? = nil) async throws -> CallTool.Result {
		var args: [String: Value] = [
			"op": .string("bind"),
			"working_dirs": .array(dirs.map { .string($0) })
		]
		if let windowID {
			args["window_id"] = .int(windowID)
		}
		let result = try await callTool(name: "bind_context", arguments: args)
		if result.isError != true, let response = try? decodeBindContextResponse(from: result) {
			selectedWindowID = response.binding.windowID ?? selectedWindowID ?? windowID
			selectedContextID = response.binding.contextID?.uuidString
		}
		return result
	}

	func bindTab(selector: String, windowID: Int? = nil) async throws -> CallTool.Result {
		let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw InteractiveSessionError.handshakeFailed(reason: "Empty context selector")
		}

		if let contextID = UUID(uuidString: trimmed) {
			return try await bindContextID(contextID.uuidString, windowID: windowID)
		}

		let preferredWindowID = windowID ?? selectedWindowID
		let state = try await fetchBindContextState(windowID: preferredWindowID)
		var matches: [(windowID: Int, tab: CLIBindContextTab)] = []
		let lowerTrimmed = trimmed.lowercased()

		for window in state.windows ?? [] {
			for tab in window.tabs where tab.name == trimmed {
				matches.append((window.windowID, tab))
			}
		}
		if matches.isEmpty {
			for window in state.windows ?? [] {
				for tab in window.tabs where tab.name.lowercased() == lowerTrimmed {
					matches.append((window.windowID, tab))
				}
			}
		}
		if matches.isEmpty {
			for window in state.windows ?? [] {
				for tab in window.tabs where tab.name.lowercased().hasPrefix(lowerTrimmed) {
					matches.append((window.windowID, tab))
				}
			}
		}

		guard !matches.isEmpty else {
			throw InteractiveSessionError.handshakeFailed(reason: "Unknown compose tab '\(trimmed)'. Use 'windows' to discover context_id values.")
		}
		guard matches.count == 1, let match = matches.first else {
			let details = matches.map { "\($0.tab.name)@w\($0.windowID)" }.sorted().joined(separator: ", ")
			throw InteractiveSessionError.handshakeFailed(reason: "Ambiguous compose tab '\(trimmed)': \(details). Re-run with -w or use a context_id.")
		}

		return try await bindContextID(match.tab.contextID.uuidString, windowID: match.windowID)
	}

	func bindingStatus() async throws -> CLIBindContextBinding {
		try await fetchBindContextState().binding
	}

	func syncBindingFromServer() async {
		guard let binding = try? await bindingStatus() else { return }
		selectedWindowID = binding.windowID
		selectedContextID = binding.contextID?.uuidString
	}

	private func fetchBindContextState(windowID: Int? = nil) async throws -> CLIBindContextResponse {
		var args: [String: Value] = [
			"op": .string("list"),
			"_rawJSON": .bool(true)
		]
		if let windowID {
			args["window_id"] = .int(windowID)
		}
		let result = try await callTool(name: "bind_context", arguments: args)
		return try decodeBindContextResponse(from: result)
	}

	private func decodeBindContextResponse(from result: CallTool.Result) throws -> CLIBindContextResponse {
		guard let text = result.content.compactMap({
			if case .text(let text, _, _) = $0 { return text }
			return nil
		}).first else {
			throw InteractiveSessionError.handshakeFailed(reason: "bind_context returned no text payload")
		}
		let data = Data(text.utf8)
		return try JSONDecoder().decode(CLIBindContextResponse.self, from: data)
	}

    // MARK: - Bootstrap Handshake

    /// Performs the bootstrap socket handshake and returns the connected FD.
    private func performBootstrapHandshake() async throws -> Int32 {
        let socketURL = MCPFilesystemConstants.bootstrapSocketURL()

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw InteractiveSessionError.socketCreationFailed(errno: errno)
        }
        var shouldCloseFD = true
        defer {
            if shouldCloseFD {
                Darwin.close(fd)
            }
        }

        // Disable SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set up socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw InteractiveSessionError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        // Connect
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        if connectResult < 0 {
            let err = errno
            if err == ECONNREFUSED || err == ENOENT {
                throw InteractiveSessionError.appNotRunning
            }
            throw InteractiveSessionError.connectFailed(errno: err)
        }

        logger.debug("Connected to bootstrap socket")

        // Send handshake request
        try sendHandshakeRequest(fd: fd)

		// Read handshake response
		let response = try await readHandshakeResponse(
			fd: fd,
			timeout: MCPBootstrapTiming.initialResponseTimeout
		)

        switch response.type {
        case "accepted":
            logger.debug("Bootstrap handshake accepted")
            shouldCloseFD = false
            return fd

		case "rejected":
			if response.errorCode == MCPBootstrapErrorCode.approvalDenied.rawValue {
				throw InteractiveSessionError.approvalDenied
			}
			throw InteractiveSessionError.handshakeFailed(reason: response.reason ?? "Rejected by server")

        default:
            throw InteractiveSessionError.handshakeFailed(reason: "Unknown response: \(response.type)")
        }
	}

	private func sendHandshakeRequest(fd: Int32) throws {
		let request = MCPBootstrapRequest(
			sessionToken: sessionToken,
			clientPid: Int(getpid()),
			clientName: clientName,
			protocolVersion: MCPBootstrapProtocol.currentVersion
		)

		guard let jsonData = try? JSONEncoder().encode(request) else {
			throw InteractiveSessionError.handshakeFailed(reason: "Failed to encode request")
		}

        var payload = jsonData
        payload.append(UInt8(ascii: "\n"))

        var totalWritten = 0
        while totalWritten < payload.count {
            let written = payload.withUnsafeBytes { buf in
                let ptr = buf.baseAddress!.advanced(by: totalWritten)
                return Darwin.write(fd, ptr, payload.count - totalWritten)
            }

            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw InteractiveSessionError.writeFailed(errno: errno)
            }
            totalWritten += written
        }
    }

	private func readHandshakeResponse(
		fd: Int32,
		timeout: TimeInterval
	) async throws -> MCPBootstrapResponse {
		var buffer = Data()
		let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
		defer { readBuffer.deallocate() }

		let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if Task.isCancelled {
                throw InteractiveSessionError.cancelled
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            let pollResult = poll(&pfd, 1, min(100, max(1, remaining)))

            if pollResult < 0 {
                if errno == EINTR { continue }
                throw InteractiveSessionError.pollFailed(errno: errno)
            }

            if pollResult == 0 { continue }

            if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                throw InteractiveSessionError.connectionReset
            }

            let bytesRead = Darwin.read(fd, readBuffer, 4096)
            if bytesRead <= 0 {
                if bytesRead < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                throw InteractiveSessionError.serverClosed
            }

			buffer.append(readBuffer, count: bytesRead)

			if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
				let jsonData = buffer[..<newlineIndex]
				guard let response = try? JSONDecoder().decode(MCPBootstrapResponse.self, from: Data(jsonData)) else {
					throw InteractiveSessionError.handshakeFailed(reason: "Invalid response JSON")
				}
				return response
			}
		}

		throw InteractiveSessionError.bootstrapResponseTimeout
	}
}

// MARK: - Errors

enum InteractiveSessionError: Swift.Error, CustomStringConvertible {
    case notConnected
    case socketCreationFailed(errno: Int32)
    case pathTooLong
    case connectFailed(errno: Int32)
    case appNotRunning
	case approvalDenied
	case handshakeFailed(reason: String)
	case bootstrapResponseTimeout
	case connectionReset
	case serverClosed
    case writeFailed(errno: Int32)
    case pollFailed(errno: Int32)
    case cancelled

    var description: String {
        switch self {
        case .notConnected:
            return "Not connected to MCP server"
        case .socketCreationFailed(let errno):
            return "Failed to create socket: \(errno)"
        case .pathTooLong:
            return "Socket path too long"
        case .connectFailed(let errno):
            if errno == EPERM || errno == EACCES {
                return "Failed to connect: permission denied (errno \(errno)). If running in a sandboxed environment (e.g., Codex), disable sandbox or grant socket access."
            } else if errno == ENOENT {
                return "Failed to connect: socket not found. Is RepoPrompt running with MCP enabled?"
            } else if errno == ECONNREFUSED {
                return "Failed to connect: connection refused. RepoPrompt may need to be restarted."
            }
            return "Failed to connect: \(errno)"
        case .appNotRunning:
            return "RepoPrompt app is not running or MCP is disabled"
		case .approvalDenied:
			return "Connection approval was denied"
		case .handshakeFailed(let reason):
			return "Handshake failed: \(reason)"
		case .bootstrapResponseTimeout:
			return "Timed out waiting for RepoPrompt bootstrap response"
		case .connectionReset:
            return "Connection reset by server"
        case .serverClosed:
            return "Server closed connection"
        case .writeFailed(let errno):
            return "Write failed: \(errno)"
        case .pollFailed(let errno):
            return "Poll failed: \(errno)"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
