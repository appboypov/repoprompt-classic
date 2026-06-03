import Foundation

enum CursorACPLaunchCandidate: CaseIterable, Sendable, Equatable {
	case cursorAgentACP
	case cursorAgentSubcommand

	var command: String {
		switch self {
		case .cursorAgentACP:
			return "cursor-agent"
		case .cursorAgentSubcommand:
			return "cursor"
		}
	}

	var launchArguments: [String] {
		switch self {
		case .cursorAgentACP:
			return ["--approve-mcps", "acp"]
		case .cursorAgentSubcommand:
			return ["agent", "--approve-mcps", "acp"]
		}
	}

	var helpArguments: [String] {
		switch self {
		case .cursorAgentACP:
			return ["acp", "--help"]
		case .cursorAgentSubcommand:
			return ["agent", "acp", "--help"]
		}
	}

	var displayCommand: String {
		([command] + launchArguments).joined(separator: " ")
	}
}

struct CursorACPResolvedLaunch: Sendable, Equatable {
	let command: String
	let arguments: [String]
	let additionalPathHints: [String]

	static func fallback(commandName: String = CursorACPLaunchCandidate.cursorAgentACP.command, additionalPathHints: [String]) -> CursorACPResolvedLaunch {
		let trimmedCommand = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
		let command = trimmedCommand.isEmpty ? CursorACPLaunchCandidate.cursorAgentACP.command : trimmedCommand
		let arguments = command == CursorACPLaunchCandidate.cursorAgentSubcommand.command
			? CursorACPLaunchCandidate.cursorAgentSubcommand.launchArguments
			: CursorACPLaunchCandidate.cursorAgentACP.launchArguments
		return CursorACPResolvedLaunch(
			command: command,
			arguments: arguments,
			additionalPathHints: additionalPathHints
		)
	}
}

final class CursorACPLaunchResolver: @unchecked Sendable {
	static let shared = CursorACPLaunchResolver()

	private let lock = NSLock()
	private var cachedLaunchByKey: [String: CursorACPResolvedLaunch] = [:]

	func resolvedLaunch(for config: CursorAgentConfig) -> CursorACPResolvedLaunch? {
		let key = cacheKey(for: config)
		lock.lock()
		defer { lock.unlock() }
		return cachedLaunchByKey[key]
	}

	func probeSupport(for config: CursorAgentConfig) async -> ACPSupportResult {
		let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
		let key = cacheKey(for: config)

		if resolvedLaunch(for: config) != nil {
			return .supported
		}

		var commandNotFoundCount = 0
		var failureMessages: [String] = []
		let candidates = orderedCandidates(for: config)
		for candidate in candidates {
			var processConfig = CLIProcessConfiguration(
				command: candidate.command,
				enableDebugLogging: config.enableDebugLogging
			)
			processConfig.ensureAdditionalPaths(effectiveHints)
			let runner = CLIProcessRunner(config: processConfig)

			do {
				let result = try await runner.run(
					args: candidate.helpArguments,
					stdin: nil,
					outputMode: .none,
					timeout: 10
				)
				let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
				let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
				let combined = "\(stdout)\n\(stderr)"
				guard result.status == 0 else {
					failureMessages.append("`\(candidate.displayCommand)` exited with status \(result.status).")
					continue
				}

				let advertisesACP = combined.localizedCaseInsensitiveContains("acp")
					|| combined.localizedCaseInsensitiveContains("agent client protocol")
				guard advertisesACP else {
					failureMessages.append("`\(candidate.displayCommand)` did not advertise ACP support.")
					continue
				}
				if advertisesACP {
					cache(
						CursorACPResolvedLaunch(
							command: candidate.command,
							arguments: candidate.launchArguments,
							additionalPathHints: effectiveHints
						),
						key: key
					)
					return .supported
				}
			} catch let error as CLIProcessRunnerError {
				switch error {
				case .commandNotFound:
					commandNotFoundCount += 1
				default:
					failureMessages.append("`\(candidate.displayCommand)` failed: \(error.localizedDescription)")
				}
			} catch {
				failureMessages.append("`\(candidate.displayCommand)` failed: \(error.localizedDescription)")
			}
		}

		if commandNotFoundCount == candidates.count {
			return .unsupported(reason: "Cursor CLI ACP server was not found. Tried `cursor-agent acp` and `cursor agent acp`.")
		}
		let detail = failureMessages.isEmpty ? "Tried `cursor-agent acp` and `cursor agent acp`." : failureMessages.joined(separator: " ")
		return .unsupported(reason: "Cursor ACP preflight failed before startup. \(detail)")
	}

	private func orderedCandidates(for config: CursorAgentConfig) -> [CursorACPLaunchCandidate] {
		if config.commandName == CursorACPLaunchCandidate.cursorAgentSubcommand.command {
			return [.cursorAgentSubcommand, .cursorAgentACP]
		}
		return [.cursorAgentACP, .cursorAgentSubcommand]
	}

	private func cache(_ launch: CursorACPResolvedLaunch, key: String) {
		lock.lock()
		cachedLaunchByKey[key] = launch
		lock.unlock()
	}

	private func cacheKey(for config: CursorAgentConfig) -> String {
		([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
	}
}
