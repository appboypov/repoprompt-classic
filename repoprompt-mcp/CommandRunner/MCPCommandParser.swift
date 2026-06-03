//
//  MCPCommandParser.swift
//  repoprompt-mcp
//
//  Extracted command grammar from InteractiveREPL.
//  Handles parsing of shell-like commands into structured operations.
//

import Foundation
import MCP

// MARK: - Command Types

/// Represents a parsed interactive command.
enum InteractiveCommand: Sendable {
    case help
    case tools(mode: ToolListMode)
    case toolsSchema(mode: ToolListMode)
    case describe(toolName: String)
    case call(toolName: String, jsonPayload: String?)
    case aliasCall(toolName: String, args: [String: AnyCodableSendable])
    case windows
    case useWindow(windowID: Int)
    case clearWindow
    case snapshot(path: String)
    case refresh
    case exit
    // Session management
    case history
    case showSettings
    case setSetting(name: String, value: String?)
    case clearScreen
    case status
    case pwd
    case cd(path: String)
}

/// A sendable wrapper for Any-typed values for alias arguments.
struct AnyCodableSendable: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

// MARK: - Errors

enum CommandParseError: Swift.Error, CustomStringConvertible, Sendable {
    case emptyCommand
    case unknownCommand(String)
    case missingArgument(String)
    case invalidArgument(String)
    case invalidJSON(String)
    case jsonRequired(String)  // Tool requires JSON format

    var description: String {
        switch self {
        case .emptyCommand:
            return "Empty command"
        case .unknownCommand(let cmd):
            return "Unknown command: '\(cmd)'. Type 'help' for available commands."
        case .missingArgument(let arg):
            return "Missing argument: \(arg)"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .invalidJSON(let msg):
            return "Invalid JSON: \(msg)"
        case .jsonRequired(let tool):
            let example: String
            switch tool {
            case "file_actions":
                example = "{\"action\":\"create\",\"path\":\"...\",\"content\":\"...\"}"
            default:  // apply_edits
                example = "{\"path\":\"...\",\"search\":\"...\",\"replace\":\"...\"}"
            }
            return "\(tool) requires JSON format. Use: call \(tool) \(example)"
        }
    }
}

// MARK: - Parse Context

/// Context for command parsing - tracks directory for path resolution.
struct CommandParseContext: Sendable {
    var currentDirectory: String

    init(currentDirectory: String = FileManager.default.currentDirectoryPath) {
        self.currentDirectory = currentDirectory
    }

    /// Resolves a path argument:
    /// - ~ expands to home directory
    /// - Relative paths resolve against currentDirectory
    /// - Absolute paths pass through unchanged
    func resolvePathArg(_ arg: String) -> String {
        // Expand ~
        if arg.hasPrefix("~") {
            let expanded = arg.replacingOccurrences(
                of: "~",
                with: FileManager.default.homeDirectoryForCurrentUser.path,
                range: arg.startIndex..<arg.index(after: arg.startIndex)
            )
            return URL(fileURLWithPath: expanded).standardized.path
        }

        // Absolute path - pass through
        if arg.hasPrefix("/") {
            return URL(fileURLWithPath: arg).standardized.path
        }

        // Relative path - resolve against currentDirectory
        let url = URL(fileURLWithPath: currentDirectory).appendingPathComponent(arg)
        return url.standardized.path
    }

    /// Passes workspace path through unchanged - the MCP server handles all resolution.
    /// Use this for: manage_selection, apply_edits, read_file, file_actions, get_code_structure, etc.
    func resolveWorkspacePathArg(_ arg: String) -> String {
        arg
    }

    /// Resolves a repo root argument - can be a path or a loaded root name.
    /// - If it looks like a path (contains / or starts with ~ or .) and exists, resolve it
    /// - Otherwise pass through unchanged for server-side name resolution
    func resolveRepoRootArg(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)

        // If it looks like a path, try to resolve it
        let looksLikePath = trimmed.contains("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
        if looksLikePath {
            let resolved = resolvePathArg(trimmed)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) && isDir.boolValue {
                return resolved
            }
        }

        // Not a path or doesn't exist - pass through for server-side name resolution
        return trimmed
    }

    /// Changes the current directory. Returns true if successful.
    mutating func changeDirectory(to path: String) -> Bool {
        let resolved = resolvePathArg(path)
        let standardized = URL(fileURLWithPath: resolved).standardized.path

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir) && isDir.boolValue {
            currentDirectory = standardized
            return true
        }
        return false
    }
}

// MARK: - Parser

enum MCPCommandParser {

    // MARK: - Context Builder Instruction Aliases

    /// CLI-level aliases that map to MCP `context_builder.instructions`.
    /// These allow users to use more intuitive parameter names.
    private static let contextBuilderInstructionAliases: Set<String> = [
        "instructions", "instruction",
        "task", "prompt", "query",
        "message", "text", "input"
    ]

	private static let contextBuilderExportAliases: Set<String> = ["export", "export_response"]

	private static func normalizeContextBuilderExportArgs(_ args: inout [String: AnyCodableSendable]) throws {
		var normalizedValue: Bool?
		var sawExportAlias = false

		for alias in contextBuilderExportAliases {
			guard let value = args[alias] else { continue }
			sawExportAlias = true
			let boolValue = try contextBuilderExportBool(from: value)
			if let normalizedValue, normalizedValue != boolValue {
				throw CommandParseError.invalidArgument("Conflicting export_response flags were provided.")
			}
			normalizedValue = boolValue
		}

		args.removeValue(forKey: "export")
		if sawExportAlias, let normalizedValue {
			args["export_response"] = AnyCodableSendable(normalizedValue)
		}
	}

	private static func normalizeContextBuilderExportArgs(_ args: inout [String: Value]) throws {
		var normalizedValue: Bool?
		var sawExportAlias = false

		for alias in contextBuilderExportAliases {
			guard let value = args[alias] else { continue }
			sawExportAlias = true
			let boolValue = try contextBuilderExportBool(from: value)
			if let normalizedValue, normalizedValue != boolValue {
				throw CommandParseError.invalidArgument("Conflicting export_response flags were provided.")
			}
			normalizedValue = boolValue
		}

		args.removeValue(forKey: "export")
		if sawExportAlias, let normalizedValue {
			args["export_response"] = .bool(normalizedValue)
		}
	}

	private static func applyContextBuilderExportFlag(_ flags: FlagParseResult, to args: inout [String: AnyCodableSendable]) throws {
		let rawValues = [
			flags["export"],
			flags["export-response"],
			flags["export_response"]
		].compactMap { $0 }

		guard !rawValues.isEmpty else { return }

		var normalizedValue: Bool?
		for rawValue in rawValues {
			guard let boolValue = parseBoolFlag(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
				throw CommandParseError.invalidArgument("export_response must be a boolean when provided.")
			}
			if let normalizedValue, normalizedValue != boolValue {
				throw CommandParseError.invalidArgument("Conflicting export_response flags were provided.")
			}
			normalizedValue = boolValue
		}

		if let normalizedValue {
			args["export_response"] = AnyCodableSendable(normalizedValue)
		}
	}

	private static func contextBuilderExportBool(from value: AnyCodableSendable) throws -> Bool {
		if let boolValue = value.value as? Bool {
			return boolValue
		}
		if let stringValue = value.value as? String,
			let boolValue = parseBoolFlag(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
			return boolValue
		}
		if let intValue = value.value as? Int, (intValue == 0 || intValue == 1) {
			return intValue == 1
		}
		if let doubleValue = value.value as? Double, (doubleValue == 0 || doubleValue == 1) {
			return doubleValue == 1
		}
		throw CommandParseError.invalidArgument("export_response must be a boolean when provided.")
	}

	private static func contextBuilderExportBool(from value: Value) throws -> Bool {
		switch value {
		case .bool(let boolValue):
			return boolValue
		case .string(let stringValue):
			guard let boolValue = parseBoolFlag(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
				throw CommandParseError.invalidArgument("export_response must be a boolean when provided.")
			}
			return boolValue
		case .int(let intValue) where intValue == 0 || intValue == 1:
			return intValue == 1
		case .double(let doubleValue) where doubleValue == 0 || doubleValue == 1:
			return doubleValue == 1
		default:
			throw CommandParseError.invalidArgument("export_response must be a boolean when provided.")
		}
	}

    /// Normalizes context_builder arguments by mapping instruction aliases to 'instructions'.
    /// - Parameter args: The arguments dictionary to normalize (modified in place)
    /// - Throws: CommandParseError if multiple conflicting instruction aliases are provided
    static func normalizeContextBuilderArgs(_ args: inout [String: AnyCodableSendable]) throws {
        try normalizeContextBuilderExportArgs(&args)

        // Check if instructions already exists and is non-empty
        if let existing = args["instructions"]?.value as? String, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Remove any other aliases to avoid sending unknown params
            for alias in contextBuilderInstructionAliases where alias != "instructions" {
                args.removeValue(forKey: alias)
            }
            return
        }

        // Find the first non-empty alias value
        var foundAlias: (key: String, value: String)? = nil
        var conflictingAliases: [String] = []

