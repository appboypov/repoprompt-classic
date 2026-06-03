import Foundation

struct CLIProcessConfiguration {
	var command: String
	/// Working directory for the CLI process. Defaults to temp directory to avoid macOS security popups.
	var workingDirectory: String
	var environment: [String: String]
	var additionalPaths: [String]
	var commandSuffix: [String]
	var enableDebugLogging: Bool
	var logCollector: CLIProcessLogCollector?
	/// Optional: explicit basenames we prefer to resolve to (e.g., ["claude", "codex"]).
	/// If omitted, the resolver will prefer `command` and otherwise behave as before.
	var resolveCandidates: [String]?
	/// Limit how many bytes from child stdout/stderr we retain (per stream).
	var captureStdoutTailBytes: Int
	var captureStderrTailBytes: Int
	/// Limit how many bytes of stdin we sample for logs (0 disables sampling).
	var logStdinSampleBytes: Int

	init(
		command: String = "claude",
		workingDirectory: String? = nil,  // nil → temp directory to avoid macOS security popups
		environment: [String: String] = [:],
		additionalPaths: [String] = CLINativePathDefaults.defaultAdditionalPaths,
		commandSuffix: [String] = [],
		enableDebugLogging: Bool = false,
		logCollector: CLIProcessLogCollector? = nil,
		resolveCandidates: [String]? = nil,
		captureStdoutTailBytes: Int = 0,
		captureStderrTailBytes: Int = 256 * 1024,
		logStdinSampleBytes: Int = 0
	) {
		self.command = command
		self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory.path
		self.environment = environment
		self.additionalPaths = additionalPaths
		self.commandSuffix = commandSuffix
		self.enableDebugLogging = enableDebugLogging
		self.logCollector = logCollector
		self.resolveCandidates = resolveCandidates
		self.captureStdoutTailBytes = captureStdoutTailBytes
		self.captureStderrTailBytes = captureStderrTailBytes
		self.logStdinSampleBytes = logStdinSampleBytes
	}
}