        for alias in contextBuilderInstructionAliases where alias != "instructions" {
            if let value = args[alias]?.value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if foundAlias == nil {
                    foundAlias = (alias, value)
                } else {
                    conflictingAliases.append(alias)
                }
            }
        }

        // Check for conflicts (multiple non-empty aliases)
        if let found = foundAlias, !conflictingAliases.isEmpty {
            throw CommandParseError.invalidArgument(
                "Multiple instruction parameters provided: '\(found.key)' and '\(conflictingAliases.joined(separator: "', '"))'. Use only one of: instructions, task, prompt, query, message, text"
            )
        }

        // Map the found alias to 'instructions'
        if let found = foundAlias {
            args["instructions"] = AnyCodableSendable(found.value)
            args.removeValue(forKey: found.key)
        }

        // Remove any remaining empty aliases
        for alias in contextBuilderInstructionAliases where alias != "instructions" {
            args.removeValue(forKey: alias)
        }
    }

    /// Normalizes context_builder arguments in MCP Value format.
    /// - Parameter args: The arguments dictionary to normalize (modified in place)
    /// - Throws: CommandParseError if multiple conflicting instruction aliases are provided
    static func normalizeContextBuilderArgs(_ args: inout [String: Value]) throws {
        try normalizeContextBuilderExportArgs(&args)

        // Check if instructions already exists and is non-empty
        if case .string(let existing) = args["instructions"], !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Remove any other aliases to avoid sending unknown params
            for alias in contextBuilderInstructionAliases where alias != "instructions" {
                args.removeValue(forKey: alias)
            }
            return
        }

        // Find the first non-empty alias value
        var foundAlias: (key: String, value: String)? = nil
        var conflictingAliases: [String] = []

        for alias in contextBuilderInstructionAliases where alias != "instructions" {
            if case .string(let value) = args[alias], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if foundAlias == nil {
                    foundAlias = (alias, value)
                } else {
                    conflictingAliases.append(alias)
                }
            }
        }

        // Check for conflicts (multiple non-empty aliases)
        if let found = foundAlias, !conflictingAliases.isEmpty {
            throw CommandParseError.invalidArgument(
                "Multiple instruction parameters provided: '\(found.key)' and '\(conflictingAliases.joined(separator: "', '"))'. Use only one of: instructions, task, prompt, query, message, text"
            )
        }

        // Map the found alias to 'instructions'
        if let found = foundAlias {
            args["instructions"] = .string(found.value)
            args.removeValue(forKey: found.key)
        }

        // Remove any remaining empty aliases
        for alias in contextBuilderInstructionAliases where alias != "instructions" {
            args.removeValue(forKey: alias)
        }
    }

    /// Resolves a command alias to its underlying MCP tool name.
    /// Returns the input unchanged if it's already a tool name or unknown.
    /// Normalizes dashes to underscores for tool names (e.g., context-builder → context_builder).
    static func resolveToolAlias(_ alias: String) -> String {
        // Normalize: convert dashes to underscores for consistent matching
        let normalized = alias.lowercased().replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "read", "cat", "read_file":
            return "read_file"
        case "search", "grep", "find", "file_search":
            return "file_search"
        case "tree", "get_file_tree":
            return "get_file_tree"
        case "structure", "struct", "map", "get_code_structure":
            return "get_code_structure"
        case "context", "ctx", "workspace_context":
            return "workspace_context"
        case "builder", "context_builder":
            return "context_builder"
        case "select", "sel", "state":
			return "manage_selection"
        case "prompt":
            return "prompt"
        // Note: "edit"/"replace" shortcuts removed - apply_edits requires JSON format
        // Note: "file" shortcut removed - file_actions requires JSON format
		case "chat", "newchat", "plan", "review", "oracle_send":
			return "oracle_send"
		case "oracle", "oracle_utils":
			return "oracle_utils"
        case "chats":
            return "oracle_utils"
        case "models":
			return "oracle_utils"
		case "workspace", "ws", "manage_workspaces":
			return "manage_workspaces"
		case "bind_context", "binding", "bind":
			return "bind_context"
        case "git":
            return "git"
        case "apply_edits":
            return "apply_edits"
        case "file_actions":
            return "file_actions"
        case "app_settings":
            return "app_settings"
		case "agent_run":
			return "agent_run"
		case "agent_manage":
			return "agent_manage"
        case "ask_user":
            return "ask_user"
        default:
            // For unknown commands, return normalized version (dashes → underscores)
            // This ensures tool names like "apply-edits" resolve to "apply_edits"
            return normalized
        }
    }

    /// All known commands for typo suggestions.
    static let allCommands = [
        // Shell-like commands
        "help", "tools", "list", "describe", "desc", "call", "windows", "use", "window",
        "snapshot", "refresh", "exit", "quit", "history", "set", "clear", "status",
        "pwd", "cd", "read", "cat", "search", "grep", "find", "tree", "structure",
		"struct", "map", "context", "ctx", "select", "sel", "state", "prompt",
		"chat", "newchat", "plan", "review", "oracle", "chats", "models", "workspace", "ws", "tabs", "builder", "git",
		// Raw MCP tool names (apply_edits and file_actions require JSON format via 'call')
		"manage_selection", "workspace_context", "read_file", "file_search",
		"get_file_tree", "get_code_structure", "apply_edits", "oracle_send",
		"oracle_utils", "manage_workspaces", "bind_context", "file_actions", "context_builder", "git",
        "app_settings", "agent_run", "agent_manage", "ask_user"
	]

    /// Parses a command segment into an InteractiveCommand.
    static func parseCommand(_ input: String, ctx: CommandParseContext) throws -> InteractiveCommand {
        let parts = splitShellWords(input)
        guard let first = parts.first?.lowercased() else {
            throw CommandParseError.emptyCommand
        }

        switch first {
        case "help", "?", "h":
            return .help

        case "tools", "list", "ls":
            // Handle tools command with optional group filtering
            let remainingParts = Array(parts.dropFirst())
            
            // Check for --schema or --json flag
            let hasSchemaFlag = remainingParts.contains("--schema") || remainingParts.contains("--json")
            let filteredParts = remainingParts.filter { $0 != "--schema" && $0 != "--json" }
            
            // Check for --groups flag
            if filteredParts.contains("--groups") {
                return hasSchemaFlag ? .toolsSchema(mode: .all) : .tools(mode: .groupNames)
            }
            
            let mode: ToolListMode
            if filteredParts.isEmpty {
                mode = .all
            } else {
                // Parse group specification (e.g., "tools routing" or "tools explore,edit")
                let spec = filteredParts.joined(separator: " ")
                do {
                    let groups = try ToolGroupCatalog.parseGroups(spec: spec)
                    mode = .groups(groups)
                } catch let error as ToolGroupParseError {
                    throw CommandParseError.invalidArgument(error.description)
                } catch {
                    throw CommandParseError.invalidArgument("\(error)")
                }
            }
            
            return hasSchemaFlag ? .toolsSchema(mode: mode) : .tools(mode: mode)

        case "describe", "desc", "d":
            guard parts.count >= 2 else {
                throw CommandParseError.missingArgument("tool name")
            }
            return .describe(toolName: parts[1])

        case "call", "c":
            guard parts.count >= 2 else {
                throw CommandParseError.missingArgument("tool name")
            }
            let toolName = parts[1]
            // Everything after tool name is JSON args - use safe extraction
            let jsonPayload: String?
            if let cmdRemainder = rawRemainderAfterFirstToken(input),
               let toolRemainder = Self.rawRemainderAfterFirstToken(cmdRemainder) {
                jsonPayload = toolRemainder.isEmpty ? nil : toolRemainder
            } else {
                jsonPayload = nil
            }
            return .call(toolName: toolName, jsonPayload: jsonPayload)

        case "windows", "w":
            return .windows

        case "use-window", "use", "window":
            guard parts.count >= 2, let windowID = Int(parts[1]) else {
                throw CommandParseError.invalidArgument("window ID must be a number")
            }
            return .useWindow(windowID: windowID)

        case "clear-window":
            return .clearWindow

        case "snapshot":
            guard parts.count >= 2 else {
                throw CommandParseError.missingArgument("output path")
            }
            return .snapshot(path: parts[1])

        case "refresh":
            return .refresh

        case "exit", "quit", "q":
            return .exit

        // History and settings
        case "history", "hist":
            return .history

        case "set":
            if parts.count < 2 {
                return .showSettings
            }
            let setting = parts[1].lowercased()
            let value = parts.count >= 3 ? parts[2].lowercased() : nil
            return .setSetting(name: setting, value: value)

        case "clear", "cls":
            return .clearScreen

        case "status", "st":
            return .status

        case "pwd":
            return .pwd

        case "cd":
            let path = parts.count >= 2 ? parts[1] : "~"
            return .cd(path: path)

        // ════════════════════════════════════════════════════════════
        // TOOL ALIASES - Shell-like shortcuts for common operations
        // ════════════════════════════════════════════════════════════

        // File reading: read <path> [start_line] [limit] or read --path <path> --start-line N --limit N
        case "read", "cat":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)

            // Get path from --path flag or first positional
            guard let pathArg = flags["path"] ?? flags["p"] ?? flags.positional.first else {
                throw CommandParseError.missingArgument("file path")
            }
            let path = ctx.resolveWorkspacePathArg(pathArg)
            var args: [String: AnyCodableSendable] = ["path": AnyCodableSendable(path)]

            // Get start_line from flag or second positional
            if let startStr = flags["start-line"] ?? flags["start_line"] ?? flags["start"] ?? flags["s"],
               let startLine = Int(startStr) {
                args["start_line"] = AnyCodableSendable(startLine)
            } else if flags.positional.count >= 2, let startLine = Int(flags.positional[1]) {
                args["start_line"] = AnyCodableSendable(startLine)
            }

            // Get limit from flag or third positional
            if let limitStr = flags["limit"] ?? flags["l"],
               let limit = Int(limitStr) {
                args["limit"] = AnyCodableSendable(limit)
            } else if flags.positional.count >= 3, let limit = Int(flags.positional[2]) {
                args["limit"] = AnyCodableSendable(limit)
            }
            return .aliasCall(toolName: "read_file", args: args)

        // Search: search <pattern> [path] [--context N] [--max N] [--path <path>] [--mode auto|path|content|both]
        //         [--extensions .swift,.ts] [--exclude pattern] [--count-only] [--whole-word]
        case "search", "grep", "find":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)

            // Get pattern from --pattern flag or first positional
            guard let pattern = flags["pattern"] ?? flags.positional.first else {
                throw CommandParseError.missingArgument("search pattern")
            }
            var args: [String: AnyCodableSendable] = ["pattern": AnyCodableSendable(pattern)]

            // Build filter object
            var filterDict: [String: Any] = [:]

            // Get path from --path/--paths flag or second positional
            if let pathArg = flags["paths"] ?? flags["path"] ?? flags["p"] ?? flags.positional.dropFirst().first {
                let rawPaths = pathArg.split(separator: ",")
                let resolvedPaths = rawPaths.map {
                    ctx.resolveWorkspacePathArg(String($0).trimmingCharacters(in: .whitespaces))
                }
                if !resolvedPaths.isEmpty {
                    filterDict["paths"] = resolvedPaths
                }
            }

            // Extensions filter (comma-separated, e.g., --extensions .swift,.ts)
            if let extsStr = flags["extensions"] ?? flags["exts"] ?? flags["extension"] ?? flags["ext"] ?? flags["e"] {
                let exts = extsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                filterDict["extensions"] = exts
            }

            // Exclude patterns (comma-separated)
            if let excludeStr = flags["exclude"] ?? flags["excludes"] ?? flags["x"] {
                let excludes = excludeStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                filterDict["exclude"] = excludes
            }

            if !filterDict.isEmpty {
                args["filter"] = AnyCodableSendable(filterDict)
            }

            // Search mode (auto, path, content, both)
            if let mode = flags["mode"] {
                args["mode"] = AnyCodableSendable(mode)
            }

            // Context lines
            if let ctxStr = flags["context-lines"] ?? flags["context_lines"] ?? flags["context"] ?? flags["C"] ?? flags["c"],
               let ctxLines = Int(ctxStr) {
                args["context_lines"] = AnyCodableSendable(ctxLines)
            }

            // Max results
            if let maxStr = flags["max"] ?? flags["max-results"] ?? flags["max_results"] ?? flags["n"],
               let maxResults = Int(maxStr) {
                args["max_results"] = AnyCodableSendable(maxResults)
            }

            // Regex flag (auto-detected unless set; disable with --no-regex/--literal)
            if flags["no-regex"] != nil || flags["literal"] != nil || flags["F"] != nil {
                args["regex"] = AnyCodableSendable(false)
            } else if let regexValue = parseBoolFlag(flags["regex"]) {
                args["regex"] = AnyCodableSendable(regexValue)
            }

            // Count only flag
            if flags["count-only"] != nil || flags["count_only"] != nil || flags["count"] != nil {
                args["count_only"] = AnyCodableSendable(true)
            }

            // Whole word flag
            if flags["whole-word"] != nil || flags["whole_word"] != nil || flags["w"] != nil {
                args["whole_word"] = AnyCodableSendable(true)
            }

            return .aliasCall(toolName: "file_search", args: args)

        // File tree: tree [path] [--folders]
        case "tree":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            var args: [String: AnyCodableSendable] = ["type": AnyCodableSendable("files")]
            var mode = "auto"

            if let type = flags["type"] {
                args["type"] = AnyCodableSendable(type)
            }
            if let modeValue = flags["mode"] {
                mode = modeValue
            }
            if flags["folders"] != nil || flags["f"] != nil {
                mode = "folders"
            } else if flags["full"] != nil {
                mode = "full"
            } else if flags["selected"] != nil || flags["s"] != nil {
                mode = "selected"
            }

            if let depthStr = flags["max-depth"] ?? flags["max_depth"] ?? flags["depth"] ?? flags["d"],
               let maxDepth = Int(depthStr) {
                args["max_depth"] = AnyCodableSendable(maxDepth)
            }

            if let pathArg = flags["path"] ?? flags["p"] ?? flags.positional.first {
                let path = ctx.resolveWorkspacePathArg(pathArg)
                args["path"] = AnyCodableSendable(path)
            }

            args["mode"] = AnyCodableSendable(mode)
            return .aliasCall(toolName: "get_file_tree", args: args)

        // Code structure: structure <path> [path2] ... [--scope paths|selected] [--max-results N]
        case "structure", "struct", "map":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)

            var args: [String: AnyCodableSendable] = [:]

            // Scope: selected or paths (default)
            if let scope = flags["scope"] ?? flags["s"] {
                args["scope"] = AnyCodableSendable(scope)
                // For scope=selected, paths are not required
                if scope.lowercased() == "selected" {
                    // No paths needed
                }
            }

            // Max results
            if let maxStr = flags["max-results"] ?? flags["max_results"] ?? flags["max"] ?? flags["m"],
               let maxResults = Int(maxStr) {
                args["max_results"] = AnyCodableSendable(maxResults)
            }

            // Paths from positional arguments or --paths/--path
            var paths = flags.positional.map { ctx.resolveWorkspacePathArg($0) }
            if let pathsArg = flags["paths"] ?? flags["path"] ?? flags["p"] {
                let rawPaths = pathsArg.split(separator: ",")
                let resolved = rawPaths.map {
                    ctx.resolveWorkspacePathArg(String($0).trimmingCharacters(in: .whitespaces))
                }
                paths.append(contentsOf: resolved)
            }
            if !paths.isEmpty {
                args["paths"] = AnyCodableSendable(paths)
            } else if args["scope"] == nil {
                // No paths and no scope - require at least one path
                throw CommandParseError.missingArgument("file or directory path (or use --scope selected)")
            }

            return .aliasCall(toolName: "get_code_structure", args: args)

        // Workspace context: context [--tree] [--files] [--all] [--path-display full|relative]
        case "context", "ctx":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            var include: [String] = ["prompt", "selection", "code", "tokens"]
            var pathDisplay: String? = nil

            if let includeStr = flags["include"] ?? flags["includes"] {
                include = includeStr.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
            }
            if flags["all"] != nil || flags["a"] != nil {
                include = ["prompt", "selection", "code", "files", "tree", "tokens"]
            }
            if flags["tree"] != nil || flags["t"] != nil {
                include.append("tree")
            }
            if flags["files"] != nil || flags["f"] != nil {
                include.append("files")
            }

            if flags["relative"] != nil {
                pathDisplay = "relative"
            } else if flags["full-paths"] != nil {
                pathDisplay = "full"
            }
            if let pathDisplayFlag = flags["path-display"] ?? flags["path_display"] {
                pathDisplay = pathDisplayFlag
            }

            var seen = Set<String>()
            include = include.filter { seen.insert($0).inserted }

            var args: [String: AnyCodableSendable] = ["include": AnyCodableSendable(include)]
            if let pathDisplay = pathDisplay {
                args["path_display"] = AnyCodableSendable(pathDisplay)
            }
            return .aliasCall(toolName: "workspace_context", args: args)

        // Context builder: builder <instructions> [--response-type plan|question|clarify] [--export]
        // Accepts instruction aliases: --task, --prompt, --query, --message, --text, --input
        // When no response-type flag is provided, response_type is NOT sent (context-only mode per API default)
        case "builder":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)

            // Get instructions from flags or positional arguments
            // Priority: explicit flags > positional text
            let instructionsFromFlags = flags["instructions"] ?? flags["instruction"] ??
                flags["task"] ?? flags["prompt"] ?? flags["query"] ??
                flags["message"] ?? flags["text"] ?? flags["input"]
            let positionalText = flags.positional.joined(separator: " ")
            let instructions = instructionsFromFlags ?? (positionalText.isEmpty ? nil : positionalText)

            guard let instructionsValue = instructions,
                  !instructionsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommandParseError.missingArgument(
                    """
                    instructions (required)

                    Usage:
                      builder "your task description"
                      builder --task "your task description"

                    Optional: --type plan|question|clarify, --export
                    """
                )
            }

            var args: [String: AnyCodableSendable] = [
                "instructions": AnyCodableSendable(instructionsValue)
            ]

            // Only set response_type if explicitly specified via --response-type/--type or -t
            // Per API: "Omit or 'clarify' to just return context"
            if let responseType = flags["response-type"] ?? flags["response_type"] ?? flags["type"] ?? flags["t"] {
                args["response_type"] = AnyCodableSendable(responseType)
            }

            try applyContextBuilderExportFlag(flags, to: &args)

            return .aliasCall(toolName: "context_builder", args: args)

        // Selection management: select <op> [paths...] [--codemap|--full] [--strict] [--path-display full|relative]
        case "select", "sel":
            guard parts.count >= 2 else {
                throw CommandParseError.missingArgument("operation (add/remove/set/clear/get)")
            }
            let op = parts[1].lowercased()
            var args: [String: AnyCodableSendable] = ["op": AnyCodableSendable(op)]

            // Regex for detecting slice tokens: path:start-end or path:start (e.g., file.swift:10-20)
            let slicePattern = try! NSRegularExpression(pattern: #"^(.+?):(\d+)(?:-(\d+))?$"#)
            
            // Helper to check if a token looks like a slice
            func isSliceToken(_ token: String) -> Bool {
                let range = NSRange(token.startIndex..<token.endIndex, in: token)
                return slicePattern.firstMatch(in: token, range: range) != nil
            }
            
            // Helper to parse slice tokens into path and ranges
            func parseSliceToken(_ token: String) -> (path: String, startLine: Int, endLine: Int?)? {
                let range = NSRange(token.startIndex..<token.endIndex, in: token)
                guard let match = slicePattern.firstMatch(in: token, range: range) else { return nil }
                
                guard let pathRange = Range(match.range(at: 1), in: token),
                      let startRange = Range(match.range(at: 2), in: token),
                      let startLine = Int(token[startRange]) else { return nil }
                
                let path = String(token[pathRange])
                var endLine: Int? = nil
                if match.range(at: 3).location != NSNotFound,
                   let endRange = Range(match.range(at: 3), in: token) {
                    endLine = Int(token[endRange])
                }
                
                return (path, startLine, endLine)
            }
            
            // Helper to extract mode flags, global flags, paths, and slices from tokens
            func extractFlagsAndPaths(from tokens: [String]) -> (mode: String?, strict: Bool?, pathDisplay: String?, paths: [String], slices: [[String: Any]]?) {
                let flags = parseFlagArgs(tokens)
                var mode: String? = nil
                var pathDisplay: String? = nil
                var slices: [[String: Any]] = []

                if flags["codemap"] != nil || flags["m"] != nil {
                    mode = "codemap_only"
                }
                if flags["full"] != nil {
                    mode = "full"
                }
                if flags["slices"] != nil {
                    mode = "slices"
                }
                if let modeValue = flags["mode"] {
                    mode = modeValue
                }

                if flags["relative"] != nil {
                    pathDisplay = "relative"
                } else if flags["full-paths"] != nil {
                    pathDisplay = "full"
                }
                if let pathDisplayFlag = flags["path-display"] ?? flags["path_display"] {
                    pathDisplay = pathDisplayFlag
                }

                // Separate slice tokens from plain path tokens
                var plainPaths: [String] = []
                for token in flags.positional {
                    if let parsed = parseSliceToken(token) {
                        let resolvedPath = ctx.resolveWorkspacePathArg(parsed.path)
                        var rangeDict: [String: Any] = ["start_line": parsed.startLine]
                        if let endLine = parsed.endLine {
                            rangeDict["end_line"] = endLine
                        } else {
                            // If no end line, use start line (single line slice)
                            rangeDict["end_line"] = parsed.startLine
                        }
                        slices.append(["path": resolvedPath, "ranges": [rangeDict]])
                    } else {
                        plainPaths.append(ctx.resolveWorkspacePathArg(token))
                    }
                }
                
                // Handle --paths flag for comma-separated paths (these don't support slice syntax)
                if let pathsArg = flags["paths"] ?? flags["path"] ?? flags["p"] {
                    let rawPaths = pathsArg.split(separator: ",")
                    let resolved = rawPaths.map {
                        ctx.resolveWorkspacePathArg(String($0).trimmingCharacters(in: .whitespaces))
                    }
                    plainPaths.append(contentsOf: resolved)
                }

                let strict = parseBoolFlag(flags["strict"])
                
                // If we have slices, auto-set mode to slices if not explicitly set
                if !slices.isEmpty && mode == nil {
                    mode = "slices"
                }
                
                return (mode, strict, pathDisplay, plainPaths, slices.isEmpty ? nil : slices)
            }

            switch op {
            case "add", "remove", "set":
                if parts.count >= 3 {
                    let (mode, strict, pathDisplay, paths, slices) = extractFlagsAndPaths(from: Array(parts.dropFirst(2)))
                    if !paths.isEmpty {
                        args["paths"] = AnyCodableSendable(paths)
                    }
                    if let slices = slices {
                        args["slices"] = AnyCodableSendable(slices)
                    }
                    if let mode = mode {
                        args["mode"] = AnyCodableSendable(mode)
                    }
                    if let strict = strict {
                        args["strict"] = AnyCodableSendable(strict)
                    }
                    if let pathDisplay = pathDisplay {
                        args["path_display"] = AnyCodableSendable(pathDisplay)
                    }
                }
            case "get", "preview":
                args["op"] = AnyCodableSendable(op == "preview" ? "preview" : "get")
                let flags = parseFlagArgs(Array(parts.dropFirst(2)))
                if let viewValue = flags["view"] ?? flags["v"] {
                    args["view"] = AnyCodableSendable(viewValue)
                }
                if flags["files"] != nil || flags["f"] != nil {
                    args["view"] = AnyCodableSendable("files")
                }
                if flags["content"] != nil || flags["c"] != nil {
                    args["view"] = AnyCodableSendable("content")
                }
                if flags["summary"] != nil || flags["s"] != nil {
                    args["view"] = AnyCodableSendable("summary")
                }
                if flags["codemaps"] != nil {
                    args["view"] = AnyCodableSendable("codemaps")
                }

                var pathDisplay: String? = nil
                if flags["relative"] != nil {
                    pathDisplay = "relative"
                } else if flags["full-paths"] != nil {
                    pathDisplay = "full"
                }
                if let pathDisplayFlag = flags["path-display"] ?? flags["path_display"] {
                    pathDisplay = pathDisplayFlag
                }
                if let pathDisplay = pathDisplay {
                    args["path_display"] = AnyCodableSendable(pathDisplay)
                }
            case "clear":
                // Check for mode flag to clear specific mode
                let (mode, _, _, _, _) = extractFlagsAndPaths(from: Array(parts.dropFirst(2)))
                if let mode = mode {
                    args["mode"] = AnyCodableSendable(mode)
                }
            case "promote", "demote":
                // promote/demote paths between full and codemap modes
                if parts.count >= 3 {
                    let flags = parseFlagArgs(Array(parts.dropFirst(2)))
                    var paths = flags.positional.map { ctx.resolveWorkspacePathArg($0) }
                    if let pathsArg = flags["paths"] ?? flags["path"] ?? flags["p"] {
                        let rawPaths = pathsArg.split(separator: ",")
                        let resolved = rawPaths.map {
                            ctx.resolveWorkspacePathArg(String($0).trimmingCharacters(in: .whitespaces))
                        }
                        paths.append(contentsOf: resolved)
                    }
                    if !paths.isEmpty {
                        args["paths"] = AnyCodableSendable(paths)
                    }
                }
            default:
                // Assume it's a path for quick add
                args["op"] = AnyCodableSendable("add")
                let (mode, strict, pathDisplay, paths, slices) = extractFlagsAndPaths(from: Array(parts.dropFirst(1)))
                if !paths.isEmpty {
                    args["paths"] = AnyCodableSendable(paths)
                }
                if let slices = slices {
                    args["slices"] = AnyCodableSendable(slices)
                }
                if let mode = mode {
                    args["mode"] = AnyCodableSendable(mode)
                }
                if let strict = strict {
                    args["strict"] = AnyCodableSendable(strict)
                }
                if let pathDisplay = pathDisplay {
                    args["path_display"] = AnyCodableSendable(pathDisplay)
                }
            }
            return .aliasCall(toolName: "manage_selection", args: args)

        // Prompt management: prompt [get|set|append|clear|export|list_presets|select_preset|presets|preset] [text|path|preset] or prompt {json}
        // export: prompt export <path> - exports the complete prompt context to a file
        // presets/list_presets: lists all available copy presets
        // preset/select_preset <name|kind|uuid>: selects a copy preset in the UI
        case "prompt":
            // Prompt is a CLI shorthand over the prompt and workspace_context tools.
            if let remainder = rawRemainderAfterFirstToken(input),
               remainder.hasPrefix("{") || remainder.hasPrefix("[") {
                throw CommandParseError.invalidArgument("prompt no longer accepts raw JSON. Use the prompt or workspace_context tool directly.")
            }
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            if let opFlag = flags["op"] {
                var args: [String: AnyCodableSendable] = ["op": AnyCodableSendable(opFlag)]
                if opFlag == "set" || opFlag == "append" {
                    let text = flags["text"] ?? flags.positional.joined(separator: " ")
                    if !text.isEmpty {
                        args["text"] = AnyCodableSendable(text)
                    }
                } else if opFlag == "export" {
                    if let pathArg = flags["path"] ?? flags["p"] ?? flags.positional.first {
                        args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(pathArg))
                    }
					if let presetArg = flags["preset"] ?? flags["copy-preset"] ?? flags["copy_preset"] {
						args["copy_preset"] = AnyCodableSendable(presetArg)
					}
                }
                if opFlag == "export" || opFlag == "list_presets" || opFlag == "select_preset" {
                    return .aliasCall(toolName: "workspace_context", args: args)
                }
                return .aliasCall(toolName: "prompt", args: args)
            }
            // Fall back to alias parsing
            if parts.count < 2 {
                return .aliasCall(toolName: "prompt", args: [
                    "op": AnyCodableSendable("get")
                ])
            }
            let op = parts[1].lowercased()
            var args: [String: AnyCodableSendable] = ["op": AnyCodableSendable(op)]
            if op == "set" || op == "append" {
                // Use raw remainder to preserve spacing in text
                if let fullRemainder = rawRemainderAfterFirstToken(input) {
                    // Skip the op token to get just the text
                    let afterOp = fullRemainder.dropFirst(op.count).trimmingCharacters(in: .whitespaces)
                    if !afterOp.isEmpty {
                        args["text"] = AnyCodableSendable(afterOp)
                    }
                }
            } else if op == "export" {
                // prompt export <path> [--path <path>]
                if let pathArg = flags["path"] ?? flags["p"] ?? flags.positional.dropFirst().first {
                    args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(pathArg))
                } else if parts.count >= 3 {
                    // prompt export path/to/file.txt
                    args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(parts[2]))
                }
				if let presetArg = flags["preset"] ?? flags["copy-preset"] ?? flags["copy_preset"] {
					args["copy_preset"] = AnyCodableSendable(presetArg)
				}
            } else if op == "presets" || op == "list_presets" {
                // prompt presets - list all available copy presets
                args["op"] = AnyCodableSendable("list_presets")
            } else if op == "preset" || op == "select_preset" {
                // prompt preset <name|kind|uuid> - select a copy preset
                args["op"] = AnyCodableSendable("select_preset")
                if let presetArg = flags["preset"] ?? flags.positional.dropFirst().first {
                    args["preset"] = AnyCodableSendable(presetArg)
                } else if parts.count >= 3 {
                    // prompt preset mcpBuilder
                    args["preset"] = AnyCodableSendable(parts[2])
                }
            }
            if op == "export" || op == "list_presets" || op == "select_preset" || op == "presets" || op == "preset" {
                return .aliasCall(toolName: "workspace_context", args: args)
            }
            return .aliasCall(toolName: "prompt", args: args)

        // Edit file: requires JSON format for reliable escape handling
        case "edit", "replace":
            throw CommandParseError.jsonRequired("apply_edits")

        // Chat: chat <message> [--mode chat|plan|edit|review] [--model <model>] [--name <name>] [--chat-id <id>] [--paths <paths>] [--no-diffs]
		case "chat":
			let remaining = Array(parts.dropFirst())
			let flags = parseFlagArgs(remaining)
			let message = flags.positional.joined(separator: " ")
			guard !message.isEmpty else {
				throw CommandParseError.missingArgument("message")
			}
			var isNewChat = flags["new"] != nil
			if let newChatValue = parseBoolFlag(flags["new-chat"] ?? flags["new_chat"]) {
				isNewChat = newChatValue
			}
            let chatMode = flags["mode"] ?? "chat"
			var args: [String: AnyCodableSendable] = [
				"message": AnyCodableSendable(message),
				"new_chat": AnyCodableSendable(isNewChat),
                "mode": AnyCodableSendable(chatMode)
            ]
            if let model = flags["model"] ?? flags["m"] {
                args["model"] = AnyCodableSendable(model)
            }
            if let name = flags["chat-name"] ?? flags["chat_name"] ?? flags["name"] ?? flags["n"] {
                args["chat_name"] = AnyCodableSendable(name)
            }
            if let chatId = flags["chat-id"] ?? flags["chat_id"] ?? flags["c"] {
                args["chat_id"] = AnyCodableSendable(chatId)
            }
            if let includeDiffs = parseBoolFlag(flags["include-diffs"] ?? flags["include_diffs"]) {
                args["include_diffs"] = AnyCodableSendable(includeDiffs)
            }
            if flags["no-diffs"] != nil {
                args["include_diffs"] = AnyCodableSendable(false)
            }
			return .aliasCall(toolName: "oracle_send", args: args)

        // New chat: newchat <message> [--model <model>] [--name <name>] [--mode chat|plan|edit|review] [--paths <paths>] [--no-diffs]
        case "newchat":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            let message = flags.positional.joined(separator: " ")
            guard !message.isEmpty else {
                throw CommandParseError.missingArgument("message")
            }
            let chatMode = flags["mode"] ?? "chat"
            var args: [String: AnyCodableSendable] = [
                "message": AnyCodableSendable(message),
                "new_chat": AnyCodableSendable(true),
                "mode": AnyCodableSendable(chatMode)
            ]
            if let model = flags["model"] ?? flags["m"] {
                args["model"] = AnyCodableSendable(model)
            }
            if let name = flags["chat-name"] ?? flags["chat_name"] ?? flags["name"] ?? flags["n"] {
                args["chat_name"] = AnyCodableSendable(name)
            }
            if let chatId = flags["chat-id"] ?? flags["chat_id"] ?? flags["c"] {
                args["chat_id"] = AnyCodableSendable(chatId)
            }
            if let includeDiffs = parseBoolFlag(flags["include-diffs"] ?? flags["include_diffs"]) {
                args["include_diffs"] = AnyCodableSendable(includeDiffs)
            }
            if flags["no-diffs"] != nil {
                args["include_diffs"] = AnyCodableSendable(false)
            }
            if let newChatValue = parseBoolFlag(flags["new-chat"] ?? flags["new_chat"]) {
                args["new_chat"] = AnyCodableSendable(newChatValue)
            }
			return .aliasCall(toolName: "oracle_send", args: args)
        // Plan: plan <message> [--model <model>] [--name <name>] [--chat-id <id>] [--continue] [--paths <paths>] [--no-diffs]
        // Defaults to new_chat=true (starts fresh). Use --continue or --new-chat=false to continue existing chat.
        case "plan":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            let message = flags.positional.joined(separator: " ")
            guard !message.isEmpty else {
                throw CommandParseError.missingArgument("message")
            }
            var isNewChat = true  // Default to new chat for plan mode
            if flags["continue"] != nil || flags["c"] != nil {
                isNewChat = false
            }
            if let newChatValue = parseBoolFlag(flags["new-chat"] ?? flags["new_chat"]) {
                isNewChat = newChatValue
            }
            var args: [String: AnyCodableSendable] = [
                "message": AnyCodableSendable(message),
                "new_chat": AnyCodableSendable(isNewChat),
                "mode": AnyCodableSendable("plan")
            ]
            if let model = flags["model"] ?? flags["m"] {
                args["model"] = AnyCodableSendable(model)
            }
            if let name = flags["chat-name"] ?? flags["chat_name"] ?? flags["name"] ?? flags["n"] {
                args["chat_name"] = AnyCodableSendable(name)
            }
            if let chatId = flags["chat-id"] ?? flags["chat_id"] ?? flags["c"] {
                args["chat_id"] = AnyCodableSendable(chatId)
            }
            if let includeDiffs = parseBoolFlag(flags["include-diffs"] ?? flags["include_diffs"]) {
                args["include_diffs"] = AnyCodableSendable(includeDiffs)
            }
            if flags["no-diffs"] != nil {
                args["include_diffs"] = AnyCodableSendable(false)
            }
			return .aliasCall(toolName: "oracle_send", args: args)
        // Review: review <message> [--model <model>] [--name <name>] [--chat-id <id>] [--continue] [--paths <paths>] [--no-diffs]
        // Code review mode - analyzes git diffs from selected files. Defaults to new_chat=true.
        case "review":
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            let message = flags.positional.joined(separator: " ")
            guard !message.isEmpty else {
                throw CommandParseError.missingArgument("message")
            }
            var isNewChat = true  // Default to new chat for review mode
            if flags["continue"] != nil || flags["c"] != nil {
                isNewChat = false
            }
            if let newChatValue = parseBoolFlag(flags["new-chat"] ?? flags["new_chat"]) {
                isNewChat = newChatValue
            }
            var args: [String: AnyCodableSendable] = [
                "message": AnyCodableSendable(message),
                "new_chat": AnyCodableSendable(isNewChat),
                "mode": AnyCodableSendable("review")
            ]
            if let model = flags["model"] ?? flags["m"] {
                args["model"] = AnyCodableSendable(model)
            }
            if let name = flags["chat-name"] ?? flags["chat_name"] ?? flags["name"] ?? flags["n"] {
                args["chat_name"] = AnyCodableSendable(name)
            }
            if let chatId = flags["chat-id"] ?? flags["chat_id"] ?? flags["c"] {
                args["chat_id"] = AnyCodableSendable(chatId)
            }
            if let includeDiffs = parseBoolFlag(flags["include-diffs"] ?? flags["include_diffs"]) {
                args["include_diffs"] = AnyCodableSendable(includeDiffs)
            }
            if flags["no-diffs"] != nil {
                args["include_diffs"] = AnyCodableSendable(false)
            }
			return .aliasCall(toolName: "oracle_send", args: args)
        // Chats: compatibility alias for live oracle session listing only.
        case "chats":
            if let remainder = rawRemainderAfterFirstToken(input),
               remainder.hasPrefix("{") || remainder.hasPrefix("[") {
                throw CommandParseError.invalidArgument("chats no longer accepts raw JSON. Use oracle_utils directly.")
            }
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            let subcommand = (flags.positional.first ?? "list").lowercased()

            switch subcommand {
            case "list", "ls", "sessions", "session":
                var args: [String: AnyCodableSendable] = ["op": AnyCodableSendable("sessions")]
                if let limitStr = flags["limit"] ?? flags["l"], let limit = Int(limitStr) {
                    args["limit"] = AnyCodableSendable(limit)
                }
                return .aliasCall(toolName: "oracle_utils", args: args)
            case "log":
				throw CommandParseError.invalidArgument("Chat log reading is only available via oracle_chat_log in agent mode. Use oracle_send with chat_id to continue a session.")
            default:
                throw CommandParseError.invalidArgument("Unknown chats subcommand '\(subcommand)'. Use list or sessions.")
            }

        // Oracle helpers: oracle [models|sessions] [flags]
        case "oracle":
            if let remainder = rawRemainderAfterFirstToken(input),
               remainder.hasPrefix("{") || remainder.hasPrefix("[") {
                return .call(toolName: "oracle_utils", jsonPayload: remainder)
            }
            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            let subcommand = (flags.positional.first ?? flags["op"] ?? "models").lowercased()
            switch subcommand {
            case "models":
                return .aliasCall(toolName: "oracle_utils", args: ["op": AnyCodableSendable("models")])
            case "sessions", "session", "list":
                var args: [String: AnyCodableSendable] = ["op": AnyCodableSendable("sessions")]
                if let limitStr = flags["limit"] ?? flags["l"], let limit = Int(limitStr) {
                    args["limit"] = AnyCodableSendable(limit)
                }
                return .aliasCall(toolName: "oracle_utils", args: args)
            case "log":
				throw CommandParseError.invalidArgument("Oracle log reading is only available via oracle_chat_log in agent mode.")
            default:
                throw CommandParseError.invalidArgument("Unknown oracle subcommand '\(subcommand)'. Use models or sessions.")
            }

        // Models: models
        case "models":
			return .aliasCall(toolName: "oracle_utils", args: ["op": AnyCodableSendable("models")])

        // Tabs: tabs [list|create|close]
        case "tabs":
            if parts.count < 2 {
                return .aliasCall(toolName: "bind_context", args: ["op": AnyCodableSendable("list")])
            }

            let action = parts[1].lowercased()
            let remaining = Array(parts.dropFirst(2))
            let flags = parseFlagArgs(remaining)

            switch action {
            case "list", "ls":
                var args: [String: AnyCodableSendable] = ["op": AnyCodableSendable("list")]
                if let windowIDStr = flags["window-id"] ?? flags["window_id"] ?? flags["window"],
                   let windowID = Int(windowIDStr) {
                    args["window_id"] = AnyCodableSendable(windowID)
                }
                return .aliasCall(toolName: "bind_context", args: args)
            case "select":
                var args: [String: AnyCodableSendable] = ["action": AnyCodableSendable("select_tab")]
                if let tab = flags["tab"] ?? flags["t"] ?? flags.positional.first {
                    args["tab"] = AnyCodableSendable(tab)
                }
                if let focus = parseBoolFlag(flags["focus"]) {
                    args["focus"] = AnyCodableSendable(focus)
                } else if flags["focus"] != nil {
                    args["focus"] = AnyCodableSendable(true)
                }
                if let windowIDStr = flags["window-id"] ?? flags["window_id"] ?? flags["window"],
                   let windowID = Int(windowIDStr) {
                    args["window_id"] = AnyCodableSendable(windowID)
                }
                return .aliasCall(toolName: "manage_workspaces", args: args)
            case "create":
                var args: [String: AnyCodableSendable] = ["action": AnyCodableSendable("create_tab")]
                if let name = flags["name"] ?? flags.positional.first {
                    args["name"] = AnyCodableSendable(name)
                }
                if let mode = flags["mode"]?.lowercased(), ["blank", "fork"].contains(mode) {
                    args["mode"] = AnyCodableSendable(mode)
                }
                if let sourceTab = flags["source-tab"] ?? flags["source_tab"] ?? flags["source"] {
                    args["source_tab"] = AnyCodableSendable(sourceTab)
                    if args["mode"] == nil {
                        args["mode"] = AnyCodableSendable("fork")
                    }
                }
                if let bind = parseBoolFlag(flags["bind"]) {
                    args["bind"] = AnyCodableSendable(bind)
                } else if flags["bind"] != nil {
                    args["bind"] = AnyCodableSendable(true)
                }
                if let focus = parseBoolFlag(flags["focus"]) {
                    args["focus"] = AnyCodableSendable(focus)
                } else if flags["focus"] != nil {
                    args["focus"] = AnyCodableSendable(true)
                }
                if let windowIDStr = flags["window-id"] ?? flags["window_id"] ?? flags["window"],
                   let windowID = Int(windowIDStr) {
                    args["window_id"] = AnyCodableSendable(windowID)
                }
                return .aliasCall(toolName: "manage_workspaces", args: args)
            case "close":
                var args: [String: AnyCodableSendable] = ["action": AnyCodableSendable("close_tab")]
                if let tab = flags["tab"] ?? flags.positional.first {
                    args["tab"] = AnyCodableSendable(tab)
                }
                if let allowActive = parseBoolFlag(flags["allow-active"] ?? flags["allow_active"]) {
                    args["allow_active"] = AnyCodableSendable(allowActive)
                } else if flags["allow-active"] != nil || flags["allow_active"] != nil {
                    args["allow_active"] = AnyCodableSendable(true)
                }
                if let windowIDStr = flags["window-id"] ?? flags["window_id"] ?? flags["window"],
                   let windowID = Int(windowIDStr) {
                    args["window_id"] = AnyCodableSendable(windowID)
                }
                return .aliasCall(toolName: "manage_workspaces", args: args)
            default:
                throw CommandParseError.invalidArgument("Unknown tabs action '\(action)'. Use list, select, create, or close.")
            }

        // Workspaces: workspace [list|switch|tabs|tab|create|add-folder|remove-folder] [args]
        case "workspace", "ws":
            var args: [String: AnyCodableSendable] = ["action": AnyCodableSendable("list")]
            if parts.count >= 2 {
                let action = parts[1].lowercased()
                let remaining = Array(parts.dropFirst(2))
                let flags = parseFlagArgs(remaining)

                switch action {
                case "list", "ls":
                    args["action"] = AnyCodableSendable("list")
					if let includeHidden = parseBoolFlag(flags["include-hidden"] ?? flags["include_hidden"]) {
						args["include_hidden"] = AnyCodableSendable(includeHidden)
					} else if flags["include-hidden"] != nil || flags["include_hidden"] != nil {
						args["include_hidden"] = AnyCodableSendable(true)
					}
                case "tabs":
                    args["action"] = AnyCodableSendable("list_tabs")
                case "switch":
                    args["action"] = AnyCodableSendable("switch")
                    if let ws = flags["workspace"] ?? flags.positional.first {
                        args["workspace"] = AnyCodableSendable(ws)
                    }
                    // Support --new-window flag to open in a new window
                    if let newWindow = parseBoolFlag(flags["new-window"] ?? flags["new_window"]) {
                        args["open_in_new_window"] = AnyCodableSendable(newWindow)
                    } else if flags["new-window"] != nil || flags["new_window"] != nil {
                        // Flag present without value means true
                        args["open_in_new_window"] = AnyCodableSendable(true)
                    }
					if let includeHidden = parseBoolFlag(flags["include-hidden"] ?? flags["include_hidden"]) {
						args["include_hidden"] = AnyCodableSendable(includeHidden)
					} else if flags["include-hidden"] != nil || flags["include_hidden"] != nil {
						args["include_hidden"] = AnyCodableSendable(true)
					}
				case "hide":
					args["action"] = AnyCodableSendable("hide")
					if let ws = flags["workspace"] ?? flags.positional.first {
						args["workspace"] = AnyCodableSendable(ws)
					}
				case "unhide":
					args["action"] = AnyCodableSendable("unhide")
					if let ws = flags["workspace"] ?? flags.positional.first {
						args["workspace"] = AnyCodableSendable(ws)
					}
                case "tab":
                    args["action"] = AnyCodableSendable("select_tab")
                    if let tab = flags["tab"] ?? flags.positional.first {
                        args["tab"] = AnyCodableSendable(tab)
                    }
                    if let focus = parseBoolFlag(flags["focus"]) {
                        args["focus"] = AnyCodableSendable(focus)
                    } else if flags["focus"] != nil {
                        args["focus"] = AnyCodableSendable(true)
                    }
                case "create":
                    args["action"] = AnyCodableSendable("create")
                    if let name = flags["name"] ?? flags.positional.first {
                        args["name"] = AnyCodableSendable(name)
                    }
                    if let path = flags["folder-path"] ?? flags["folder_path"] ?? flags["path"] ?? flags.positional.dropFirst().first {
                        args["folder_path"] = AnyCodableSendable(ctx.resolvePathArg(path))
                    }
                    if let newWindow = parseBoolFlag(flags["new-window"] ?? flags["new_window"]) {
                        args["open_in_new_window"] = AnyCodableSendable(newWindow)
                    } else if flags["new-window"] != nil || flags["new_window"] != nil {
                        args["open_in_new_window"] = AnyCodableSendable(true)
                    }
                    if let switchToCreated = parseBoolFlag(flags["switch"] ?? flags["activate"]) {
                        args["switch_to_created"] = AnyCodableSendable(switchToCreated)
                    } else if flags["switch"] != nil || flags["activate"] != nil {
                        args["switch_to_created"] = AnyCodableSendable(true)
                    }
                case "add-folder", "add_folder":
                    args["action"] = AnyCodableSendable("add_folder")
                    if let path = flags["folder-path"] ?? flags["folder_path"] ?? flags["path"] ?? flags.positional.first {
                        args["folder_path"] = AnyCodableSendable(ctx.resolvePathArg(path))
                    }
                    if let ws = flags["workspace"] ?? flags.positional.dropFirst().first {
                        args["workspace"] = AnyCodableSendable(ws)
                    }
                case "remove-folder", "remove_folder":
                    args["action"] = AnyCodableSendable("remove_folder")
                    if let path = flags["folder-path"] ?? flags["folder_path"] ?? flags["path"] ?? flags.positional.first {
                        args["folder_path"] = AnyCodableSendable(ctx.resolvePathArg(path))
                    }
                    if let ws = flags["workspace"] ?? flags.positional.dropFirst().first {
                        args["workspace"] = AnyCodableSendable(ws)
                    }
				case "delete":
					args["action"] = AnyCodableSendable("delete")
					if let ws = flags["workspace"] ?? flags.positional.first {
						args["workspace"] = AnyCodableSendable(ws)
					}
					if let closeWindow = parseBoolFlag(flags["close-window"] ?? flags["close_window"]) {
						args["close_window"] = AnyCodableSendable(closeWindow)
					} else if flags["close-window"] != nil || flags["close_window"] != nil {
						args["close_window"] = AnyCodableSendable(true)
					}
					if let includeHidden = parseBoolFlag(flags["include-hidden"] ?? flags["include_hidden"]) {
						args["include_hidden"] = AnyCodableSendable(includeHidden)
					} else if flags["include-hidden"] != nil || flags["include_hidden"] != nil {
						args["include_hidden"] = AnyCodableSendable(true)
					}
				default:
                    // Assume it's a workspace name to switch to (preserve original case)
                    args["action"] = AnyCodableSendable("switch")
                    args["workspace"] = AnyCodableSendable(parts[1])
                    // Support --new-window flag even in shorthand form: workspace MyProject --new-window
                    if let newWindow = parseBoolFlag(flags["new-window"] ?? flags["new_window"]) {
                        args["open_in_new_window"] = AnyCodableSendable(newWindow)
                    } else if flags["new-window"] != nil || flags["new_window"] != nil {
                        args["open_in_new_window"] = AnyCodableSendable(true)
                    }
					if let includeHidden = parseBoolFlag(flags["include-hidden"] ?? flags["include_hidden"]) {
						args["include_hidden"] = AnyCodableSendable(includeHidden)
					} else if flags["include-hidden"] != nil || flags["include_hidden"] != nil {
						args["include_hidden"] = AnyCodableSendable(true)
					}
                }

                if let windowIDStr = flags["window-id"] ?? flags["window_id"] ?? flags["window"],
                   let windowID = Int(windowIDStr) {
                    args["window_id"] = AnyCodableSendable(windowID)
                }
            }
            return .aliasCall(toolName: "manage_workspaces", args: args)

        // File operations: requires JSON format for reliable escape handling
        case "file":
            throw CommandParseError.jsonRequired("file_actions")

        // Git: git [status|diff|log|show|blame] [options]
        case "git":
            // Check for JSON payload first
            if let remainder = rawRemainderAfterFirstToken(input),
               remainder.hasPrefix("{") || remainder.hasPrefix("[") {
                return .call(toolName: "git", jsonPayload: remainder)
            }

            let remaining = Array(parts.dropFirst())
            let flags = parseFlagArgs(remaining)
            var args: [String: AnyCodableSendable] = [:]

            // Determine operation from first positional or --op flag
            let op: String
            if let opFlag = flags["op"] {
                op = opFlag.lowercased()
            } else if let firstPos = flags.positional.first {
                // Check if it's a known op
                let knownOps = ["status", "diff", "log", "show", "blame"]
                if knownOps.contains(firstPos.lowercased()) {
                    op = firstPos.lowercased()
                } else {
                    // Default to status if no recognized op
                    op = "status"
                }
            } else {
                op = "status"
            }
            args["op"] = AnyCodableSendable(op)

            // Common flags
            if let repoRoot = flags["repo-root"] ?? flags["repo_root"] ?? flags["root"] {
                args["repo_root"] = AnyCodableSendable(ctx.resolveRepoRootArg(repoRoot))
            }
            if let repoRootsStr = flags["repo-roots"] ?? flags["repo_roots"] {
                let repoRoots = repoRootsStr.split(separator: ",").map { ctx.resolveRepoRootArg(String($0)) }
                args["repo_roots"] = AnyCodableSendable(repoRoots)
            }
            if let compare = flags["compare"] ?? flags["c"] {
                args["compare"] = AnyCodableSendable(compare)
            }
            if let detail = flags["detail"] ?? flags["d"] {
                args["detail"] = AnyCodableSendable(detail)
            }
            // Convenience flags for detail level
            if flags["summary"] != nil { args["detail"] = AnyCodableSendable("summary") }
            if flags["files"] != nil { args["detail"] = AnyCodableSendable("files") }
            if flags["patches"] != nil { args["detail"] = AnyCodableSendable("patches") }
            if flags["full"] != nil { args["detail"] = AnyCodableSendable("full") }
            // Remap legacy --truncate flag to detail level (only if detail wasn't explicitly set)
            if args["detail"] == nil, let truncateRaw = flags["truncate"] ?? flags["t"] {
                if let truncateVal = parseBoolFlag(truncateRaw) {
                    args["detail"] = AnyCodableSendable(truncateVal ? "patches" : "full")
                } else {
                    // bare --truncate (no value) means truncation on → patches
                    args["detail"] = AnyCodableSendable("patches")
                }
            }

            if let mode = flags["mode"] ?? flags["m"] {
                args["mode"] = AnyCodableSendable(mode)
            }
            if let scope = flags["scope"] ?? flags["s"] {
                args["scope"] = AnyCodableSendable(scope)
            }
            if let path = flags["path"] ?? flags["p"] {
                args["path"] = AnyCodableSendable(path)
            }
            if let pathsStr = flags["paths"] {
                let paths = pathsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                args["paths"] = AnyCodableSendable(paths)
            }
            if let contextLines = flags["context-lines"] ?? flags["context_lines"] ?? flags["C"], let val = Int(contextLines) {
                args["context_lines"] = AnyCodableSendable(val)
            }
            if let detectRenames = parseBoolFlag(flags["detect-renames"] ?? flags["detect_renames"] ?? flags["renames"]) {
                args["detect_renames"] = AnyCodableSendable(detectRenames)
            }
            if let artifacts = parseBoolFlag(flags["artifacts"] ?? flags["a"]) {
                args["artifacts"] = AnyCodableSendable(artifacts)
            } else if flags["artifacts"] != nil || flags["a"] != nil {
                args["artifacts"] = AnyCodableSendable(true)
            }
            if let reuse = parseBoolFlag(flags["reuse"]) {
                args["reuse"] = AnyCodableSendable(reuse)
            } else if flags["reuse"] != nil {
                args["reuse"] = AnyCodableSendable(true)
            }

            // Inline object for MAP excerpt
            var inlineObj: [String: Any] = [:]
            if let inlineMap = parseBoolFlag(flags["inline-map"] ?? flags["inline_map"]) {
                inlineObj["map"] = inlineMap
            } else if flags["inline-map"] != nil || flags["inline_map"] != nil {
                inlineObj["map"] = true
            }
            if let inlineMode = flags["inline-mode"] ?? flags["inline_mode"] {
                inlineObj["mode"] = inlineMode
            }
            if let inlineMaxLines = flags["inline-max-lines"] ?? flags["inline_max_lines"], let val = Int(inlineMaxLines) {
                inlineObj["max_lines"] = val
            }
            if !inlineObj.isEmpty {
                args["inline"] = AnyCodableSendable(inlineObj)
            }

            // Operation-specific handling
            switch op {
            case "show":
                // git show <ref> or git show --ref <ref>
                if let ref = flags["ref"] ?? flags["r"] {
                    args["ref"] = AnyCodableSendable(ref)
                } else {
                    // Second positional (after "show") is the ref
                    let positionalAfterOp = flags.positional.dropFirst()
                    if let refArg = positionalAfterOp.first {
                        args["ref"] = AnyCodableSendable(refArg)
                    }
                }

            case "blame":
                // git blame <path> --lines 10-40
                if args["path"] == nil {
                    // Second positional (after "blame") is the path
                    let positionalAfterOp = flags.positional.dropFirst()
                    if let pathArg = positionalAfterOp.first {
                        args["path"] = AnyCodableSendable(pathArg)
                    }
                }
                if let lines = flags["lines"] ?? flags["l"] {
                    args["lines"] = AnyCodableSendable(lines)
                }

            case "log":
                // git log --count 20
                if let count = flags["count"] ?? flags["n"], let val = Int(count) {
                    args["count"] = AnyCodableSendable(val)
                }

            default:
                // status, diff - no additional special handling needed
                break
            }

            return .aliasCall(toolName: "git", args: args)

        // ════════════════════════════════════════════════════════════
        // RAW MCP TOOL NAMES - Direct tool invocation with key=value args
        // ════════════════════════════════════════════════════════════
        case "state":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "manage_selection", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "manage_selection", args: parsed.args)

        case "manage_selection":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "manage_selection", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "manage_selection", args: parsed.args)

        case "workspace_context":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "workspace_context", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "workspace_context", args: parsed.args)

        case "read_file":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "read_file", jsonPayload: parsed.jsonPayload)
            }
            var args = parsed.args
            if let pathValue = args["path"]?.value as? String {
                args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(pathValue))
            }
            return .aliasCall(toolName: "read_file", args: args)

        case "file_search":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "file_search", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "file_search", args: parsed.args)

        case "get_file_tree":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "get_file_tree", jsonPayload: parsed.jsonPayload)
            }
            var args = parsed.args
            if let pathValue = args["path"]?.value as? String {
                args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(pathValue))
            }
            return .aliasCall(toolName: "get_file_tree", args: args)

        case "get_code_structure":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "get_code_structure", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "get_code_structure", args: parsed.args)

        case "apply_edits":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "apply_edits", jsonPayload: parsed.jsonPayload)
            }
            var args = parsed.args
            if let pathValue = args["path"]?.value as? String {
                args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(pathValue))
            }
            return .aliasCall(toolName: "apply_edits", args: args)

        case "ask_oracle", "oracle_send":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
				return .call(toolName: "oracle_send", jsonPayload: parsed.jsonPayload)
            }
			return .aliasCall(toolName: "oracle_send", args: parsed.args)

        case "oracle_utils":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
				return .call(toolName: "oracle_utils", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "oracle_utils", args: parsed.args)

        case "manage_workspaces":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "manage_workspaces", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "manage_workspaces", args: parsed.args)

		case "bind_context":
			let parsed = parseRawToolArgs(input, toolName: first)
			if parsed.isJSON {
				return .call(toolName: "bind_context", jsonPayload: parsed.jsonPayload)
			}
			return .aliasCall(toolName: "bind_context", args: parsed.args)

        case "app_settings":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "app_settings", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "app_settings", args: parsed.args)

        case "file_actions":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "file_actions", jsonPayload: parsed.jsonPayload)
            }
            var args = parsed.args
            if let pathValue = args["path"]?.value as? String {
                args["path"] = AnyCodableSendable(ctx.resolveWorkspacePathArg(pathValue))
            }
            return .aliasCall(toolName: "file_actions", args: args)

        case "context_builder":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "context_builder", jsonPayload: parsed.jsonPayload)
            }
            // Normalize instruction aliases (task, prompt, query, etc. -> instructions)
            var args = parsed.args
            try normalizeContextBuilderArgs(&args)

            // Validate required instructions parameter
            let hasInstructions: Bool
            if let instructionsValue = args["instructions"]?.value as? String {
                hasInstructions = !instructionsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                hasInstructions = false
            }

            guard hasInstructions else {
                throw CommandParseError.missingArgument(
                    """
                    instructions (required)

                    Usage:
                      context_builder task="your task description"
                      context_builder instructions="..." response_type=plan

                    Optional: response_type=plan|question|clarify, export_response=true
                    """
                )
            }

            return .aliasCall(toolName: "context_builder", args: args)

        case "agent_run":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "agent_run", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "agent_run", args: parsed.args)

        case "ask_user":
            let parsed = parseRawToolArgs(input, toolName: first)
            if parsed.isJSON {
                return .call(toolName: "ask_user", jsonPayload: parsed.jsonPayload)
            }
            return .aliasCall(toolName: "ask_user", args: parsed.args)

        case "agent_manage":
			if let remainder = rawRemainderAfterFirstToken(input),
				remainder.hasPrefix("{") || remainder.hasPrefix("[") {
				return .call(toolName: "agent_manage", jsonPayload: remainder)
            }

			if parts.count >= 2 {
				let action = parts[1].lowercased()
				if action == "handoff" || action == "extract_handoff" {
					let flags = parseFlagArgs(Array(parts.dropFirst(2)))
					func requireFlagValue(_ value: String?, name: String) throws -> String? {
						guard let value else { return nil }
						let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
						guard !trimmed.isEmpty, trimmed.lowercased() != "true" else {
							throw CommandParseError.missingArgument(name)
						}
						return value
					}
					guard let sessionID = flags["session-id"] ?? flags["session_id"] ?? flags.positional.first else {
						throw CommandParseError.missingArgument("session_id")
					}
					var args: [String: AnyCodableSendable] = [
						"op": AnyCodableSendable("extract_handoff"),
						"session_id": AnyCodableSendable(sessionID)
					]
					if let output = try requireFlagValue(flags["output"] ?? flags["output-path"] ?? flags["output_path"] ?? flags["o"], name: "output_path") {
						args["output_path"] = AnyCodableSendable(ctx.resolvePathArg(output))
					}
					if let cutoff = flags["up-to-item-id"] ?? flags["up_to_item_id"] ?? flags["cutoff"] {
						args["up_to_item_id"] = AnyCodableSendable(cutoff)
					}
					if let includeFileContents = parseBoolFlag(flags["include-file-contents"] ?? flags["include_file_contents"]) {
						args["include_file_contents"] = AnyCodableSendable(includeFileContents)
					} else if flags["include-file-contents"] != nil || flags["include_file_contents"] != nil {
						args["include_file_contents"] = AnyCodableSendable(true)
					}
					if let inline = parseBoolFlag(flags["inline"]) {
						args["inline"] = AnyCodableSendable(inline)
					} else if flags["inline"] != nil {
						args["inline"] = AnyCodableSendable(true)
					}
					if flags["no-overwrite"] != nil || flags["no_overwrite"] != nil {
						args["overwrite"] = AnyCodableSendable(false)
					} else if let overwrite = parseBoolFlag(flags["overwrite"]) {
						args["overwrite"] = AnyCodableSendable(overwrite)
					} else if flags["overwrite"] != nil {
						args["overwrite"] = AnyCodableSendable(true)
					}
					if let maxItems = flags["max-transcript-items"] ?? flags["max_transcript_items"] {
						guard let value = Int(maxItems) else {
							throw CommandParseError.invalidArgument("max_transcript_items must be an integer")
						}
						args["max_transcript_items"] = AnyCodableSendable(value)
					}
					if let maxArgs = flags["max-tool-args-characters"] ?? flags["max_tool_args_characters"] ?? flags["max-tool-args"] ?? flags["max_tool_args"] {
						guard let value = Int(maxArgs) else {
							throw CommandParseError.invalidArgument("max_tool_args_characters must be an integer")
						}
						args["max_tool_args_characters"] = AnyCodableSendable(value)
					}
					return .aliasCall(toolName: "agent_manage", args: args)
				}
			}

			let parsed = parseRawToolArgs(input, toolName: first)
            return .aliasCall(toolName: "agent_manage", args: parsed.args)

        default:
            throw CommandParseError.unknownCommand(first)
        }
    }

    /// Result of parsing --flag value style arguments.
    struct FlagParseResult {
        var named: [String: String] = [:]
        var positional: [String] = []

        /// Looks up a flag value, normalizing dashes and underscores.
        /// Both `response-type` and `response_type` will find either variant.
        subscript(_ key: String) -> String? {
            // Try exact match first
            if let value = named[key] {
                return value
            }
            // Try with dashes converted to underscores
            let underscored = key.replacingOccurrences(of: "-", with: "_")
            if let value = named[underscored] {
                return value
            }
            // Try with underscores converted to dashes
            let dashed = key.replacingOccurrences(of: "_", with: "-")
            return named[dashed]
        }
    }

    /// Returns the raw remainder of input after the first token.
    /// Preserves original spacing and quotes for JSON passthrough.
    /// Returns nil if no remainder exists.
    private static func rawRemainderAfterFirstToken(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        // Find the end of the first token (command name)
        var inQuote: Character? = nil
        var i = trimmed.startIndex
        // Skip leading whitespace (shouldn't be any after trim, but be safe)
        while i < trimmed.endIndex && trimmed[i].isWhitespace {
            i = trimmed.index(after: i)
        }
        // Skip the command token
        while i < trimmed.endIndex {
            let ch = trimmed[i]
            if let q = inQuote {
                if ch == q { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch.isWhitespace {
                break
            }
            i = trimmed.index(after: i)
        }
        // Skip whitespace after command
        while i < trimmed.endIndex && trimmed[i].isWhitespace {
            i = trimmed.index(after: i)
        }
        guard i < trimmed.endIndex else { return nil }
        return String(trimmed[i...])
    }

    /// Checks if a token is a numeric literal (including negative numbers like "-5", "-10").
    /// Used to distinguish negative numbers from short flags.
    private static func isNumericLiteralToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var chars = s.makeIterator()
        let first = chars.next()!
        // Allow optional leading minus
        let startChar = (first == "-") ? chars.next() : first
        guard let start = startChar, start.isNumber else { return false }
        // Rest must be digits or decimal point
        while let ch = chars.next() {
            if !ch.isNumber && ch != "." { return false }
        }
        return true
    }

    /// Checks if a token looks like a flag (--something or -x where x is a letter).
    /// Used to distinguish actual flags from values that happen to start with a dash.
    /// Examples:
    ///   "--task" -> true (long flag)
    ///   "-t" -> true (short flag)
    ///   "-5" -> false (negative number)
    ///   "- change" -> false (text starting with dash)
    ///   "-/path" -> false (path starting with dash)
    private static func looksLikeFlagToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }

        // Long flags: --something
        if s.hasPrefix("--") {
            // Must have at least one character after --
            return s.count > 2
        }

        // Short flags: -x where x is a letter
        if s.hasPrefix("-") && s.count == 2 {
            let afterDash = s.dropFirst().first!
            return afterDash.isLetter
        }

        return false
    }

    /// Parses --flag value style arguments.
    /// Returns both named flags and positional arguments.
    /// Supports: --flag value, --flag=value, -f value
    /// Handles values starting with dash correctly (e.g., "- change bombs")
    private static func parseFlagArgs(_ tokens: [String]) -> FlagParseResult {
        var result = FlagParseResult()
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.hasPrefix("--") && token.count > 2 {
                let flagPart = String(token.dropFirst(2))
                // Check for --flag=value format
                if let eqIdx = flagPart.firstIndex(of: "=") {
                    let key = String(flagPart[..<eqIdx])
                    let value = String(flagPart[flagPart.index(after: eqIdx)...])
                    result.named[key] = value
                } else if i + 1 < tokens.count && !looksLikeFlagToken(tokens[i + 1]) {
                    // --flag value format (next token is not a flag)
                    result.named[flagPart] = tokens[i + 1]
                    i += 1
                } else {
                    // Boolean flag with no value
                    result.named[flagPart] = "true"
                }
            } else if token.hasPrefix("-") && token.count == 2 {
                // Short flag: -f value
                let afterDash = token.dropFirst().first!
                if afterDash.isLetter {
                    // It's a short flag
                    let key = String(token.dropFirst())
                    if i + 1 < tokens.count && !looksLikeFlagToken(tokens[i + 1]) {
                        result.named[key] = tokens[i + 1]
                        i += 1
                    } else {
                        result.named[key] = "true"
                    }
                } else {
                    // Not a flag (e.g., "-5"), treat as positional
                    result.positional.append(token)
                }
            } else {
                // Positional argument (includes negative numbers, paths, etc.)
                result.positional.append(token)
            }
            i += 1
        }
        return result
    }

	/// Parses a boolean flag value (supports true/false, yes/no, on/off, 1/0).
	private static func parseBoolFlag(_ value: String?) -> Bool? {
		guard let value = value else { return nil }
		switch value.lowercased() {
		case "true", "1", "yes", "y", "on":
			return true
		case "false", "0", "no", "n", "off":
			return false
		default:
			return nil
		}
	}

    /// Parses arguments for raw MCP tool calls, handling both JSON and key=value formats.
    /// If input starts with '{' or '[', returns a .call with JSON payload.
    /// Otherwise parses as key=value and returns nil (caller should use aliasCall).
    private static func parseRawToolArgs(_ input: String, toolName: String) -> (isJSON: Bool, jsonPayload: String?, args: [String: AnyCodableSendable]) {
        if let remainder = rawRemainderAfterFirstToken(input),
           (remainder.hasPrefix("{") || remainder.hasPrefix("[")) {
            return (isJSON: true, jsonPayload: remainder, args: [:])
        }
        // Fall back to key=value parsing
        let parts = splitShellWords(input)
		var args = parseKeyValueArgs(Array(parts.dropFirst()))

		// Preserve nested JSON for answer maps. splitShellWords intentionally strips shell
		// quotes, which can turn answers={"id":...} into non-JSON before parseValue sees it.
		if toolName == "agent_run",
			let remainder = rawRemainderAfterFirstToken(input),
			let rawAnswers = extractRawAssignmentValue(named: "answers", from: remainder),
			let parsedAnswers = parsePreservedJSONValue(rawAnswers) {
			args["answers"] = parsedAnswers
		}

        return (isJSON: false, jsonPayload: nil, args: args)
    }

	private static func extractRawAssignmentValue(named key: String, from text: String) -> String? {
		var index = text.startIndex
		while index < text.endIndex {
			let atBoundary = index == text.startIndex || text[text.index(before: index)].isWhitespace
			if atBoundary,
				text[index...].hasPrefix(key),
				let equalsIndex = text.index(index, offsetBy: key.count, limitedBy: text.endIndex),
				equalsIndex < text.endIndex,
				text[equalsIndex] == "=" {
				let valueStart = text.index(after: equalsIndex)
				return extractRawValue(from: text, startingAt: valueStart)
			}
			index = text.index(after: index)
		}
		return nil
	}

	private static func extractRawValue(from text: String, startingAt valueStart: String.Index) -> String? {
		guard valueStart < text.endIndex else { return "" }
		let first = text[valueStart]
		if first == "'" || first == "\"" {
			var index = text.index(after: valueStart)
			var escaped = false
			while index < text.endIndex {
				let ch = text[index]
				if first == "\"", ch == "\\", !escaped {
					escaped = true
					index = text.index(after: index)
					continue
				}
				if ch == first, !escaped {
					return String(text[valueStart...index])
				}
				escaped = false
				index = text.index(after: index)
			}
			return String(text[valueStart...])
		}
		if first == "{" || first == "[" {
			let closing: Character = first == "{" ? "}" : "]"
			var depth = 0
			var index = valueStart
			var inString = false
			var escaped = false
			while index < text.endIndex {
				let ch = text[index]
				if inString {
					if ch == "\\", !escaped {
						escaped = true
					} else {
						if ch == "\"", !escaped { inString = false }
						escaped = false
					}
				} else if ch == "\"" {
					inString = true
				} else if ch == first {
					depth += 1
				} else if ch == closing {
					depth -= 1
					if depth == 0 {
						return String(text[valueStart...index])
					}
				}
				index = text.index(after: index)
			}
			return String(text[valueStart...])
		}
		var index = valueStart
		while index < text.endIndex, !text[index].isWhitespace {
			index = text.index(after: index)
		}
		return String(text[valueStart..<index])
	}

	private static func unwrapShellQuotes(_ value: String) -> String {
		guard value.count >= 2,
				let first = value.first,
				let last = value.last,
				(first == "'" || first == "\""),
				first == last else {
			return value
		}
		return String(value.dropFirst().dropLast())
	}

	private static func parsePreservedJSONValue(_ value: String) -> AnyCodableSendable? {
		let unwrapped = unwrapShellQuotes(value)
		if let parsed = parseJSONValue(unwrapped) {
			return parsed
		}
		let unescapedQuotes = unwrapped.replacingOccurrences(of: "\\\"", with: "\"")
		guard unescapedQuotes != unwrapped else { return nil }
		return parseJSONValue(unescapedQuotes)
	}

    /// Parses key=value and --key value style arguments into a dictionary.
    /// Handles: key=value, --key value, --key=value, key="quoted value", key=true/false, key=123
    /// Also handles: JSON arrays/objects (key=[...], key={...}), dotted keys (filter.paths=src)
    /// Note: Quotes are already stripped by splitShellWords, so we don't strip here.
    /// This preserves intentional quote characters in values.
    /// Keys are normalized: dashes become underscores (response-type -> response_type).
    private static func parseKeyValueArgs(_ tokens: [String]) -> [String: AnyCodableSendable] {
        var args: [String: AnyCodableSendable] = [:]
        var i = 0
        
        while i < tokens.count {
            let token = tokens[i]
            
            // Handle --key=value format
            if token.hasPrefix("--") && token.contains("=") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let rawKey = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let key = rawKey.replacingOccurrences(of: "-", with: "_")
                    let value = String(token[token.index(after: eqIndex)...])
                    let parsedValue = parseValue(value, key: key)
                    
                    if key.contains(".") {
                        mergeNestedKey(into: &args, dottedKey: key, value: parsedValue)
                    } else {
                        args[key] = parsedValue
                    }
                }
                i += 1
                continue
            }
            
            // Handle --key value format (value is next token)
            if token.hasPrefix("--") {
                let rawKey = String(token.dropFirst(2))
                let key = rawKey.replacingOccurrences(of: "-", with: "_")
                
                // Check if next token exists and is a value (not another flag)
                if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                    let value = tokens[i + 1]
                    let parsedValue = parseValue(value, key: key)
                    
                    if key.contains(".") {
                        mergeNestedKey(into: &args, dottedKey: key, value: parsedValue)
                    } else {
                        args[key] = parsedValue
                    }
                    i += 2
                    continue
                } else {
                    // Boolean flag with no value (--verbose means verbose=true)
                    args[key] = AnyCodableSendable(true)
                    i += 1
                    continue
                }
            }
            
            // Handle key=value format
            if let eqIndex = token.firstIndex(of: "=") {
                let rawKey = String(token[..<eqIndex])
                let key = rawKey.replacingOccurrences(of: "-", with: "_")
                let value = String(token[token.index(after: eqIndex)...])
                let parsedValue = parseValue(value, key: key)
                
                if key.contains(".") {
                    mergeNestedKey(into: &args, dottedKey: key, value: parsedValue)
                } else {
                    args[key] = parsedValue
                }
            }
            
            i += 1
        }
        return args
    }
    
    /// Parses a value string into an AnyCodableSendable.
    /// Handles: JSON arrays/objects, booleans, integers, and strings.
    private static func parseValue(_ value: String, key: String? = nil) -> AnyCodableSendable {
        // Try to parse as JSON array or object
        if (value.hasPrefix("[") && value.hasSuffix("]")) ||
           (value.hasPrefix("{") && value.hasSuffix("}")) {
            if let jsonValue = parseJSONValue(value) {
                return jsonValue
            }
            if key == "session_ids", let relaxedArray = parseRelaxedStringArray(value) {
                return relaxedArray
            }
            // Fall through to string if JSON parsing fails
        }
        
        // Try to parse as bool
        if value.lowercased() == "true" {
            return AnyCodableSendable(true)
        } else if value.lowercased() == "false" {
            return AnyCodableSendable(false)
        }
        
        // Try to parse as int
        if let intVal = Int(value) {
            return AnyCodableSendable(intVal)
        }
        
        // Default to string
        return AnyCodableSendable(value)
    }
    
    /// Parses shell-style arrays whose inner JSON string quotes were stripped by splitShellWords.
    /// This is intentionally narrow: it supports `session_ids=[uuid1,uuid2]` after quote removal.
    private static func parseRelaxedStringArray(_ value: String) -> AnyCodableSendable? {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else {
            return AnyCodableSendable([AnyCodableSendable]())
        }
        let items = inner.split(separator: ",", omittingEmptySubsequences: false).map { raw -> String in
            var item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("\"") && item.hasSuffix("\""), item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            }
            return item
        }
        guard items.allSatisfy({ !$0.isEmpty }) else { return nil }
        return AnyCodableSendable(items.map { AnyCodableSendable($0) })
    }

    /// Attempts to parse a JSON string into an AnyCodableSendable.
    /// Returns nil if parsing fails.
    private static func parseJSONValue(_ jsonString: String) -> AnyCodableSendable? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return convertToAnyCodableSendable(parsed)
        } catch {
            return nil
        }
    }
    
    /// Converts a JSONSerialization result to AnyCodableSendable.
    private static func convertToAnyCodableSendable(_ value: Any) -> AnyCodableSendable {
        switch value {
        case let array as [Any]:
            return AnyCodableSendable(array.map { convertToAnyCodableSendable($0) })
        case let dict as [String: Any]:
            var result: [String: AnyCodableSendable] = [:]
            for (k, v) in dict {
                result[k] = convertToAnyCodableSendable(v)
            }
            return AnyCodableSendable(result)
        case let str as String:
            return AnyCodableSendable(str)
        case let num as NSNumber:
            // Check if it's a boolean (NSNumber wraps both)
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return AnyCodableSendable(num.boolValue)
            }
            // Check if it's an integer
            if num.doubleValue == Double(num.intValue) {
                return AnyCodableSendable(num.intValue)
            }
            return AnyCodableSendable(num.doubleValue)
        case is NSNull:
            return AnyCodableSendable(NSNull())
        default:
            return AnyCodableSendable(String(describing: value))
        }
    }
    
    /// Merges a dotted key (e.g., "filter.paths") into a nested dictionary structure.
    /// Example: "filter.paths" with value "src" becomes ["filter": ["paths": "src"]]
    private static func mergeNestedKey(into args: inout [String: AnyCodableSendable], dottedKey: String, value: AnyCodableSendable) {
        let parts = dottedKey.split(separator: ".").map { String($0).replacingOccurrences(of: "-", with: "_") }
        guard !parts.isEmpty else { return }
        
        if parts.count == 1 {
            args[parts[0]] = value
            return
        }
        
        // Build nested structure from the inside out
        var current = value
        for key in parts.dropFirst().reversed() {
            current = AnyCodableSendable([key: current])
        }
        
        // Merge with existing structure at the root key
        let rootKey = parts[0]
        if let existing = args[rootKey] {
            args[rootKey] = mergeAnyCodableSendable(existing, with: current)
        } else {
            args[rootKey] = current
        }
    }
    
    /// Merges two AnyCodableSendable values, combining dictionaries recursively.
    private static func mergeAnyCodableSendable(_ lhs: AnyCodableSendable, with rhs: AnyCodableSendable) -> AnyCodableSendable {
        // If both are dictionaries, merge them recursively
        if let lhsDict = lhs.value as? [String: AnyCodableSendable],
           let rhsDict = rhs.value as? [String: AnyCodableSendable] {
            var merged = lhsDict
            for (key, value) in rhsDict {
                if let existing = merged[key] {
                    merged[key] = mergeAnyCodableSendable(existing, with: value)
                } else {
                    merged[key] = value
                }
            }
            return AnyCodableSendable(merged)
        }
        // Otherwise, rhs wins
        return rhs
    }

    /// Splits a command line into shell-like words, preserving quoted substrings.
    /// Quotes are removed; inside double quotes, common escape sequences are decoded:
    /// - `\"` and `\\` → literal quote and backslash
    /// - `\n`, `\t`, `\r` → newline, tab, carriage return
    /// - Other backslashes (like `\w` in regex) are preserved literally.
    static func splitShellWords(_ input: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(8)

        var current = ""
        var inSingle = false
        var inDouble = false

        func flush() {
            if !current.isEmpty {
                out.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        var iterator = input.makeIterator()
        while let ch = iterator.next() {
            // Inside double quotes, handle escape sequences
            if inDouble && ch == "\\" {
                // Peek at next character
                if let next = iterator.next() {
                    switch next {
                    case "\"", "\\":
                        current.append(next)
                    case "n":
                        current.append("\n")
                    case "t":
                        current.append("\t")
                    case "r":
                        current.append("\r")
                    default:
                        // Preserve backslash for other characters (e.g., \w in regex)
                        current.append("\\")
                        current.append(next)
                    }
                } else {
                    // Trailing backslash at end of input - preserve it
                    current.append("\\")
                }
                continue
            }

            if ch == "'" && !inDouble {
                inSingle.toggle()
                continue
            }

            if ch == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }

            if !inSingle && !inDouble && ch.isWhitespace {
                flush()
                continue
            }

            current.append(ch)
        }

        flush()
        return out
    }

    /// Suggests a command based on typo detection using Levenshtein distance.
    /// Normalizes dashes to underscores before comparison.
    static func suggestCommand(for input: String) -> String? {
        let threshold = 2 // Max edit distance
        var bestMatch: (command: String, distance: Int)? = nil
        // Normalize: convert dashes to underscores for consistent matching
        let normalized = input.lowercased().replacingOccurrences(of: "-", with: "_")

        for cmd in allCommands {
            let dist = levenshteinDistance(normalized, cmd)
            if dist <= threshold {
                if bestMatch == nil || dist < bestMatch!.distance {
                    bestMatch = (cmd, dist)
                }
            }
        }

        return bestMatch?.command
    }

    /// Simple Levenshtein distance for typo detection.
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        if s1.isEmpty { return s2.count }
        if s2.isEmpty { return s1.count }

        let a = Array(s1)
        let b = Array(s2)

        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }

        return prev[b.count]
    }

    /// Parses JSON arguments string into MCP Value dictionary.
    static func parseJSONArgs(_ jsonPayload: String?) throws -> [String: Value]? {
        guard let rawPayload = jsonPayload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPayload.isEmpty else {
            return nil
        }

        let json = try resolveJSONPayload(rawPayload)

        guard let data = json.data(using: .utf8) else {
            throw CommandParseError.invalidJSON("Invalid UTF-8")
        }

        do {
            let decoded = try JSONDecoder().decode([String: Value].self, from: data)
            return decoded
        } catch let originalError {
            // Best-effort repair for common LLM/CLI JSON issues:
            // raw newlines/tabs/control chars inside quoted strings.
            if let repaired = repairJSONStringControlCharacters(in: json),
               let repairedData = repaired.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: Value].self, from: repairedData) {
                return decoded
            }
            throw CommandParseError.invalidJSON("\(originalError.localizedDescription). Tip: for multiline payloads, pass @/path/to/file.json or @-.")
        }
    }

    /// Resolves JSON payload indirection syntax.
    /// Supported forms:
    /// - Inline JSON: `{"path":"..."}`
    /// - File payload: `@/path/to/args.json` or `@relative/path.json`
    /// - Auto-detected file: `/path/to/args.json` or `relative/args.json` (no @ needed)
    /// - Stdin payload: `@-`
    /// - Escaped literal @: `@@{...}` -> `@{...}`
    private static func resolveJSONPayload(_ payload: String) throws -> String {
        // Auto-detect file paths: ends with .json and doesn't look like inline JSON
        if !payload.hasPrefix("@"),
           !payload.hasPrefix("{"), !payload.hasPrefix("["),
           payload.hasSuffix(".json") {
            let resolvedPath = resolveJSONFilePath(payload)
            if FileManager.default.fileExists(atPath: resolvedPath) {
                do {
                    return try String(contentsOfFile: resolvedPath, encoding: .utf8)
                } catch {
                    throw CommandParseError.invalidJSON("Failed to read JSON file '\(payload)': \(error.localizedDescription)")
                }
            }
        }

        guard payload.hasPrefix("@") else { return payload }

        // Escape hatch for literal payloads that intentionally begin with '@'
        if payload.hasPrefix("@@") {
            return String(payload.dropFirst())
        }

        let source = String(payload.dropFirst())
        guard !source.isEmpty else {
            throw CommandParseError.invalidJSON("Missing JSON source after '@'. Use @/path/to/file.json or @-.")
        }

        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else {
                throw CommandParseError.invalidJSON("No JSON received on stdin for @-.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandParseError.invalidJSON("Invalid UTF-8 in stdin JSON (@-).")
            }
            return text
        }

        let resolvedPath = resolveJSONFilePath(source)
        do {
            return try String(contentsOfFile: resolvedPath, encoding: .utf8)
        } catch {
            throw CommandParseError.invalidJSON("Failed to read JSON file '@\(source)': \(error.localizedDescription)")
        }
    }

    /// Resolves a JSON argument file path (used by @file syntax and auto-detected .json paths).
    private static func resolveJSONFilePath(_ inputPath: String) -> String {
        let expanded = (inputPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardized.path
        }

        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(expanded)
            .standardized.path
    }

    /// Attempts to repair JSON by escaping raw control characters that appear
    /// inside quoted strings. This handles cases like:
    /// {"rewrite":"line1
    /// line2"}
    /// which is invalid JSON but common in model-generated payloads.
    private static func repairJSONStringControlCharacters(in text: String) -> String? {
        var output = ""
        output.reserveCapacity(text.count + 32)

        var inString = false
        var isEscaping = false
        var changed = false

        for scalar in text.unicodeScalars {
            if inString {
                if isEscaping {
                    output.unicodeScalars.append(scalar)
                    isEscaping = false
                    continue
                }

                if scalar == "\\" {
                    output.unicodeScalars.append(scalar)
                    isEscaping = true
                    continue
                }

                if scalar == "\"" {
                    output.unicodeScalars.append(scalar)
                    inString = false
                    continue
                }

                switch scalar.value {
                case 0x0A: // \n
                    output += "\\n"
                    changed = true
                case 0x0D: // \r
                    output += "\\r"
                    changed = true
                case 0x09: // \t
                    output += "\\t"
                    changed = true
                case 0x00...0x1F:
                    output += String(format: "\\u%04X", scalar.value)
                    changed = true
                default:
                    output.unicodeScalars.append(scalar)
                }
            } else {
                output.unicodeScalars.append(scalar)
                if scalar == "\"" {
                    inString = true
                }
            }
        }

        // If string state is unbalanced, don't attempt to "repair" further.
        if inString || isEscaping {
            return nil
        }

        return changed ? output : nil
    }
}

// MARK: - Value Conversion

extension MCPCommandParser {

    /// Converts a dictionary of AnyCodableSendable values to MCP Value types.
    static func convertToMCPValues(_ dict: [String: AnyCodableSendable]) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, wrapped) in dict {
            result[key] = try convertToMCPValue(wrapped.value)
        }
        return result
    }

    static func convertToMCPValue(_ value: Any) throws -> Value {
        switch value {
        case let s as String:
            return .string(s)
        case let i as Int:
            return .int(i)
        case let b as Bool:
            return .bool(b)
        case let d as Double:
            return .double(d)
        // Handle AnyCodableSendable-wrapped arrays (from JSON parsing)
        case let arr as [AnyCodableSendable]:
            return .array(try arr.map { try convertToMCPValue($0.value) })
        case let arr as [Any]:
            return .array(try arr.map { try convertToMCPValue($0) })
        // Handle AnyCodableSendable-wrapped dictionaries (from JSON parsing)
        case let dict as [String: AnyCodableSendable]:
            var result: [String: Value] = [:]
            for (k, v) in dict {
                result[k] = try convertToMCPValue(v.value)
            }
            return .object(result)
        case let dict as [String: Any]:
            var result: [String: Value] = [:]
            for (k, v) in dict {
                result[k] = try convertToMCPValue(v)
            }
            return .object(result)
        case is NSNull:
            return .null
        case let wrapped as AnyCodableSendable:
            return try convertToMCPValue(wrapped.value)
        default:
            // Try JSON serialization as fallback
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let decoded = try? JSONDecoder().decode(Value.self, from: data) {
                return decoded
            }
            throw CommandParseError.invalidArgument("Cannot convert value to MCP type: \(value)")
        }
    }
}
