//
//  ProcessCoreTests.swift
//  RepoPromptTests
//

import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class ProcessCoreTests: XCTestCase {

	private func withTempHome(_ body: (URL) throws -> Void) throws {
		let fm = FileManager.default
		let tempHome = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
		addTeardownBlock {
			try? fm.removeItem(at: tempHome)
		}
		try body(tempHome)
	}

	func testPathLooksInsufficientDetectsSystemOnlyValues() {
		XCTAssertTrue(CLIEnvironmentCache.test_pathLooksInsufficient("/usr/bin:/bin:/usr/sbin:/sbin"))
		XCTAssertFalse(CLIEnvironmentCache.test_pathLooksInsufficient("/usr/bin:/bin:/opt/homebrew/bin"))
	}

	func testProcessLaunchContextDetectsLaunchServicesMarker() {
		let environment = [
			ProcessLaunchContext.launchSourceEnvironmentKey: ProcessLaunchContext.launchServicesEnvironmentValue,
			"XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
			"TERM_PROGRAM": "iTerm.app",
			"PATH": "/usr/bin:/bin:/opt/homebrew/bin",
			"SHELL": "/bin/zsh",
			"HOME": "/Users/tester"
		]

		let context = ProcessLaunchContext.detect(from: environment)

		XCTAssertEqual(context.source, .launchServices, "Explicit LaunchServices marker should be the strongest launch-source signal")
		XCTAssertEqual(context.inheritedEnvironmentPath, "/usr/bin:/bin:/opt/homebrew/bin")
		XCTAssertEqual(context.shell, "/bin/zsh")
		XCTAssertEqual(context.home, "/Users/tester")
	}

	func testProcessLaunchContextLaunchServicesMarkerMatchesInfoPlist() throws {
		let repoRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
			.deletingLastPathComponent() // Process/
			.deletingLastPathComponent() // RepoPromptTests/
			.deletingLastPathComponent()
		let plistURL = repoRoot.appendingPathComponent("RepoPrompt/Info.plist", isDirectory: false)
		let data = try Data(contentsOf: plistURL)
		let plist = try XCTUnwrap(
			PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
		)
		let launchServicesEnvironment = try XCTUnwrap(plist["LSEnvironment"] as? [String: String])

		XCTAssertEqual(
			launchServicesEnvironment[ProcessLaunchContext.launchSourceEnvironmentKey],
			ProcessLaunchContext.launchServicesEnvironmentValue
		)
	}

	func testProcessLaunchContextDetectsXcodeTestAndPreviewMarkers() {
		let markerKeys = [
			"XCTestConfigurationFilePath",
			"XCTestSessionIdentifier",
			"XCODE_RUNNING_FOR_PREVIEWS",
			"__XCODE_BUILT_PRODUCTS_DIR_PATHS"
		]

		for markerKey in markerKeys {
			let environment = [
				markerKey: "1",
				"TERM": "xterm-256color",
				"PATH": "/usr/bin:/bin:/opt/homebrew/bin"
			]

			XCTAssertEqual(
				ProcessLaunchContext.detect(from: environment).source,
				.xcode,
				"Expected \(markerKey) to be classified as an Xcode/test/previews launch"
			)
		}
	}

	func testProcessLaunchContextDetectsTerminalInheritedRichEnvironment() {
		let environment = [
			"TERM": "xterm-256color",
			"TERM_PROGRAM": "Apple_Terminal",
			"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
			"SHELL": "/bin/zsh",
			"HOME": "/Users/tester"
		]

		let context = ProcessLaunchContext.detect(from: environment)

		XCTAssertEqual(context.source, .terminalInherited)
		XCTAssertEqual(context.inheritedEnvironmentPath, "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
		XCTAssertEqual(context.shell, "/bin/zsh")
		XCTAssertEqual(context.home, "/Users/tester")
	}

	func testProcessLaunchContextFallsBackToUnknownForMinimalOrUnmarkedEnvironment() {
		let minimalTerminalEnvironment = [
			"TERM": "xterm-256color",
			"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
		]
		XCTAssertEqual(ProcessLaunchContext.detect(from: minimalTerminalEnvironment).source, .unknown)
		XCTAssertEqual(ProcessLaunchContext.detect(from: [:]).source, .unknown)
	}

	func testProcessEnvironmentSanitizerRemovesDynamicLoaderKeysForChildLaunch() {
		let environment = [
			"DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
			"DYLD_LIBRARY_PATH": "/tmp/libs",
			"DYLD_FRAMEWORK_PATH": "/tmp/frameworks",
			"DYLD_ROOT_PATH": "/tmp/root",
			"DYLD_FALLBACK_LIBRARY_PATH": "/tmp/fallback-libs",
			"DYLD_FALLBACK_FRAMEWORK_PATH": "/tmp/fallback-frameworks",
			"DYLD_VERSIONED_LIBRARY_PATH": "/tmp/versioned-libs",
			"DYLD_PRINT_LIBRARIES": "1",
			"__XPC_DYLD_LIBRARY_PATH": "/tmp/xpc-libs",
			"PATH": "/usr/bin:/bin",
			"OPENAI_API_KEY": "secret",
			"ANTHROPIC_API_KEY": "secret",
			"CODEX_HOME": "/tmp/codex",
			"GEMINI_API_KEY": "secret",
			"XPC_SERVICE_NAME": "com.pvncher.repoprompt",
			"NODE_OPTIONS": "--require /tmp/hook.js",
			"REMOVE_ME": "1"
		]

		let sanitized = ProcessEnvironmentSanitizer.sanitizedForChildLaunch(
			environment,
			additionalRemovedKeys: ["REMOVE_ME"]
		)

		for key in ProcessEnvironmentSanitizer.dynamicLoaderKeys {
			XCTAssertNil(sanitized[key], "Expected \(key) to be removed before child launch")
		}
		XCTAssertNil(sanitized["DYLD_VERSIONED_LIBRARY_PATH"])
		XCTAssertNil(sanitized["DYLD_PRINT_LIBRARIES"])
		XCTAssertNil(sanitized["__XPC_DYLD_LIBRARY_PATH"])
		XCTAssertNil(sanitized["REMOVE_ME"])
		XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
		XCTAssertEqual(sanitized["OPENAI_API_KEY"], "secret")
		XCTAssertEqual(sanitized["ANTHROPIC_API_KEY"], "secret")
		XCTAssertEqual(sanitized["CODEX_HOME"], "/tmp/codex")
		XCTAssertEqual(sanitized["GEMINI_API_KEY"], "secret")
		XCTAssertEqual(sanitized["XPC_SERVICE_NAME"], "com.pvncher.repoprompt")
		XCTAssertEqual(sanitized["NODE_OPTIONS"], "--require /tmp/hook.js")
	}

	func testProcessEnvironmentSanitizerDynamicLoaderKeyClassification() {
		XCTAssertTrue(ProcessEnvironmentSanitizer.isDynamicLoaderKey("DYLD_INSERT_LIBRARIES"))
		XCTAssertTrue(ProcessEnvironmentSanitizer.isDynamicLoaderKey("DYLD_LIBRARY_PATH"))
		XCTAssertTrue(ProcessEnvironmentSanitizer.isDynamicLoaderKey("DYLD_VERSIONED_LIBRARY_PATH"))
		XCTAssertTrue(ProcessEnvironmentSanitizer.isDynamicLoaderKey("DYLD_PRINT_LIBRARIES"))
		XCTAssertTrue(ProcessEnvironmentSanitizer.isDynamicLoaderKey("__XPC_DYLD_FRAMEWORK_PATH"))
		XCTAssertFalse(ProcessEnvironmentSanitizer.isDynamicLoaderKey("XPC_SERVICE_NAME"))
		XCTAssertFalse(ProcessEnvironmentSanitizer.isDynamicLoaderKey("OPENAI_API_KEY"))
	}

	func testProcessEnvironmentBuilderUsesRichInheritedTerminalEnvironmentWithoutShellCapture() async {
		let inherited = [
			"TERM": "xterm-256color",
			"TERM_PROGRAM": "Apple_Terminal",
			"PATH": "/usr/bin:/bin:/opt/homebrew/bin",
			"HOME": "/Users/tester",
			"DYLD_PRINT_LIBRARIES": "1"
		]
		let request = ProcessEnvironmentRequest(
			purpose: .cliRunner,
			inheritedEnvironment: inherited,
			overrides: ["OVERRIDE": "1"]
		)

		let result = await ProcessEnvironmentBuilder.build(request) { _, _ in
			CLIEnvironmentCache.test_snapshot(
				environment: [
					"PATH": "/shell/bin",
					"SHELL_ONLY": "should-not-be-used"
				],
				source: .capturedLoginShell
			)
		}

		XCTAssertEqual(result.launchContext.source, .terminalInherited)
		XCTAssertEqual(result.shellEnvironmentSource, .inheritedRichEnvironment)
		XCTAssertEqual(result.environment["PATH"], "/usr/bin:/bin:/opt/homebrew/bin")
		XCTAssertEqual(result.environment["HOME"], "/Users/tester")
		XCTAssertEqual(result.environment["OVERRIDE"], "1")
		XCTAssertNil(result.environment["SHELL_ONLY"])
		XCTAssertNil(result.environment["DYLD_PRINT_LIBRARIES"])
	}

	func testProcessEnvironmentBuilderMergesShellAndInheritedEnvironmentsWithBasePathPrecedence() async {
		let inherited = [
			ProcessLaunchContext.launchSourceEnvironmentKey: ProcessLaunchContext.launchServicesEnvironmentValue,
			"PATH": "/usr/bin:/bin:/terminal/bin",
			"HOME": "/Users/tester",
			"TERM": "vt100",
			"INHERITED_ONLY": "inherited",
			"SHARED": "inherited",
			"REMOVE_ME": "1"
		]
		let shellSnapshot = CLIEnvironmentCache.test_snapshot(
			environment: [
				"PATH": "/shell/bin:/usr/bin",
				"BASE_ONLY": "base",
				"SHARED": "base",
				"DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib"
			],
			source: .capturedLoginShell
		)
		let request = ProcessEnvironmentRequest(
			purpose: .codexPreflight,
			inheritedEnvironment: inherited,
			overrides: ["SHARED": "override", "OVERRIDE_ONLY": "override"],
			additionalRemovedKeys: ["REMOVE_ME"]
		)

		let result = await ProcessEnvironmentBuilder.build(request) { _, _ in shellSnapshot }

		XCTAssertEqual(result.launchContext.source, .launchServices)
		XCTAssertEqual(result.shellEnvironmentSource, .capturedLoginShell)
		XCTAssertEqual(result.environment["PATH"], "/shell/bin:/usr/bin:/bin:/terminal/bin")
		XCTAssertEqual(result.environment["HOME"], "/Users/tester")
		XCTAssertEqual(result.environment["TERM"], "vt100")
		XCTAssertEqual(result.environment["BASE_ONLY"], "base")
		XCTAssertEqual(result.environment["INHERITED_ONLY"], "inherited")
		XCTAssertEqual(result.environment["SHARED"], "override")
		XCTAssertEqual(result.environment["OVERRIDE_ONLY"], "override")
		XCTAssertNil(result.environment["REMOVE_ME"])
		XCTAssertNil(result.environment["DYLD_INSERT_LIBRARIES"])
	}

	func testProcessEnvironmentBuilderUsesShellSnapshotForUnknownAndForceRefresh() async {
		let unknownRequest = ProcessEnvironmentRequest(
			purpose: .shellEnvironmentProbe,
			inheritedEnvironment: ["PATH": "/usr/bin:/bin"],
			enableDebugLogging: true
		)
		let unknownResult = await ProcessEnvironmentBuilder.build(unknownRequest) { enableLogging, forceRefresh in
			CLIEnvironmentCache.test_snapshot(
				environment: [
					"PATH": "/shell/bin",
					"ENABLE_LOGGING": enableLogging ? "true" : "false",
					"FORCE_REFRESH": forceRefresh ? "true" : "false"
				],
				source: .enrichedFallback
			)
		}

		XCTAssertEqual(unknownResult.launchContext.source, .unknown)
		XCTAssertEqual(unknownResult.shellEnvironmentSource, .enrichedFallback)
		XCTAssertEqual(unknownResult.environment["PATH"], "/shell/bin:/usr/bin:/bin")
		XCTAssertEqual(unknownResult.environment["ENABLE_LOGGING"], "true")
		XCTAssertEqual(unknownResult.environment["FORCE_REFRESH"], "false")

		let shellProbeRequest = ProcessEnvironmentRequest(
			purpose: .shellEnvironmentProbe,
			inheritedEnvironment: [
				"TERM": "xterm-256color",
				"PATH": "/usr/bin:/bin:/opt/homebrew/bin"
			]
		)
		let shellProbeResult = await ProcessEnvironmentBuilder.build(shellProbeRequest) { _, _ in
			CLIEnvironmentCache.test_snapshot(
				environment: ["PATH": "/probe-shell/bin", "PROBED": "true"],
				source: .capturedLoginShell
			)
		}

		XCTAssertEqual(shellProbeResult.launchContext.source, .terminalInherited)
		XCTAssertEqual(shellProbeResult.shellEnvironmentSource, .capturedLoginShell)
		XCTAssertEqual(shellProbeResult.environment["PATH"], "/probe-shell/bin:/usr/bin:/bin:/opt/homebrew/bin")
		XCTAssertEqual(shellProbeResult.environment["PROBED"], "true")

		let terminalRequest = ProcessEnvironmentRequest(
			purpose: .cliRunner,
			inheritedEnvironment: [
				"TERM": "xterm-256color",
				"PATH": "/usr/bin:/bin:/opt/homebrew/bin"
			],
			forceRefreshShellEnvironment: true
		)
		let terminalResult = await ProcessEnvironmentBuilder.build(terminalRequest) { _, forceRefresh in
			CLIEnvironmentCache.test_snapshot(
				environment: [
					"PATH": "/fresh-shell/bin",
					"FORCE_REFRESH": forceRefresh ? "true" : "false"
				],
				source: .capturedLoginShell
			)
		}

		XCTAssertEqual(terminalResult.launchContext.source, .terminalInherited)
		XCTAssertEqual(terminalResult.shellEnvironmentSource, .capturedLoginShell)
		XCTAssertEqual(terminalResult.environment["PATH"], "/fresh-shell/bin:/usr/bin:/bin:/opt/homebrew/bin")
		XCTAssertEqual(terminalResult.environment["FORCE_REFRESH"], "true")
	}

	func testProcessEnvironmentBuilderCodexPurposesUseShellSnapshotEvenForRichTerminalEnvironment() async {
		let inherited = [
			"TERM": "xterm-256color",
			"PATH": "/usr/bin:/bin:/opt/homebrew/bin"
		]

		for purpose in [ProcessLaunchPurpose.codexPreflight, .codexAppServer] {
			let request = ProcessEnvironmentRequest(
				purpose: purpose,
				inheritedEnvironment: inherited
			)
			let result = await ProcessEnvironmentBuilder.build(request) { _, _ in
				CLIEnvironmentCache.test_snapshot(
					environment: ["PATH": "/codex-shell/bin", "CODEX_SHELL": "true"],
					source: .capturedLoginShell
				)
			}

			XCTAssertEqual(result.launchContext.source, .terminalInherited)
			XCTAssertEqual(result.shellEnvironmentSource, .capturedLoginShell)
			XCTAssertEqual(result.environment["PATH"], "/codex-shell/bin:/usr/bin:/bin:/opt/homebrew/bin")
			XCTAssertEqual(result.environment["CODEX_SHELL"], "true")
		}
	}

	func testCLIProcessRunnerUsesBuilderEnvironmentPrecedenceAndSanitizer() async throws {
		let config = CLIProcessConfiguration(
			command: "/usr/bin/env",
			environment: [
				"PATH": "/config/bin",
				"CONFIG_ONLY": "config",
				"SHARED_KEY": "config",
				"OPENAI_API_KEY": "config-secret",
				"DYLD_PRINT_LIBRARIES": "config-dyld"
			],
			additionalPaths: ["/should/not/be/in/path"]
		)
		let runner = CLIProcessRunner(config: config)

		let result = try await runner.run(
			args: [],
			stdin: nil,
			outputMode: .none,
			timeout: 5,
			additionalEnvironment: [
				"PATH": "/runtime/bin",
				"RUNTIME_ONLY": "runtime",
				"SHARED_KEY": "runtime",
				"ANTHROPIC_API_KEY": "runtime-secret",
				"__XPC_DYLD_LIBRARY_PATH": "/tmp/xpc-dyld"
			]
		)

		XCTAssertEqual(result.status, 0)
		let environment = parsedEnvironmentOutput(result.stdout)
		XCTAssertEqual(environment["PATH"], "/runtime/bin")
		XCTAssertEqual(environment["CONFIG_ONLY"], "config")
		XCTAssertEqual(environment["RUNTIME_ONLY"], "runtime")
		XCTAssertEqual(environment["SHARED_KEY"], "runtime")
		XCTAssertEqual(environment["OPENAI_API_KEY"], "config-secret")
		XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "runtime-secret")
		XCTAssertNil(environment["DYLD_PRINT_LIBRARIES"])
		XCTAssertNil(environment["__XPC_DYLD_LIBRARY_PATH"])
		XCTAssertFalse(environment["PATH"]?.contains("/should/not/be/in/path") == true)
	}

	func testCLILaunchProfilesPreserveCLIPathHintsCompatibility() {
		XCTAssertEqual(CLILaunchProfiles.claudeCode.commandName, "claude")
		XCTAssertEqual(CLILaunchProfiles.claudeCode.preferredBasenames, ["claude"])
		XCTAssertEqual(CLILaunchProfiles.claudeCode.supplementalSearchPaths, CLIPathHints.nativeDefaultsSupplemented(with: CLIPathHints.claudeCode))

		XCTAssertEqual(CLILaunchProfiles.codex.commandName, "codex")
		XCTAssertEqual(CLILaunchProfiles.codex.preferredBasenames, ["codex"])
		XCTAssertEqual(CLILaunchProfiles.codex.supplementalSearchPaths, CLIPathHints.codex)
		for fallbackPath in CLINativePathDefaults.loginShellFallbackCandidates {
			XCTAssertTrue(
				CLILaunchProfiles.codex.supplementalSearchPaths.contains(fallbackPath),
				"Codex profile should keep native shell fallback hint \(fallbackPath)"
			)
		}
		XCTAssertTrue(CLILaunchProfiles.codex.supplementalSearchPaths.contains("~/.bun/bin"))
		XCTAssertTrue(CLILaunchProfiles.codex.supplementalSearchPaths.contains("/Applications/Codex.app/Contents/Resources"))

		XCTAssertEqual(CLILaunchProfiles.gemini.commandName, "gemini")
		XCTAssertEqual(CLILaunchProfiles.gemini.preferredBasenames, ["gemini"])
		XCTAssertEqual(CLILaunchProfiles.gemini.supplementalSearchPaths, CLIPathHints.nativeDefaultsSupplemented(with: CLIPathHints.gemini))

		XCTAssertEqual(CLILaunchProfiles.openCode.commandName, "opencode")
		XCTAssertEqual(CLILaunchProfiles.openCode.preferredBasenames, ["opencode"])
		XCTAssertEqual(CLILaunchProfiles.openCode.supplementalSearchPaths, CLIPathHints.nativeDefaultsSupplemented(with: CLIPathHints.openCode))

		XCTAssertEqual(CLILaunchProfiles.cursor.commandName, "cursor-agent")
		XCTAssertEqual(CLILaunchProfiles.cursor.preferredBasenames, ["cursor-agent", "cursor"])
		XCTAssertEqual(CLILaunchProfiles.cursor.supplementalSearchPaths, CLIPathHints.nativeDefaultsSupplemented(with: CLIPathHints.cursor))
	}

	func testEnrichedPathAppendsExistingFallbackDirectories() throws {
		try withTempHome { home in
			let localDir = home.appendingPathComponent(".local", isDirectory: true)
			let localBin = localDir.appendingPathComponent("bin", isDirectory: true)
			try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
			let bunDir = home.appendingPathComponent(".bun", isDirectory: true)
			let bunBin = bunDir.appendingPathComponent("bin", isDirectory: true)
			try FileManager.default.createDirectory(at: bunBin, withIntermediateDirectories: true)

			let enriched = CLIEnvironmentCache.test_enrichedPath(existing: "/usr/bin:/bin", home: home.path)

			let components = enriched.split(separator: ":").map(String.init)
			XCTAssertTrue(components.contains(localBin.path), "Expected ~/.local/bin to be appended when it exists on disk")
			XCTAssertTrue(components.contains(bunBin.path), "Expected ~/.bun/bin to be appended when it exists on disk")
			XCTAssertTrue(components.starts(with: ["/usr/bin", "/bin"]), "Existing PATH order should be preserved")
		}
	}

	func testEnrichedPathAppendsNodePackageManagerFallbackDirectories() throws {
		try withTempHome { home in
			let expectedDirectories = [
				home.appendingPathComponent(".volta/bin", isDirectory: true),
				home.appendingPathComponent(".local/share/pnpm", isDirectory: true),
				home.appendingPathComponent(".config/yarn/global/node_modules/.bin", isDirectory: true),
				home.appendingPathComponent(".nodenv/shims", isDirectory: true)
			]
			for directory in expectedDirectories {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			}

			let enriched = CLIEnvironmentCache.test_enrichedPath(existing: "/usr/bin:/bin", home: home.path)
			let components = enriched.split(separator: ":").map(String.init)

			for directory in expectedDirectories {
				XCTAssertTrue(components.contains(directory.path), "Expected \(directory.path) to be appended when it exists on disk")
			}
			XCTAssertTrue(components.starts(with: ["/usr/bin", "/bin"]), "Existing PATH order should be preserved")
		}
	}

	func testCLIProcessConfigurationUsesNativePathDefaults() {
		let config = CLIProcessConfiguration()
		XCTAssertEqual(config.additionalPaths, CLINativePathDefaults.defaultAdditionalPaths)
		XCTAssertTrue(config.additionalPaths.contains("~/.volta/bin"))
		XCTAssertTrue(config.additionalPaths.contains("~/.local/share/pnpm"))
		XCTAssertTrue(config.additionalPaths.contains("~/.nodenv/shims"))
	}

	func testNonCodexProviderHintsOnlyContainProviderSpecificLocations() {
		XCTAssertEqual(CLIPathHints.claudeCode, ["~/.claude/local"])
		XCTAssertEqual(CLIPathHints.gemini, ["~/.gemini/bin"])
		XCTAssertEqual(CLIPathHints.openCode, [])

		XCTAssertFalse(CLIPathHints.gemini.contains("/opt/homebrew/bin"), "Homebrew is provided by native defaults, not Gemini-specific hints")
		XCTAssertFalse(CLIPathHints.openCode.contains("~/.bun/bin"), "Bun is provided by native defaults, not OpenCode-specific hints")
		XCTAssertFalse(CLIPathHints.openCode.contains("~/.local/bin"), "Local user bins are provided by native defaults, not OpenCode-specific hints")
		XCTAssertFalse(CLIPathHints.openCode.contains("/opt/homebrew/bin"), "Homebrew is provided by native defaults, not OpenCode-specific hints")
	}

	func testEffectiveNonCodexProviderPathsUseNativeDefaultsPlusProviderSpecificHints() {
		let cases: [(name: String, hints: [String], providerSpecific: [String])] = [
			("Claude Code", CLIPathHints.claudeCode, ["~/.claude/local"]),
			("Gemini", CLIPathHints.gemini, ["~/.gemini/bin"]),
			("OpenCode", CLIPathHints.openCode, [])
		]

		for testCase in cases {
			var processConfig = CLIProcessConfiguration()
			processConfig.ensureAdditionalPaths(testCase.hints)
			let effectivePaths = CLIPathHints.nativeDefaultsSupplemented(with: testCase.hints)

			XCTAssertEqual(processConfig.additionalPaths, effectivePaths, "\(testCase.name) should use CLIProcessConfiguration native defaults plus provider-specific hints")
			XCTAssertTrue(effectivePaths.starts(with: CLINativePathDefaults.defaultAdditionalPaths), "\(testCase.name) should preserve native default path precedence")
			for nativePath in CLINativePathDefaults.defaultAdditionalPaths {
				XCTAssertTrue(effectivePaths.contains(nativePath), "\(testCase.name) effective paths should include native default \(nativePath)")
			}
			for providerPath in testCase.providerSpecific {
				XCTAssertTrue(effectivePaths.contains(providerPath), "\(testCase.name) effective paths should include provider-specific path \(providerPath)")
			}
		}
	}

	func testCodexPathHintsIncludeNativeAppInstallFallbacks() {
		let hints = CLIPathHints.codex
		let expectedPaths = CLINativePathDefaults.homebrewBins
			+ CLINativePathDefaults.nodePackageManagerBins
			+ CLINativePathDefaults.versionManagerShimBins
			+ CLINativePathDefaults.userToolBins
			+ ["/Applications/Codex.app/Contents/Resources"]

		for expected in expectedPaths {
			XCTAssertTrue(hints.contains(expected), "Codex path hints should include \(expected)")
		}
	}

	func testCodexPathHintsResolveBunInstallWhenShellLookupUnavailable() throws {
		XCTAssertTrue(CLIPathHints.codex.contains("~/.bun/bin"), "Codex hints should include Bun's install directory")

		try withTempHome { home in
			let bunBin = home.appendingPathComponent(".bun/bin", isDirectory: true)
			try FileManager.default.createDirectory(at: bunBin, withIntermediateDirectories: true)
			let codexExecutable = bunBin.appendingPathComponent("codex")
			try "#!/bin/sh\nexit 0\n".write(to: codexExecutable, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: codexExecutable.path)

			let resolved = CommandPathResolver.resolve(
				"codex",
				environment: [
					"HOME": home.path,
					"PATH": "/usr/bin:/bin",
					"SHELL": "/definitely/missing-shell"
				],
				additionalPaths: [bunBin.path]
			)

			XCTAssertEqual(resolved, codexExecutable.path)
		}
	}

	func testFullEnvironmentCaptureAndClaudeResolution() async throws {
		print("\n========== Full Environment Capture Integration Test ==========\n")

		// Capture the full environment using the actual shell
		let env = await CLIEnvironmentCache.capturedEnvironment(enableLogging: true)

		// Print shell information
		print("\n--- Shell Information ---")
		print("SHELL: \(env["SHELL"] ?? "not set")")
		print("TERM: \(env["TERM"] ?? "not set")")
		print("TERM_PROGRAM: \(env["TERM_PROGRAM"] ?? "not set")")
		print("HOME: \(env["HOME"] ?? "not set")")
		print("USER: \(env["USER"] ?? "not set")")

		// Print PATH components
		print("\n--- PATH Components ---")
		if let path = env["PATH"] {
			let components = path.split(separator: ":").map(String.init)
			print("PATH has \(components.count) components:")
			for (idx, component) in components.enumerated() {
				print("  [\(idx + 1)] \(component)")
			}
		} else {
			print("PATH is not set!")
		}

		// Print other relevant environment variables
		print("\n--- Other Relevant Variables ---")
		let relevantVars = [
			"LANG", "LC_CTYPE", "MISE_ACTIVATE_SHELL", "INTELLIJ_ENVIRONMENT_READER",
			"RP_SHELL_LOOKUP", "ZDOTDIR", "NVM_DIR", "PYENV_ROOT", "RBENV_ROOT"
		]
		for varName in relevantVars {
			if let value = env[varName] {
				print("\(varName): \(value)")
			}
		}

		// Try to resolve claude using the captured environment
		print("\n--- Claude Resolution Test ---")
		let claudePath = CommandPathResolver.resolve(
			"claude",
			environment: env,
			additionalPaths: []
		)
		print("CommandPathResolver.resolve(\"claude\") returned: \(claudePath)")

		// Try to resolve codex as well
		print("\n--- Codex Resolution Test ---")
		let codexPath = CommandPathResolver.resolve(
			"codex",
			environment: env,
			additionalPaths: []
		)
		print("CommandPathResolver.resolve(\"codex\") returned: \(codexPath)")

		// Check if the resolved paths are executable
		if claudePath != "claude" {
			let fm = FileManager.default
			var isDir: ObjCBool = false
			let exists = fm.fileExists(atPath: claudePath, isDirectory: &isDir)
			print("  - Path exists: \(exists)")
			print("  - Is directory: \(isDir.boolValue)")
			if exists && !isDir.boolValue {
				print("  - Is executable: \(access(claudePath, X_OK) == 0)")
			}
		} else {
			print("  - Claude was not resolved to a path")
		}

		if codexPath != "codex" {
			let fm = FileManager.default
			var isDir: ObjCBool = false
			let exists = fm.fileExists(atPath: codexPath, isDirectory: &isDir)
			print("  - Path exists: \(exists)")
			print("  - Is directory: \(isDir.boolValue)")
			if exists && !isDir.boolValue {
				print("  - Is executable: \(access(codexPath, X_OK) == 0)")
			}
		} else {
			print("  - Codex was not resolved to a path")
		}

		print("\n========== End Integration Test ==========\n")

		// Basic assertion: captured environment should at least have a PATH
		XCTAssertNotNil(env["PATH"], "Captured environment should have a PATH")
		XCTAssertFalse(env["PATH"]?.isEmpty ?? true, "PATH should not be empty")
	}
}



// MARK: - Merged from CommandPathResolverTests.swift


extension ProcessCoreTests {

	/// Helper to ensure temp directories are cleaned up properly, even on test failure
	private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
		let fm = FileManager.default
		let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

		addTeardownBlock {
			do {
				if fm.fileExists(atPath: tempDir.path) {
					try fm.removeItem(at: tempDir)
				}
			} catch {
				XCTFail("Failed to clean up temp directory at \(tempDir.path): \(error)")
			}
		}

		return try body(tempDir)
	}

	func testResolveFallsBackToAdditionalPaths() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default
			let toolName = "codex-test-tool"
			let toolURL = tempDir.appendingPathComponent(toolName)
			let scriptData = try XCTUnwrap("exit 0\n".data(using: .utf8))
			try scriptData.write(to: toolURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: toolURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
			]

			let resolved = CommandPathResolver.resolve(
				toolName,
				environment: environment,
				additionalPaths: [tempDir.path]
			)

			XCTAssertEqual(resolved, toolURL.path, "Resolver should locate executables that live only in additional paths.")
		}
	}
	
	func testResolveSplitsCompositeAdditionalPathEntries() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default
			let toolName = "codex-test-tool-alt"
			let toolURL = tempDir.appendingPathComponent(toolName)
			let scriptData = try XCTUnwrap("exit 0\n".data(using: .utf8))
			try scriptData.write(to: toolURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: toolURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
			]

			let combinedAdditionalPath = "/nonexistent:\(tempDir.path)"
			let resolved = CommandPathResolver.resolve(
				toolName,
				environment: environment,
				additionalPaths: [combinedAdditionalPath]
			)

			XCTAssertEqual(resolved, toolURL.path, "Resolver should search through colon-separated additional path entries.")
		}
	}

	func testResolveHandlesAliasTargetWithDifferentExecutableName() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create the executable that the alias points to.
			let aliasTargetURL = tempDir.appendingPathComponent("claude")
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: aliasTargetURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: aliasTargetURL.path)

			// Fake shell that emits the sentinel output our resolver expects, returning an alias whose
			// target command name does not match the alias name (claudecode -> claude).
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "claudecode: aliased to \(aliasTargetURL.path)\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			let fakeShellData = try XCTUnwrap(fakeShellContents.data(using: .utf8))
			try fakeShellData.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claudecode",
				environment: environment,
				additionalPaths: []
			)

			XCTAssertEqual(resolved, aliasTargetURL.path, "Resolver should accept alias targets whose filenames differ from the alias name.")
		}
	}

	func testSanitizedExecutableOutputHandlesQuotedSpaces() throws {
		let line = "alias claudecode='/tmp/My Tools/claude \"$@\"'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claudecode")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/tmp/My Tools/claude")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testSanitizedExecutableOutputHandlesEscapedSpaces() throws {
		let line = "claudecode: aliased to /tmp/My\\ Tools/claude \"$@\""
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claudecode")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/tmp/My Tools/claude")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testAliasTargetBareCommandResolvesViaAdditionalPaths() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			let claudeURL = tempDir.appendingPathComponent("claude")
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: claudeURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: claudeURL.path)

			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "claudecode: aliased to claude \\"$@\\"\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			let fakeShellData = try XCTUnwrap(fakeShellContents.data(using: .utf8))
			try fakeShellData.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claudecode",
				environment: environment,
				additionalPaths: [tempDir.path]
			)

			XCTAssertEqual(resolved, claudeURL.path, "Resolver should locate bare alias targets via additional path search.")
		}
	}

	func testResolveAcceptsVersionedBareShellOutput() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			let versionedExecutable = tempDir.appendingPathComponent("claude2")
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: versionedExecutable)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: versionedExecutable.path)

			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "claude2\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			let fakeShellData = try XCTUnwrap(fakeShellContents.data(using: .utf8))
			try fakeShellData.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": tempDir.path,
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claude",
				environment: environment,
				additionalPaths: []
			)

			XCTAssertEqual(resolved, versionedExecutable.path, "Resolver should accept versioned bare shell outputs (e.g., claude2) for the base command.")
		}
	}

	func testAliasThatPointsBackToCommandStillLocatesActualExecutable() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default
			let claudeExecutable = tempDir.appendingPathComponent("claude")
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: claudeExecutable)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: claudeExecutable.path)

			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "claude: aliased to claude --permission-mode plan --dangerously-skip-permissions\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			let fakeShellData = try XCTUnwrap(fakeShellContents.data(using: .utf8))
			try fakeShellData.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "\(tempDir.path):/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claude",
				environment: environment,
				additionalPaths: []
			)

			XCTAssertEqual(resolved, claudeExecutable.path, "Resolver should fallback to PATH search when alias output reuses the base command name.")
		}
	}

	func testSanitizedExecutableOutputSkipsWrapperCommands() throws {
		let line = "claudecode: aliased to command claude \"$@\""
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claudecode")
		XCTAssertEqual(sanitized?.path, "claude")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testSanitizedExecutableOutputHandlesEnvWrapper() throws {
		let line = "alias claudecode='/usr/bin/env PATH=\"/tmp/bin:$PATH\" claude \"$@\"'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claudecode")
		XCTAssertEqual(sanitized?.path, "claude")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	// MARK: - Real-world stress tests

	func testRealWorldAbsolutePathAlias() throws {
		// Based on actual alias: claude="/Users/example/.claude/local/claude"
		let line = "alias claude='/Users/example/.claude/local/claude'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claude")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/Users/example/.claude/local/claude")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testVersionManagerPathWithVersionNumber() throws {
		// Based on nvm: /Users/example/.nvm/versions/node/v22.18.0/bin/node
		let line = "node: /Users/example/.nvm/versions/node/v22.18.0/bin/node"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "node")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/Users/example/.nvm/versions/node/v22.18.0/bin/node")
	}

	func testArrowNotationOutput() throws {
		// Some which implementations use arrow notation
		let line = "git -> /usr/bin/git"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "git")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/usr/bin/git")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testMultipleWrapperCommandsChained() throws {
		// Complex wrapper: sudo + env + command
		let line = "alias deploy='sudo /usr/bin/env PATH=\"/opt/bin:$PATH\" command deploy-tool'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "deploy")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "deploy-tool")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testMultipleEnvironmentAssignments() throws {
		// Multiple env vars in wrapper
		let line = "alias build='env NODE_ENV=production DEBUG=* npm run build'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "build")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "npm")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testMixedQuotingStyles() throws {
		// Single and double quotes mixed
		let line = #"alias test='sh -c "echo \"hello\" && /usr/local/bin/tool"'"#
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "test")
		XCTAssertNotNil(sanitized?.path)
		// Should extract the path /usr/local/bin/tool
		XCTAssertTrue(sanitized?.path.contains("/usr/local/bin/tool") ?? false)
	}

	func testParenthesesInOutput() throws {
		// Some shells wrap output in parentheses
		let line = "alias foo='(/usr/local/bin/bar)'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "foo")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/usr/local/bin/bar")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testPathWithDotsAndUnderscores() throws {
		// Paths with special characters common in version managers
		let line = "python: /opt/homebrew/Cellar/python@3.11/3.11.6_1/bin/python3.11"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "python")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/opt/homebrew/Cellar/python@3.11/3.11.6_1/bin/python3.11")
	}

	func testAliasWithBacktickSubstitution() throws {
		// Alias that contains command substitution (should extract path before backticks)
		let line = "alias docker='/usr/local/bin/docker `some-config-command`'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "docker")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/usr/local/bin/docker")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testZshIsAliasedToFormat() throws {
		// Zsh's "is aliased to" format (already has a test, but adding comprehensive version)
		let line = "ll is aliased to `ls -lah'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "ll")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "ls")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testIntegrationNvmStylePathResolution() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create nvm-style directory structure: .nvm/versions/node/v22.18.0/bin/node
			let nvmPath = tempDir.appendingPathComponent(".nvm/versions/node/v22.18.0/bin", isDirectory: true)
			try fm.createDirectory(at: nvmPath, withIntermediateDirectories: true)

			let nodeURL = nvmPath.appendingPathComponent("node")
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: nodeURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: nodeURL.path)

			// Fake shell that returns nvm-style path
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "\(nodeURL.path)\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			let fakeShellData = try XCTUnwrap(fakeShellContents.data(using: .utf8))
			try fakeShellData.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"node",
				environment: environment,
				additionalPaths: []
			)

			XCTAssertEqual(resolved, nodeURL.path, "Resolver should handle nvm-style version manager paths.")
		}
	}

	func testIntegrationComplexAliasWithWrappers() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create the actual executable
			let toolURL = tempDir.appendingPathComponent("actual-tool")
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: toolURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: toolURL.path)

			// Fake shell that returns complex alias with multiple wrappers
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "mytool: aliased to env DEBUG=1 command \\"\(toolURL.path)\\" \\\\"\\$@\\\\"\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			let fakeShellData = try XCTUnwrap(fakeShellContents.data(using: .utf8))
			try fakeShellData.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"mytool",
				environment: environment,
				additionalPaths: []
			)

			XCTAssertEqual(resolved, toolURL.path, "Resolver should extract executable from complex wrapper chains.")
		}
	}

	// MARK: - Regression Tests for Volta and Argument Stripping

	func testVoltaStyleSymlinkResolution() throws {
		// Tests the fix for: trusting shell-resolved paths even when they're symlinks
		// Issue: Volta uses symlinks that may not pass isExecutableRegularFile checks
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create a target script (like Volta's cli.js)
			let targetURL = tempDir.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/cli.js")
			try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			let scriptData = try XCTUnwrap("#!/usr/bin/env node\nconsole.log('claude');\n".data(using: .utf8))
			try scriptData.write(to: targetURL)
			// Note: cli.js might NOT have execute bit set (relies on shebang + symlink)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o644))], ofItemAtPath: targetURL.path)

			// Create the symlink (like Volta's bin/claude -> ../lib/.../cli.js)
			let symlinkURL = tempDir.appendingPathComponent(".volta/bin/claude")
			try fm.createDirectory(at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

			// Fake shell that returns the symlink path (as `command -v claude` would)
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "\(symlinkURL.path)\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			try fakeShellContents.data(using: .utf8)?.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claude",
				environment: environment,
				additionalPaths: []
			)

			// Should trust the shell and return the symlink path, even if the target isn't +x
			XCTAssertEqual(resolved, symlinkURL.path, "Should trust shell-resolved symlink paths (Volta-style) even when target lacks execute bit")
		}
	}

	func testAliasWithArgumentsNotMergedIntoPath() throws {
		// Tests the fix for: greedy path coalescing incorrectly merging arguments into the path
		// Issue: `alias claude='/usr/bin/claude verbose mode'` was being resolved to "/usr/bin/claude verbose mode"
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create the actual executable
			let claudeURL = tempDir.appendingPathComponent("bin/claude")
			try fm.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: claudeURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: claudeURL.path)

			// Fake shell that returns an alias with arguments (that should NOT be merged)
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "claude: aliased to '\(claudeURL.path) verbose mode'\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			try fakeShellContents.data(using: .utf8)?.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claude",
				environment: environment,
				additionalPaths: []
			)

			// Should extract ONLY the executable path, NOT merge "verbose mode" into it
			XCTAssertEqual(resolved, claudeURL.path, "Should extract only the executable path from alias, not merge arguments")
		}
	}

	func testAliasWithSpacedPathAndArgumentsCorrectlySeparated() throws {
		// Tests combination: path with spaces + arguments that should be stripped
		// Issue: Greedy coalescing would merge everything together
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create executable in a path with spaces
			let claudeURL = tempDir.appendingPathComponent("My Dev Tools/claude")
			try fm.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			let scriptData = try XCTUnwrap("#!/bin/sh\nexit 0\n".data(using: .utf8))
			try scriptData.write(to: claudeURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: claudeURL.path)

			// Fake shell that returns properly quoted path with spaces + arguments
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "claude: aliased to '\(claudeURL.path)' --verbose --yolo\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			try fakeShellContents.data(using: .utf8)?.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claude",
				environment: environment,
				additionalPaths: []
			)

			// Should extract the path with spaces, but NOT the --verbose --yolo arguments
			XCTAssertEqual(resolved, claudeURL.path, "Should handle path with spaces correctly while stripping dash arguments")
		}
	}

	func testYoloScriptStyleAliasWithArguments() throws {
		// Real-world test case: yolo script that runs `claude --verbose --dangerously-skip-permissions`
		// The shell might resolve this to an alias with arguments
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create the claude executable
			let claudeURL = tempDir.appendingPathComponent(".volta/bin/claude")
			try fm.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			let scriptData = try XCTUnwrap("#!/usr/bin/env node\nconsole.log('claude');\n".data(using: .utf8))
			try scriptData.write(to: claudeURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: claudeURL.path)

			// Fake shell that returns the resolved path (no alias, but with potential arguments)
			let fakeShellURL = tempDir.appendingPathComponent("fake-shell.sh")
			let fakeShellContents = """
			#!/bin/sh
			printf "__RP_BEGIN__\\n"
			printf "\(claudeURL.path)\\n"
			printf "__RP_END__\\n"
			exit 0
			"""
			try fakeShellContents.data(using: .utf8)?.write(to: fakeShellURL)
			try fm.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: fakeShellURL.path)

			let environment: [String: String] = [
				"PATH": "/usr/bin:/bin",
				"SHELL": fakeShellURL.path
			]

			let resolved = CommandPathResolver.resolve(
				"claude",
				environment: environment,
				additionalPaths: []
			)

			// Should resolve to the clean path
			XCTAssertEqual(resolved, claudeURL.path, "Should resolve Volta-managed claude correctly")
		}
	}

	func testSanitizedExecutableOutputStripsArgumentsFromAlias() throws {
		// Unit test for sanitizedExecutableOutput to ensure it doesn't merge arguments
		let line = "claude: aliased to /usr/local/bin/claude --verbose --dangerously-skip-permissions"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claude")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/usr/local/bin/claude", "Should extract only the executable path, not arguments")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testSanitizedExecutableOutputHandlesNonDashArguments() throws {
		// Test the specific case that was broken: non-dash arguments like "verbose mode"
		let line = "claude: aliased to /usr/bin/claude verbose mode extra"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claude")
		XCTAssertNotNil(sanitized?.path)
		// Should extract ONLY the path, not "verbose mode extra"
		XCTAssertEqual(sanitized?.path, "/usr/bin/claude", "Should not merge non-dash arguments into the path")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testAliasInApplicationSupportVolta() throws {
		// Regression test for spaces-in-path issue with "Application Support" directory
		// Previously, the resolver would stop at "Application" and truncate the path
		let line = "alias claude='/Users/alice/Library/Application Support/Volta/bin/claude'"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "claude")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/Users/alice/Library/Application Support/Volta/bin/claude")
		XCTAssertEqual(sanitized?.isAliasTarget, true)
	}

	func testNonAliasApplicationSupportPath() throws {
		// Regression test for spaces-in-path with direct command -v output (not an alias)
		// Issue: "Command not found: Support/reflex/bun/bin/codex"
		// Path was being truncated when "Application Support" was split into tokens
		let line = "/Users/bob/Library/Application Support/reflex/bun/bin/codex"
		let sanitized = CommandPathResolver.sanitizedExecutableOutput(line, originalCommand: "codex")
		XCTAssertNotNil(sanitized?.path)
		XCTAssertEqual(sanitized?.path, "/Users/bob/Library/Application Support/reflex/bun/bin/codex", "Should merge all path segments even for non-alias output")
		XCTAssertEqual(sanitized?.isAliasTarget, false)
	}

	// MARK: - Kitchen Sink Test

	func testKitchenSinkBusyShellEnvironment() throws {
		try withTempDirectory { tempDir in
			let fm = FileManager.default

			// Create a complex directory structure simulating a real development environment

		// 1. nvm-style node installation
		let nvmPath = tempDir.appendingPathComponent(".nvm/versions/node/v22.18.0/bin", isDirectory: true)
		try fm.createDirectory(at: nvmPath, withIntermediateDirectories: true)
		let nodeURL = nvmPath.appendingPathComponent("node")
		try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: nodeURL)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodeURL.path)

		// 2. Tool with spaces in path
		let spacedPath = tempDir.appendingPathComponent("My Dev Tools", isDirectory: true)
		try fm.createDirectory(at: spacedPath, withIntermediateDirectories: true)
		let claudeURL = spacedPath.appendingPathComponent("claude")
		try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: claudeURL)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeURL.path)

		// 3. Homebrew-style path with special characters
		let brewPath = tempDir.appendingPathComponent("homebrew/Cellar/python@3.11/3.11.6_1/bin", isDirectory: true)
		try fm.createDirectory(at: brewPath, withIntermediateDirectories: true)
		let pythonURL = brewPath.appendingPathComponent("python3.11")
		try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: pythonURL)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonURL.path)

		// 4. Custom tool directory
		let customBin = tempDir.appendingPathComponent("custom/bin", isDirectory: true)
		try fm.createDirectory(at: customBin, withIntermediateDirectories: true)
		let deployURL = customBin.appendingPathComponent("deploy-prod")
		try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: deployURL)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deployURL.path)

		// 5. Docker with config
		let dockerURL = customBin.appendingPathComponent("docker")
		try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: dockerURL)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dockerURL.path)

		// Create a "busy" fake shell that returns complex output with:
		// - Multiple alias formats
		// - Wrapper commands (env, sudo, command)
		// - Environment variable assignments
		// - Command substitutions
		// - Paths with spaces and special characters
		// - Different sentinel-delimited outputs
		let fakeShellURL = tempDir.appendingPathComponent("fake-busy-shell.sh")
		let fakeShellContents = """
		#!/bin/sh

		# Simulate a busy shell with lots of startup noise
		# (real shells output profile banners, prompt setup, etc.)

		case "$4" in
		  *"command -v node"*)
		    # nvm-managed node - typical version manager output
		    printf "__RP_BEGIN__\\n"
		    printf "\(nodeURL.path)\\n"
		    printf "__RP_END__\\n"
		    ;;
		  *"command -v claudecode"*)
		    # Alias with spaces in path + argument forwarding
		    printf "__RP_BEGIN__\\n"
		    printf "claudecode: aliased to '\(claudeURL.path) \\"\\$@\\"'\\n"
		    printf "__RP_END__\\n"
		    ;;
		  *"command -v python"*)
		    # Homebrew-style path with @ and version numbers
		    printf "__RP_BEGIN__\\n"
		    printf "python: \(pythonURL.path)\\n"
		    printf "__RP_END__\\n"
		    ;;
		  *"command -v deploy"*)
		    # Complex alias: sudo + env + multiple env vars + command wrapper
		    printf "__RP_BEGIN__\\n"
		    printf "deploy: aliased to 'sudo /usr/bin/env NODE_ENV=production DEBUG=* command \(deployURL.path)'\\n"
		    printf "__RP_END__\\n"
		    ;;
		  *"command -v dkr"*)
		    # Alias with backtick command substitution that should be stripped
		    printf "__RP_BEGIN__\\n"
		    printf "dkr: aliased to '\(dockerURL.path) \\`load-config\\` run'\\n"
		    printf "__RP_END__\\n"
		    ;;
		  *)
		    exit 1
		    ;;
		esac
		exit 0
		"""
		try fakeShellContents.data(using: .utf8)?.write(to: fakeShellURL)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShellURL.path)

		let environment: [String: String] = [
			"PATH": "/usr/bin:/bin",
			"SHELL": fakeShellURL.path,
			"HOME": tempDir.path,
			"NVM_DIR": tempDir.appendingPathComponent(".nvm").path
		]

		// Test 1: nvm-managed node with version in path
		let resolvedNode = CommandPathResolver.resolve(
			"node",
			environment: environment,
			additionalPaths: []
		)
		XCTAssertEqual(resolvedNode, nodeURL.path, "Should resolve nvm-style node path with version numbers")

		// Test 2: Alias with spaces in executable path + argument forwarding
		let resolvedClaude = CommandPathResolver.resolve(
			"claudecode",
			environment: environment,
			additionalPaths: []
		)
		XCTAssertEqual(resolvedClaude, claudeURL.path, "Should handle alias with spaces in path and strip argument forwarding")

		// Test 3: Homebrew-style path with @ and underscores
		let resolvedPython = CommandPathResolver.resolve(
			"python",
			environment: environment,
			additionalPaths: []
		)
		XCTAssertEqual(resolvedPython, pythonURL.path, "Should resolve Homebrew paths with special characters (@, dots, underscores)")

		// Test 4: Complex wrapper chain: sudo + env + env vars + command
		let resolvedDeploy = CommandPathResolver.resolve(
			"deploy",
			environment: environment,
			additionalPaths: []
		)
		XCTAssertEqual(resolvedDeploy, deployURL.path, "Should extract executable from complex sudo + env + command wrapper chain")

		// Test 5: Alias with backtick command substitution
		let resolvedDocker = CommandPathResolver.resolve(
			"dkr",
			environment: environment,
			additionalPaths: []
		)
		XCTAssertEqual(resolvedDocker, dockerURL.path, "Should strip backtick command substitution and extract executable path")

		// Bonus: Verify that the fake shell is actually being queried (not falling back)
		// by resolving something that doesn't exist - should fall back to original
		let resolvedNonExistent = CommandPathResolver.resolve(
			"totally-fake-command-xyz",
			environment: environment,
			additionalPaths: []
		)
		XCTAssertEqual(resolvedNonExistent, "totally-fake-command-xyz", "Should fall back to original command when not found")
		}
	}
}



// MARK: - Merged from LineFramerTests.swift


extension ProcessCoreTests {
	func testEmitsCompleteLinesWithinSingleChunk() {
		var framer = LineFramer()
		let input = Data("first\nsecond\n".utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines, ["first", "second"])
	}

	func testEmitsLinesAcrossChunkBoundaries() {
		var framer = LineFramer()
		let chunk1 = Data("first\nse".utf8)
		let chunk2 = Data("cond\nthi".utf8)
		let chunk3 = Data("rd".utf8)
		var lines: [String] = []

		framer.feed(chunk1) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.feed(chunk2) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.feed(chunk3) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines, ["first", "second", "third"])
	}

	func testFlushReturnsTrailingBytes() {
		var framer = LineFramer()
		let chunk = Data("no-newline".utf8)
		var lines: [String] = []

		framer.feed(chunk) { lines.append(String(decoding: $0, as: UTF8.self)) }
		XCTAssertTrue(lines.isEmpty, "Should not emit when newline missing")

		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }
		XCTAssertEqual(lines, ["no-newline"])
	}

	func testPreservesRawNewlineInsideJSONStringUntilRecordNewline() {
		var framer = LineFramer()
		let payload = """
		{"type":"user","message":{"role":"user","content":[{"type":"text","text":"line one
		line two"}]}}
		"""
		let input = Data((payload + "\n").utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 1)
		XCTAssertEqual(lines.first, payload)
	}

	func testPreservesRawNewlineInsideJSONStringAcrossChunkBoundary() {
		var framer = LineFramer()
		let payload = """
		{"type":"user","message":{"role":"user","content":[{"type":"text","text":"line one
		line two"}]}}
		"""
		let full = Data((payload + "\n").utf8)
		let split = payload.utf8.count / 2
		let chunk1 = full.subdata(in: 0..<split)
		let chunk2 = full.subdata(in: split..<full.count)
		var lines: [String] = []

		framer.feed(chunk1) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.feed(chunk2) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 1)
		XCTAssertEqual(lines.first, payload)
	}

	func testMakeUTF8SampleRespectsCharacterBoundaries() {
		let snowman = "☃️" // multi-byte emoji
		let data = Data((snowman + snowman + snowman).utf8)

		let result = makeUTF8Sample(from: data, limit: 5)

		XCTAssertNotNil(result)
		let (sample, truncated) = result!
		XCTAssertTrue(sample.hasPrefix("☃"), "Sample should include at least the first snowman character")
		XCTAssertTrue(truncated)
	}

	func testTrimmedASCIIWhitespaceRemovesBothEnds() {
		let data = Data(" \n trimmed \t".utf8)

		let trimmed = trimmedASCIIWhitespace(data)

		XCTAssertEqual(trimmed, Data("trimmed".utf8))
	}

	func testTrimmedASCIIWhitespaceReturnsNilForWhitespaceOnly() {
		let whitespace = Data(" \n\t\r".utf8)

		XCTAssertNil(trimmedASCIIWhitespace(whitespace))
	}

	func testRepairJSONStringControlCharactersEscapesRawLFInsideString() throws {
		let raw = Data("{\"text\":\"line one\nline two\"}".utf8)

		let repaired = repairJSONStringControlCharacters(raw)

		XCTAssertNotNil(repaired)
		let repairedData = try XCTUnwrap(repaired)
		XCTAssertEqual(String(data: repairedData, encoding: .utf8), "{\"text\":\"line one\\nline two\"}")
		let json = try JSONSerialization.jsonObject(with: repairedData) as? [String: Any]
		XCTAssertEqual(json?["text"] as? String, "line one\nline two")
	}

	func testRepairJSONStringControlCharactersReturnsNilForNonJSONCandidate() {
		let raw = Data("line one\nline two".utf8)

		XCTAssertNil(repairJSONStringControlCharacters(raw))
	}

	func testRepairJSONStringControlCharactersReturnsNilWhenNoControlCharsNeedRepair() {
		let raw = Data("{\"text\":\"line one\\nline two\"}".utf8)

		XCTAssertNil(repairJSONStringControlCharacters(raw))
	}

	func testLineFramerStressInterleavedJSONAndGarbageAcrossChunkBoundaries() throws {
		var records: [String] = []
		var expectedJSONCandidateCount = 0
		for index in 0..<400 {
			if index % 3 == 0 {
				let record = "{\"index\":\(index),\"text\":\"line \(index) a\nline \(index) b\",\"kind\":\"object\"}"
				records.append(record)
				expectedJSONCandidateCount += 1
			} else if index % 3 == 1 {
				records.append("garbage \"quoted fragment \(index)")
			} else {
				let record = "[{\"index\":\(index),\"text\":\"array \(index) a\narray \(index) b\"}]"
				records.append(record)
				expectedJSONCandidateCount += 1
			}
		}

		let input = Data((records.joined(separator: "\n") + "\n").utf8)
		var framer = LineFramer()
		var emitted: [String] = []
		var offset = 0
		var seed: UInt64 = 0xC0D3_510F

		while offset < input.count {
			seed = seed &* 6_364_136_223_846_793_005 &+ 1
			let chunkSize = Int((seed >> 33) % 31) + 1
			let upperBound = min(offset + chunkSize, input.count)
			framer.feed(input.subdata(in: offset..<upperBound)) {
				emitted.append(String(decoding: $0, as: UTF8.self))
			}
			offset = upperBound
		}
		framer.flush {
			emitted.append(String(decoding: $0, as: UTF8.self))
		}

		XCTAssertEqual(emitted.count, records.count)
		XCTAssertEqual(emitted, records)

		var recoveredJSONCount = 0
		for line in emitted {
			let data = Data(line.utf8)
			guard let trimmed = trimmedASCIIWhitespace(data),
				let firstByte = trimmed.first,
				firstByte == 0x7B || firstByte == 0x5B
			else {
				continue
			}

			if (try? JSONSerialization.jsonObject(with: trimmed)) != nil {
				recoveredJSONCount += 1
				continue
			}

			let repaired = try XCTUnwrap(repairJSONStringControlCharacters(trimmed))
			XCTAssertNotNil(try? JSONSerialization.jsonObject(with: repaired))
			recoveredJSONCount += 1
		}

		XCTAssertEqual(recoveredJSONCount, expectedJSONCandidateCount)
	}

	func testRepairJSONStringControlCharactersStressEscapesAllASCIIControls() throws {
		var raw = Data("{\"text\":\"".utf8)
		for byte in UInt8.min...0x1F {
			raw.append(byte)
		}
		raw.append(contentsOf: "\"}".utf8)

		let repaired = try XCTUnwrap(repairJSONStringControlCharacters(raw))
		XCTAssertFalse(repaired.contains(where: { $0 < 0x20 }))

		let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: repaired) as? [String: Any])
		let text = try XCTUnwrap(decoded["text"] as? String)
		let scalarValues = text.unicodeScalars.map(\.value)
		XCTAssertEqual(scalarValues, Array(UInt32(0)...UInt32(0x1F)))
	}

	func testMakeUTF8SampleReturnsNilWhenLimitTooSmall() {
		let snowman = "☃️"
		let data = Data(snowman.utf8)

		let result = makeUTF8Sample(from: data, limit: 1)

		XCTAssertNil(result)
	}

	func testMakeUTF8SampleHandlesMixedASCIIAndEmoji() {
		let message = "Hello ☃️"
		let data = Data(message.utf8)

		let result = makeUTF8Sample(from: data, limit: 7)

		XCTAssertNotNil(result)
		let (sample, truncated) = result!
		XCTAssertEqual(sample, "Hello ")
		XCTAssertTrue(truncated)
	}

	func testAppendTailRetainsOnlyLimit() {
		var tail = Data()
		let chunkA = Data(repeating: 0x61, count: 100) // 'a'
		let chunkB = Data(repeating: 0x62, count: 100) // 'b'

		appendTail(&tail, chunk: chunkA, limit: 150)
		appendTail(&tail, chunk: chunkB, limit: 150)

		XCTAssertEqual(tail.count, 150)
		XCTAssertTrue(tail.prefix(50).allSatisfy { $0 == 0x61 })
		XCTAssertTrue(tail.suffix(100).allSatisfy { $0 == 0x62 })
	}

	func testAppendTailWithZeroLimitDropsAllData() {
		var tail = Data()
		appendTail(&tail, chunk: Data("data".utf8), limit: 0)
		XCTAssertTrue(tail.isEmpty)
	}

	// MARK: - JSON-Candidate Gating

	func testNonJSONCandidateLineSplitsOnNewlineEvenWithQuotes() {
		// Garbage line with unbalanced quotes should NOT suppress newline splitting.
		// Before JSON-candidate gating, the quote in "hello" would toggle inJSONString,
		// causing the next newline to be swallowed.
		var framer = LineFramer()
		let input = Data("garbage \"hello\nsecond\n".utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines, ["garbage \"hello", "second"])
	}

	func testJSONCandidateLinePreservesNewlineInsideString() {
		// JSON-candidate lines (starting with {) should still preserve newlines inside strings.
		var framer = LineFramer()
		let json = "{\"text\":\"line one\nline two\"}"
		let input = Data((json + "\n").utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 1)
		XCTAssertEqual(lines.first, json)
	}

	func testGarbageLineDoesNotPoisonSubsequentJSONLine() {
		// A garbage line with quotes followed by a JSON line should not cause the JSON
		// line's framing to be poisoned by leftover inJSONString state.
		var framer = LineFramer()
		let garbageLine = "some minified JS with \"quotes and more \"stuff\n"
		let jsonLine = "{\"type\":\"content\",\"text\":\"hello\"}\n"
		let input = Data((garbageLine + jsonLine).utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 2)
		XCTAssertEqual(lines[0], String(garbageLine.dropLast())) // without trailing \n
		XCTAssertEqual(lines[1], String(jsonLine.dropLast()))
	}

	func testArrayCandidateLinePreservesNewlineInsideString() {
		// Lines starting with [ should also get quote tracking.
		var framer = LineFramer()
		let json = "[{\"text\":\"line\none\"}]"
		let input = Data((json + "\n").utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 1)
		XCTAssertEqual(lines.first, json)
	}

	func testLeadingWhitespaceBeforeJSONCandidateStillGetsQuoteTracking() {
		// Lines with leading whitespace before { should still be JSON candidates.
		var framer = LineFramer()
		let json = "  {\"text\":\"has\nnewline\"}"
		let input = Data((json + "\n").utf8)
		var lines: [String] = []

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 1)
		XCTAssertEqual(lines.first, json)
	}

	// MARK: - Size Limits & Overflow

	func testOverflowTriggersCarryTruncationAndDiagnostic() {
		let limits = LineFramer.Limits(maxLineBytes: 100, maxCarryBytes: 100, tailRetainBytes: 20)
		var framer = LineFramer(limits: limits)
		// Feed a chunk larger than maxCarryBytes without any newlines.
		let bigChunk = Data(repeating: 0x41, count: 150) // 'A' * 150
		var lines: [String] = []
		var diagnostics: [LineFramer.Diagnostic] = []

		framer.feed(bigChunk, onDiagnostic: { diagnostics.append($0) }) {
			lines.append(String(decoding: $0, as: UTF8.self))
		}

		// No complete lines emitted (no newline in input).
		XCTAssertTrue(lines.isEmpty)

		// Should have at least one overflow diagnostic.
		let overflows = diagnostics.compactMap { diagnostic -> (Int, Int)? in
			if case .overflow(let dropped, let retained) = diagnostic {
				return (dropped, retained)
			}
			return nil
		}
		XCTAssertFalse(overflows.isEmpty, "Expected at least one overflow diagnostic")

		// After overflow, a newline should emit whatever was retained + any new bytes.
		framer.feed(Data("\n".utf8), onDiagnostic: { diagnostics.append($0) }) {
			lines.append(String(decoding: $0, as: UTF8.self))
		}
		XCTAssertEqual(lines.count, 1, "Should emit one line after overflow + newline")
	}

	func testOverflowResetsQuoteTrackingState() {
		// After overflow, poisoned quote state should be cleared.
		let limits = LineFramer.Limits(maxLineBytes: 50, maxCarryBytes: 50, tailRetainBytes: 10)
		var framer = LineFramer(limits: limits)

		// Feed a JSON candidate that starts quote tracking, then exceeds the limit.
		let start = Data("{\"key\":\"".utf8) // 8 bytes, sets inJSONString=true
		let filler = Data(repeating: 0x41, count: 50) // 'A' * 50, causes overflow
		var lines: [String] = []
		var diagnostics: [LineFramer.Diagnostic] = []

		framer.feed(start, onDiagnostic: { diagnostics.append($0) }) {
			lines.append(String(decoding: $0, as: UTF8.self))
		}
		framer.feed(filler, onDiagnostic: { diagnostics.append($0) }) {
			lines.append(String(decoding: $0, as: UTF8.self))
		}

		// Now feed a new line that should NOT have poisoned state.
		// If quote tracking was properly reset, this newline should split normally.
		let newData = Data("next-line\n".utf8)
		framer.feed(newData, onDiagnostic: { diagnostics.append($0) }) {
			lines.append(String(decoding: $0, as: UTF8.self))
		}

		// We should get at least one line from the overflow tail + newData.
		XCTAssertFalse(lines.isEmpty, "Should emit at least one line after overflow + newline")

		let hasOverflow = diagnostics.contains { if case .overflow = $0 { return true }; return false }
		XCTAssertTrue(hasOverflow, "Expected overflow diagnostic")
	}

	func testDefaultLimitsAreReasonable() {
		let limits = LineFramer.Limits.default
		XCTAssertGreaterThan(limits.maxLineBytes, 0)
		XCTAssertGreaterThanOrEqual(limits.maxCarryBytes, limits.maxLineBytes)
		XCTAssertGreaterThan(limits.tailRetainBytes, 0)
		XCTAssertLessThanOrEqual(limits.tailRetainBytes, limits.maxCarryBytes)
	}

	func testFlushResetsJSONCandidateState() {
		// After flush, the framer's JSON-candidate and quote tracking state should be clean,
		// so a subsequent non-JSON line is handled correctly.
		var framer = LineFramer()
		var lines: [String] = []

		// Feed an incomplete JSON line (no newline) — leaves state mid-parse.
		framer.feed(Data("{\"text\":\"open".utf8)) { _ in }
		// Flush to emit the incomplete carry and reset all state.
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 1)
		XCTAssertEqual(lines[0], "{\"text\":\"open")

		// Now feed a non-JSON line — should split normally on newline.
		framer.feed(Data("garbage with \"quotes\"\nsecond\n".utf8)) {
			lines.append(String(decoding: $0, as: UTF8.self))
		}

		XCTAssertEqual(lines.count, 3)
		XCTAssertEqual(lines[1], "garbage with \"quotes\"")
		XCTAssertEqual(lines[2], "second")
	}

	func testMultipleJSONLinesWithInterleavedGarbage() {
		// Verifies that JSON-candidate gating correctly handles alternating JSON and garbage lines.
		var framer = LineFramer()
		var lines: [String] = []

		let input = Data("""
		{"type":"content","text":"hello"}
		some garbage with "quotes" and stuff
		{"type":"done"}
		more garbage "here"

		""".utf8)

		framer.feed(input) { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines.count, 4)
		XCTAssertEqual(lines[0], "{\"type\":\"content\",\"text\":\"hello\"}")
		XCTAssertEqual(lines[1], "some garbage with \"quotes\" and stuff")
		XCTAssertEqual(lines[2], "{\"type\":\"done\"}")
		XCTAssertEqual(lines[3], "more garbage \"here\"")
	}
}



// MARK: - Merged from ProviderStreamParsingTests.swift


extension ProcessCoreTests {
	func testClaudeParseStreamEventsSkipsWhitespace() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let eventData = Data("   \n".utf8)

		let events = try provider.parseStreamEvents(eventData)

		XCTAssertTrue(events.isEmpty)
	}

	func testClaudeParseStreamEventsParsesMessage() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"message","content":"hello","reasoning":null}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertEqual(events.count, 1)
		guard let firstEvent = events.first else {
			XCTFail("Expected message event")
			return
		}
		if case let .message(content, _) = firstEvent {
			XCTAssertEqual(content, "hello")
		} else {
			XCTFail("Expected message event")
		}
	}

	func testClaudeParseStreamEventsParsesStreamEventTextDelta() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertEqual(events.count, 1)
		if case let .message(content, reasoning) = events[0] {
			XCTAssertEqual(content, "Hello")
			XCTAssertNil(reasoning)
		} else {
			XCTFail("Expected stream_event to map to message delta")
		}
	}

	func testClaudeParseStreamEventsParsesAssistantToolUseBlocks() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"read_file","input":{"path":"README.md"}}]}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertEqual(events.count, 1)
		if case let .toolCall(name, args) = events[0] {
			XCTAssertEqual(name, "read_file")
			XCTAssertEqual(args["path"] as? String, "README.md")
		} else {
			XCTFail("Expected assistant tool_use block to map to toolCall")
		}
	}

	func testClaudeParseStreamEventsParsesAssistantTextAndThinkingBlocks() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"},{"type":"thinking","thinking":"Reasoning text"}]}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertEqual(events.count, 2)
		if case let .message(content, reasoning) = events[0] {
			XCTAssertEqual(content, "Hello")
			XCTAssertNil(reasoning)
		} else {
			XCTFail("Expected first assistant content block to map to message text")
		}
		if case let .message(content, reasoning) = events[1] {
			XCTAssertEqual(content, "")
			XCTAssertEqual(reasoning, "Reasoning text")
		} else {
			XCTFail("Expected thinking block to map to message reasoning")
		}
	}

	func testClaudeParseStreamEventsParsesAssistantToolResultBlockWithObjectContent() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"assistant","message":{"content":[{"type":"tool_result","name":"read_file","content":{"ok":true,"lines":3}}]}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertEqual(events.count, 1)
		if case let .toolResult(name, result) = events[0] {
			XCTAssertEqual(name, "read_file")
			XCTAssertTrue(result.contains("\"ok\""))
			XCTAssertTrue(result.contains("true"))
			XCTAssertTrue(result.contains("\"lines\""))
			XCTAssertTrue(result.contains("3"))
		} else {
			XCTFail("Expected assistant tool_result block to map to toolResult")
		}
	}

	func testClaudeParseStreamEventsHonorsReasoningExtractionFlagForThinkingDelta() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Need to inspect files"}}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		if ClaudeReasoningExtractionFeature.isEnabled {
			XCTAssertEqual(events.count, 1)
			if case let .message(content, reasoning) = events[0] {
				XCTAssertEqual(content, "")
				XCTAssertEqual(reasoning, "Need to inspect files")
			} else {
				XCTFail("Expected thinking_delta to map to reasoning message")
			}
		} else {
			XCTAssertTrue(events.isEmpty)
		}
	}

	func testClaudeParseStreamEventsIgnoresUnsupportedStreamEventDeltaType() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"path\":\"R"}}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertTrue(events.isEmpty)
	}

	func testClaudeParseStreamEventsIgnoresNonDeltaStreamEvents() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_123"}}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertTrue(events.isEmpty)
	}

	func testClaudeParseStreamEventsIgnoresUserToolResultEnvelope() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"ok","is_error":false}]}}"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertTrue(events.isEmpty)
	}

	func testClaudeParseStreamEventsParsesArrayPayloadWithMultipleEntries() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"[{"type":"message","content":"one"},{"type":"message","content":"two"}]"#

		let events = try provider.parseStreamEvents(Data(json.utf8))

		XCTAssertEqual(events.count, 2)
		if case let .message(content, _) = events[0] {
			XCTAssertEqual(content, "one")
		} else {
			XCTFail("Expected first array event to map to message")
		}
		if case let .message(content, _) = events[1] {
			XCTAssertEqual(content, "two")
		} else {
			XCTFail("Expected second array event to map to message")
		}
	}

	func testClaudeParseStreamEventsHandlesMalformedJSON() {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let malformed = Data("{\"type\":".utf8)

		XCTAssertThrowsError(try provider.parseStreamEvents(malformed))
	}

func testClaudeExtractCLIErrorDetailUsesLatestMessage() {
	let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
	let line1 = #"{"result":"old"}"#.data(using: .utf8)!
	let line2 = #"{"result":"new"}"#.data(using: .utf8)!
	var buffer = Data()
	buffer.append(line1)
	buffer.append(0x0A)
	buffer.append(line2)

	let message = provider.extractCLIErrorDetail(fromStdout: buffer)

	XCTAssertEqual(message, "new")
}

func testClaudeExtractCLIErrorDetailSkipsMalformedLines() {
	let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
	var buffer = Data()
	buffer.append(Data("not json".utf8))
	buffer.append(0x0A)
	buffer.append(Data(" ".utf8))
	buffer.append(0x0A)
	buffer.append(Data(#"{"error":"boom"}"#.utf8))

	let message = provider.extractCLIErrorDetail(fromStdout: buffer)

	XCTAssertEqual(message, "boom")
}

func testClaudeExtractCLIErrorDetailHandlesPlainTextDiagnostics() {
	let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
	// Regression test for 1.5.22: Plain-text diagnostics from CLI (before JSON mode) should be surfaced
	var buffer = Data()
	buffer.append(Data("Claude CLI installed at /opt/homebrew/bin/claude".utf8))
	buffer.append(0x0A)
	buffer.append(Data("Command not found: claude".utf8))

	let message = provider.extractCLIErrorDetail(fromStdout: buffer)

	// Should return the plain-text diagnostic (most recent non-JSON line)
	XCTAssertEqual(message, "Command not found: claude")
}

func testClaudeExtractCLIErrorDetailPrefersJSONOverPlainText() {
	let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
	var buffer = Data()
	buffer.append(Data("Plain text warning".utf8))
	buffer.append(0x0A)
	buffer.append(Data(#"{"error":"Structured error message"}"#.utf8))

	let message = provider.extractCLIErrorDetail(fromStdout: buffer)

	// Should prefer structured JSON error over plain text
	XCTAssertEqual(message, "Structured error message")
}

func testCodexParseJSONLEventSkipsWhitespace() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let event = provider.parseJSONLEvent(Data("   ".utf8))
	XCTAssertNil(event)
}

func testCodexParseJSONLEventParsesMessageStop() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let event = provider.parseJSONLEvent(Data(#"{"type":"done"}"#.utf8))

	XCTAssertEqual(event?.type, "message_stop")
}

func testCodexParseJSONLEventSystemFallback() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let event = provider.parseJSONLEvent(Data(#"{"message":"notice"}"#.utf8))

	XCTAssertEqual(event?.type, "system")
	XCTAssertEqual(event?.text, "notice")
}

func testCodexParseJSONLEventCommandStartedEmitsBashRunningResult() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let line = """
	{"type":"item.started","item":{"id":"item_71","type":"command_execution","command":"npm start","status":"in_progress","process_id":"56616"}}
	"""

	let event = provider.parseJSONLEvent(Data(line.utf8))

	XCTAssertEqual(event?.type, "tool_result")
	XCTAssertEqual(event?.toolName, "bash")
	XCTAssertEqual(event?.toolIsError, false)
	XCTAssertTrue(event?.toolResultJSON?.contains(#""status" : "in_progress""#) == true)
}

func testCodexParseJSONLEventCommandCompletedWithoutExitCodeEmitsNonErrorResult() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let line = """
	{"type":"item.completed","item":{"id":"item_71","type":"command_execution","command":"npm start","status":"completed","process_id":"56616","aggregated_output":"ready"}}
	"""

	let event = provider.parseJSONLEvent(Data(line.utf8))

	XCTAssertEqual(event?.type, "tool_result")
	XCTAssertEqual(event?.toolName, "bash")
	XCTAssertEqual(event?.toolIsError, false)
	XCTAssertNotNil(event?.toolInvocationID)
	XCTAssertTrue(event?.toolResultJSON?.contains(#""aggregated_output" : "ready""#) == true)
}

func testCodexParseJSONLEventFiltersRepoPromptMCPTools() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let server = MCPIntegrationHelper.repoPromptMCPServerName
	let line = """
	{"type":"item.completed","item":{"id":"call_1","type":"function_call","name":"mcp__\(server)__read_file","arguments":{"path":"README.md"},"status":"completed"}}
	"""

	let event = provider.parseJSONLEvent(Data(line.utf8))

	XCTAssertNil(event)
}

func testCodexParseJSONLEventHandlesMalformedJSON() {
	let provider = CodexExecAgentProvider(runner: mockRunner(), config: CodexExecAgentConfig())
	let event = provider.parseJSONLEvent(Data("{\"type\":".utf8))
	XCTAssertNil(event)
}

	func testClaudeParseResultEventWithSessionID() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"result","result":"Hello world","session_id":"abc-123-def","usage":{"input_tokens":100,"output_tokens":50},"total_cost_usd":0.01}"#
		
		let events = try provider.parseStreamEvents(Data(json.utf8))
		
		// Should emit both finalMessage and completion events
		XCTAssertEqual(events.count, 2)
		
		// First event should be finalMessage
		if case let .finalMessage(content) = events[0] {
			XCTAssertEqual(content, "Hello world")
		} else {
			XCTFail("Expected finalMessage event, got \(events[0])")
		}
		
		// Second event should be completion with session ID
		if case let .completion(usage, cost, sessionID) = events[1] {
			XCTAssertEqual(usage?.inputTokens, 100)
			XCTAssertEqual(usage?.outputTokens, 50)
			XCTAssertEqual(cost, 0.01)
			XCTAssertEqual(sessionID, "abc-123-def")
		} else {
			XCTFail("Expected completion event, got \(events[1])")
		}
	}
	
	func testClaudeParseResultEventWithCamelCaseSessionId() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		// Test camelCase sessionId variant
		let json = #"{"type":"result","sessionId":"xyz-456","usage":{"input_tokens":10,"output_tokens":5}}"#
		
		let events = try provider.parseStreamEvents(Data(json.utf8))
		
		// Should emit just completion (no result text)
		XCTAssertEqual(events.count, 1)
		
		if case let .completion(_, _, sessionID) = events[0] {
			XCTAssertEqual(sessionID, "xyz-456")
		} else {
			XCTFail("Expected completion event")
		}
	}
	
	func testClaudeParseResultEventWithoutSessionID() throws {
		let provider = ClaudeCodeAgentProvider(runner: mockRunner(), config: ClaudeCodeAgentConfig.agentMode())
		let json = #"{"type":"result","result":"Done","usage":{"input_tokens":5,"output_tokens":2}}"#
		
		let events = try provider.parseStreamEvents(Data(json.utf8))
		
		XCTAssertEqual(events.count, 2)
		
		// Completion should have nil session ID
		if case let .completion(_, _, sessionID) = events[1] {
			XCTAssertNil(sessionID)
		} else {
			XCTFail("Expected completion event")
		}
	}

	func testGeminiParseInitEventCapturesSessionIDForCompletion() throws {
		let provider = GeminiAgentProvider(runner: mockRunner(), config: GeminiAgentConfig())
		let initJSON = #"{"type":"init","session_id":"gem-session-123"}"#
		let resultJSON = #"{"type":"result","status":"success","stats":{"input_tokens":12,"output_tokens":7}}"#

		_ = try provider.test_parseStreamEvents(Data(initJSON.utf8))
		let events = try provider.test_parseStreamEvents(Data(resultJSON.utf8))

		XCTAssertEqual(events.count, 1)
		if case let .completion(usage, _, sessionID) = events[0] {
			XCTAssertEqual(usage?.inputTokens, 12)
			XCTAssertEqual(usage?.outputTokens, 7)
			XCTAssertEqual(sessionID, "gem-session-123")
		} else {
			XCTFail("Expected completion event")
		}
	}

	func testGeminiBuildArgumentsIncludesResumeFlag() {
		let provider = GeminiAgentProvider(runner: mockRunner(), config: GeminiAgentConfig())

		let args = provider.test_buildArguments(resumeSessionID: "gem-session-123")

		let resumeIndex = args.firstIndex(of: "--resume")
		XCTAssertNotNil(resumeIndex)
		if let resumeIndex {
			XCTAssertTrue(args.indices.contains(resumeIndex + 1))
			XCTAssertEqual(args[resumeIndex + 1], "gem-session-123")
		}
	}

	func testGeminiEscapeSpecialCharactersPreservesAtFileReferences() {
		let provider = GeminiAgentProvider(runner: mockRunner(), config: GeminiAgentConfig())
		let input = "@/tmp/image.png @./local.png @../up.png @C:/Windows/file.png"

		let escaped = provider.test_escapeSpecialCharacters(input)

		XCTAssertEqual(escaped, input)
	}

	func testGeminiEscapeSpecialCharactersEscapesNonReferenceAtCharacters() {
		let provider = GeminiAgentProvider(runner: mockRunner(), config: GeminiAgentConfig())
		let input = "Email me at a@b.com and mention @teammate."

		let escaped = provider.test_escapeSpecialCharacters(input)

		XCTAssertEqual(escaped, "Email me at a[at]b.com and mention [at]teammate.")
	}

	func testGeminiACPLaunchConfigurationUsesACPAndNoMCPSettingsInjection() throws {
		let provider = GeminiACPAgentProvider(config: GeminiAgentConfig(modelString: "gemini-2.5-pro"))
		let request = ACPRunRequest(
			agentKind: .gemini,
			modelString: "gemini-2.5-pro",
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		let launch = try provider.makeLaunchConfiguration(for: request)

		XCTAssertEqual(launch.providerID, .gemini)
		XCTAssertEqual(Array(launch.arguments.prefix(4)), ["--acp", "--skip-trust", "--allowed-mcp-server-names", "RepoPrompt"])
		XCTAssertTrue(launch.arguments.contains("--model"))
		XCTAssertTrue(launch.arguments.contains("gemini-2.5-pro"))
		XCTAssertEqual(launch.workingDirectory, "/tmp/workspace")
		XCTAssertEqual(launch.additionalPathHints, CLIPathHints.nativeDefaultsSupplemented(with: CLIPathHints.gemini))

		XCTAssertEqual(Set(launch.environment.keys), [MCPIntegrationHelper.geminiSystemSettingsEnvKey])
		let settingsPath = try XCTUnwrap(launch.environment[MCPIntegrationHelper.geminiSystemSettingsEnvKey])
		let settingsData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
		let settingsJSON = try XCTUnwrap(
			JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
		)

		XCTAssertNil(settingsJSON["mcpServers"], "ACP launch should not inject RepoPrompt MCP through Gemini settings.")
	}

	func testGeminiACPLaunchConfigurationOmitsModelWhenResumingSession() throws {
		let provider = GeminiACPAgentProvider(config: GeminiAgentConfig(modelString: "gemini-2.5-pro"))
		let request = ACPRunRequest(
			agentKind: .gemini,
			modelString: "gemini-2.5-flash",
			workspacePath: "/tmp/workspace",
			resumeSessionID: "session-123",
			attachments: [],
			taskLabelKind: nil
		)

		let launch = try provider.makeLaunchConfiguration(for: request)

		XCTAssertEqual(launch.providerID, .gemini)
		XCTAssertTrue(launch.arguments.contains("--acp"))
		XCTAssertTrue(launch.arguments.contains("--skip-trust"))
		XCTAssertFalse(launch.arguments.contains("--model"))
		XCTAssertFalse(launch.arguments.contains("gemini-2.5-flash"))
		XCTAssertFalse(launch.arguments.contains("gemini-2.5-pro"))
	}

	func testGeminiACPSessionConfigurationUsesLoadModeForResume() throws {
		let provider = GeminiACPAgentProvider(config: GeminiAgentConfig())
		let request = ACPRunRequest(
			agentKind: .gemini,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: "session-123",
			attachments: [],
			taskLabelKind: nil
		)
		let mcpServer = RepoPromptMCPServerConfiguration(
			name: "RepoPrompt",
			command: "/usr/local/bin/rp",
			args: ["serve"]
		)

		let session = try provider.makeSessionConfiguration(for: request, mcpServer: mcpServer)

		if case .load(let existingSessionID) = session.mode {
			XCTAssertEqual(existingSessionID, "session-123")
		} else {
			XCTFail("Expected load session mode")
		}
		XCTAssertEqual(session.workingDirectory, "/tmp/workspace")
		XCTAssertEqual(session.mcpServers, [mcpServer])
	}

	func testGeminiACPBuildPromptBlocksOmitsSystemPromptOnFollowUp() throws {
		let provider = GeminiACPAgentProvider(config: GeminiAgentConfig())
		let freshRequest = ACPRunRequest(
			agentKind: .gemini,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)
		let followUpRequest = ACPRunRequest(
			agentKind: .gemini,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: "session-123",
			attachments: [],
			taskLabelKind: nil
		)
		let message = AgentMessage(systemPrompt: "System prompt", userMessage: "User message", resumeSessionID: "session-123")

		let freshBlocks = try provider.buildPromptBlocks(for: message, request: freshRequest)
		let followUpBlocks = try provider.buildPromptBlocks(for: message, request: followUpRequest)

		XCTAssertEqual(freshBlocks.first?["text"] as? String, "System prompt\n\nUser message")
		XCTAssertEqual(followUpBlocks.first?["text"] as? String, "User message")
	}

	func testGeminiACPBuildPromptBlocksEmbedsLocalImageAttachments() throws {
		let provider = GeminiACPAgentProvider(config: GeminiAgentConfig())
		let imageURL = try makeTemporaryImage(named: "screenshot.png", bytes: [0x89, 0x50, 0x4E, 0x47])
		let attachment = AgentImageAttachment(source: .localFile(path: imageURL.path), title: "screenshot.png")
		let request = ACPRunRequest(
			agentKind: .gemini,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [attachment],
			taskLabelKind: nil
		)

		let blocks = try provider.buildPromptBlocks(
			for: AgentMessage(systemPrompt: "System prompt", userMessage: "Describe this", resumeSessionID: nil),
			request: request
		)

		XCTAssertEqual(blocks.count, 2)
		XCTAssertEqual(blocks[0]["type"] as? String, "text")
		XCTAssertEqual(blocks[0]["text"] as? String, "System prompt\n\nDescribe this")
		XCTAssertEqual(blocks[1]["type"] as? String, "image")
		XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/png")
		XCTAssertEqual(blocks[1]["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
		XCTAssertEqual(blocks[1]["uri"] as? String, imageURL.absoluteString)
	}

	func testGeminiACPUpdateNormalizationMapsContentReasoningAndToolLifecycle() {
		let provider = GeminiACPAgentProvider(config: GeminiAgentConfig())

		let contentEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "agent_message_chunk",
				"content": [
					"type": "text",
					"text": "hello"
				]
			],
			sessionID: "session-1"
		)
		let reasoningEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "agent_thought_chunk",
				"content": [
					"type": "text",
					"text": "thinking"
				]
			],
			sessionID: "session-1"
		)
		let toolCallEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "tool-1",
				"title": "read_file",
				"rawInput": ["path": "README.md"]
			],
			sessionID: "session-1"
		)
		let repoPromptToolCallEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "tool-2",
				"title": "workspace_context (RepoPrompt MCP Server)",
				"kind": "other",
				"rawInput": ["op": "get"]
			],
			sessionID: "session-1"
		)
		let toolProgressEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-1",
				"title": "Reading file",
				"status": "in_progress"
			],
			sessionID: "session-1"
		)
		let toolResultEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-1",
				"title": "read_file",
				"status": "completed",
				"rawInput": ["path": "README.md"],
				"rawOutput": ["contents": "Hello"]
			],
			sessionID: "session-1"
		)

		guard
			case .stream(let contentResult) = contentEvents.first,
			case .stream(let reasoningResult) = reasoningEvents.first,
			case .stream(let toolCallResult) = toolCallEvents.first,
			case .stream(let repoPromptToolCallResult) = repoPromptToolCallEvents.first,
			case .stream(let toolProgressResult) = toolProgressEvents.first,
			case .stream(let toolResult) = toolResultEvents.first
		else {
			return XCTFail("Expected normalized stream events")
		}

		XCTAssertEqual(contentResult.type, "content")
		XCTAssertEqual(contentResult.text, "hello")

		XCTAssertEqual(reasoningResult.type, "reasoning")
		XCTAssertEqual(reasoningResult.reasoning, "thinking")

		XCTAssertEqual(toolCallResult.type, "tool_call")
		XCTAssertEqual(toolCallResult.toolName, "read_file")
		XCTAssertEqual(toolCallResult.toolInvocationID, toolProgressResult.toolInvocationID)
		XCTAssertEqual(repoPromptToolCallResult.toolName, "mcp__RepoPrompt__workspace_context")
		XCTAssertEqual(toolCallResult.toolInvocationID, toolResult.toolInvocationID)
		XCTAssertTrue(toolCallResult.toolArgsJSON?.contains("README.md") == true)

		XCTAssertEqual(toolProgressResult.type, "tool_result")
		XCTAssertEqual(toolProgressResult.toolName, "Reading file")
		XCTAssertEqual(toolProgressResult.toolIsError, false)
		XCTAssertTrue(toolProgressResult.toolResultJSON?.contains("running") == true)
		XCTAssertTrue(toolProgressResult.toolResultJSON?.contains("Reading file") == true)

		XCTAssertEqual(toolResult.type, "tool_result")
		XCTAssertEqual(toolResult.toolName, "read_file")
		XCTAssertEqual(toolResult.toolIsError, false)
		XCTAssertTrue(toolResult.toolResultJSON?.contains("Hello") == true)
	}

	func testOpenCodeACPLaunchConfigurationUsesManagedConfigToggleAndACPSubcommand() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				commandName: "opencode-test",
				additionalPathHints: ["/opt/opencode/bin"],
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil,
			sessionModeID: OpenCodeAgentConfig.managedSessionModeID
		)

		let launch = try provider.makeLaunchConfiguration(for: request)

		XCTAssertEqual(launch.providerID, .openCode)
		XCTAssertEqual(launch.command, "opencode-test")
		XCTAssertEqual(launch.arguments, ["acp"])
		XCTAssertEqual(launch.environment, [:])
		XCTAssertEqual(launch.workingDirectory, "/tmp/workspace")
		XCTAssertEqual(launch.additionalPathHints, CLIPathHints.nativeDefaultsSupplemented(with: ["/opt/opencode/bin"]))
	}

	func testOpenCodeACPLaunchConfigurationInjectsEphemeralConfigContentWithActiveMCP() throws {
		let executableURL = try makeTemporaryExecutable(named: "repoprompt_cli")
		let mcpConfiguration = RepoPromptMCPServerConfiguration(
			command: executableURL.path,
			args: ["serve"]
		)
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeRepoPromptMCPServer: true,
				includeManagedConfigOverlay: true,
				cleanupLegacyPersistentConfig: false,
				toolProfile: .agentMode
			),
			repoPromptMCPConfiguration: mcpConfiguration
		)
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil,
			sessionModeID: OpenCodeAgentConfig.managedSessionModeID
		)

		let launch = try provider.makeLaunchConfiguration(for: request)
		let root = try parsedOpenCodeConfigContent(from: launch)
		let agents = try XCTUnwrap(root["agent"] as? [String: Any])
		let servers = try XCTUnwrap(root["mcp"] as? [String: Any])
		let repoPromptServer = try XCTUnwrap(servers[MCPIntegrationHelper.repoPromptMCPServerName] as? [String: Any])
		let command = try XCTUnwrap(repoPromptServer["command"] as? [String])

		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedFullAccessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedHeadlessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedNoToolsSessionModeID])
		XCTAssertEqual(command, [executableURL.path, "serve"])
		XCTAssertFalse(repoPromptServer["enabled"] as? Bool == false)
	}

	func testOpenCodeACPLaunchConfigurationInjectsDisabledRepoPromptMCPOverlayWhenExcluded() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeRepoPromptMCPServer: false,
				includeManagedConfigOverlay: true,
				cleanupLegacyPersistentConfig: false,
				toolProfile: .noTools
			)
		)
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil,
			sessionModeID: OpenCodeAgentConfig.managedNoToolsSessionModeID
		)

		let launch = try provider.makeLaunchConfiguration(for: request)
		let root = try parsedOpenCodeConfigContent(from: launch)
		let agents = try XCTUnwrap(root["agent"] as? [String: Any])
		let servers = try XCTUnwrap(root["mcp"] as? [String: Any])
		let repoPromptServer = try XCTUnwrap(servers[MCPIntegrationHelper.repoPromptMCPServerName] as? [String: Any])

		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedFullAccessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedHeadlessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedNoToolsSessionModeID])
		XCTAssertEqual(repoPromptServer["enabled"] as? Bool, false)
		XCTAssertEqual(repoPromptServer["command"] as? [String], ["/usr/bin/false"])
	}

	func testOpenCodeAgentConfigDefaultsToHeadlessProfile() {
		let config = OpenCodeAgentConfig()

		XCTAssertEqual(config.toolProfile, .headless)
		XCTAssertEqual(config.sessionModeID, OpenCodeAgentConfig.managedHeadlessSessionModeID)
		XCTAssertTrue(config.includeManagedConfigOverlay)
		XCTAssertTrue(config.cleanupLegacyPersistentConfig)
	}

	func testOpenCodeACPProviderFactoryUsesAgentModeToolProfile() throws {
		let provider = try XCTUnwrap(
			ACPAgentProviderFactory.makeProvider(for: .openCode, modelString: "opencode/model") as? OpenCodeACPAgentProvider
		)

		XCTAssertEqual(provider.test_config.toolProfile, .agentMode)
		XCTAssertEqual(provider.test_config.sessionModeID, OpenCodeAgentConfig.managedSessionModeID)
	}

	func testOpenCodeCLIActiveProviderStoreKeepsReplacedProviderTrackedUntilCleanup() throws {
		let store = ActiveOpenCodeCLIProviderStore<OpenCodeCLIActiveProviderStoreTestProvider>()
		let providerA = OpenCodeCLIActiveProviderStoreTestProvider()
		let providerB = OpenCodeCLIActiveProviderStoreTestProvider()

		XCTAssertNil(store.replace(providerA))
		let replacedProvider = try XCTUnwrap(store.replace(providerB))
		XCTAssertTrue(replacedProvider === providerA)
		XCTAssertTrue(store.contains(providerA))
		XCTAssertTrue(store.contains(providerB))

		XCTAssertTrue(store.remove(providerA))
		XCTAssertFalse(store.contains(providerA))
		XCTAssertFalse(store.remove(providerA))

		let remainingProviders = store.removeAll()
		XCTAssertEqual(remainingProviders.count, 1)
		XCTAssertTrue(remainingProviders.first === providerB)
		XCTAssertTrue(store.removeAll().isEmpty)
	}

	func testOpenCodeCLIHeadlessConfigUsesNoToolsAndNoMCP() throws {
		let config = OpenCodeCLIProvider.test_makeHeadlessConfig(modelName: "opencode/model")

		XCTAssertEqual(config.modelString, "opencode/model")
		XCTAssertEqual(config.toolProfile, .noTools)
		XCTAssertEqual(config.sessionModeID, OpenCodeAgentConfig.managedNoToolsSessionModeID)
		XCTAssertFalse(config.includeRepoPromptMCPServer)
		XCTAssertTrue(config.includeManagedConfigOverlay)
		XCTAssertTrue(config.cleanupLegacyPersistentConfig)

		let provider = OpenCodeACPAgentProvider(config: config)
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: config.modelString,
			workspacePath: nil,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil,
			sessionModeID: config.sessionModeID
		)
		let mcpServer = RepoPromptMCPServerConfiguration(
			name: "RepoPrompt",
			command: "/usr/local/bin/rp",
			args: ["serve"]
		)
		let session = try provider.makeSessionConfiguration(for: request, mcpServer: mcpServer)
		XCTAssertEqual(session.mcpServers, [])
	}

	func testOpenCodeHeadlessProviderRequestsConfiguredHeadlessSessionMode() async throws {
		let capturingProvider = OpenCodeCapturingACPProvider(
			supportResult: .unsupported(reason: "stop before launch")
		)
		let provider = OpenCodeACPHeadlessAgentProvider(
			config: OpenCodeAgentConfig(
				modelString: "opencode/model",
				includeRepoPromptMCPServer: true,
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false,
				toolProfile: .headless
			),
			providerFactory: { _ in capturingProvider }
		)

		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "hello", resumeSessionID: nil),
			runID: UUID()
		)
		do {
			for try await _ in stream {}
			XCTFail("Expected unsupported fake provider to end the stream with an error")
		} catch {
			// Expected: this test only needs to inspect the ACP run request built by the provider.
		}

		let capturedRequest = try XCTUnwrap(capturingProvider.capturedRequests.last)
		XCTAssertEqual(capturedRequest.sessionModeID, OpenCodeAgentConfig.managedHeadlessSessionModeID)
		XCTAssertEqual(provider.test_config.sessionModeID, OpenCodeAgentConfig.managedHeadlessSessionModeID)
	}

	func testOpenCodeACPBuildPromptBlocksIncludesURLImageAttachments() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [AgentImageAttachment(source: .url("https://example.com/screenshot.jpg"), title: "screenshot.jpg")],
			taskLabelKind: nil,
			sessionModeID: OpenCodeAgentConfig.managedSessionModeID
		)

		let blocks = try provider.buildPromptBlocks(
			for: AgentMessage(systemPrompt: "System prompt", userMessage: "Describe this", resumeSessionID: nil),
			request: request
		)

		XCTAssertEqual(blocks.count, 2)
		XCTAssertEqual(blocks[0]["type"] as? String, "text")
		XCTAssertEqual(blocks[0]["text"] as? String, "System prompt\n\nDescribe this")
		XCTAssertEqual(blocks[1]["type"] as? String, "image")
		XCTAssertEqual(blocks[1]["uri"] as? String, "https://example.com/screenshot.jpg")
		XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/jpeg")
		XCTAssertNil(blocks[1]["data"])
	}

	func testOpenCodeACPBuildPromptBlocksEmbedsLocalImageAttachments() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)
		let imageURL = try makeTemporaryImage(named: "diagram.gif", bytes: [0x47, 0x49, 0x46])
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [AgentImageAttachment(source: .localFile(path: imageURL.path), title: "diagram.gif")],
			taskLabelKind: nil,
			sessionModeID: OpenCodeAgentConfig.managedSessionModeID
		)

		let blocks = try provider.buildPromptBlocks(
			for: AgentMessage(systemPrompt: "", userMessage: "Describe this", resumeSessionID: nil),
			request: request
		)

		XCTAssertEqual(blocks.count, 2)
		XCTAssertEqual(blocks[0]["text"] as? String, "Describe this")
		XCTAssertEqual(blocks[1]["type"] as? String, "image")
		XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/gif")
		XCTAssertEqual(blocks[1]["data"] as? String, Data([0x47, 0x49, 0x46]).base64EncodedString())
		XCTAssertEqual(blocks[1]["uri"] as? String, imageURL.absoluteString)
	}

	func testOpenCodeACPSessionConfigurationDoesNotUseACPLevelMCPInjection() throws {
		let request = ACPRunRequest(
			agentKind: .openCode,
			modelString: nil,
			workspacePath: "/tmp/workspace",
			resumeSessionID: "session-123",
			attachments: [],
			taskLabelKind: nil,
			sessionModeID: OpenCodeAgentConfig.managedSessionModeID
		)
		let mcpServer = RepoPromptMCPServerConfiguration(
			name: "RepoPrompt",
			command: "/usr/local/bin/rp",
			args: ["serve"]
		)
		let injectingProvider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeRepoPromptMCPServer: true,
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)
		let isolatedProvider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeRepoPromptMCPServer: false,
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let injected = try injectingProvider.makeSessionConfiguration(for: request, mcpServer: mcpServer)
		let isolated = try isolatedProvider.makeSessionConfiguration(for: request, mcpServer: mcpServer)

		if case .load(let existingSessionID) = injected.mode {
			XCTAssertEqual(existingSessionID, "session-123")
		} else {
			XCTFail("Expected load session mode")
		}
		XCTAssertEqual(injected.workingDirectory, "/tmp/workspace")
		XCTAssertEqual(injected.mcpServers, [])
		XCTAssertEqual(isolated.mcpServers, [])
	}

	func testOpenCodeACPUpdateNormalizationMapsToolLifecycleAndUsage() {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let contentEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "agent_message_chunk",
				"messageId": "assistant-message-1",
				"content": ["type": "text", "text": "hello"]
			],
			sessionID: "session-1"
		)
		let toolCallEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "tool-1",
				"title": "workspace_context (RepoPrompt MCP Server)",
				"rawInput": ["include": ["prompt"]]
			],
			sessionID: "session-1"
		)
		let toolRunningEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-1",
				"title": "workspace_context (RepoPrompt MCP Server)",
				"status": "in_progress",
				"rawInput": ["include": ["prompt"]],
				"content": [
					[
						"type": "content",
						"content": ["type": "text", "text": "loading"]
					]
				]
			],
			sessionID: "session-1"
		)
		let toolResultEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-1",
				"title": "workspace_context (RepoPrompt MCP Server)",
				"status": "completed",
				"rawInput": ["include": ["prompt"]],
				"rawOutput": ["output": "done", "metadata": ["ok": true]]
			],
			sessionID: "session-1"
		)
		let usageEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "usage_update",
				"used": 123,
				"size": 2000,
				"cost": ["amount": 0.42, "currency": "USD"]
			],
			sessionID: "session-1"
		)

		guard
			case .stream(let contentResult) = contentEvents.first,
			case .stream(let toolCallResult) = toolCallEvents.first,
			case .stream(let toolRunningResult) = toolRunningEvents.first,
			case .stream(let toolResult) = toolResultEvents.first,
			case .stream(let usageResult) = usageEvents.first
		else {
			return XCTFail("Expected normalized stream events")
		}

		XCTAssertEqual(contentResult.type, "content")
		XCTAssertEqual(contentResult.text, "hello")
		XCTAssertEqual(contentResult.contentMessageID, "assistant-message-1")
		XCTAssertEqual(toolCallResult.type, "tool_call")
		XCTAssertEqual(toolCallResult.toolName, "mcp__RepoPrompt__workspace_context")
		XCTAssertEqual(toolCallResult.toolInvocationID, toolRunningResult.toolInvocationID)
		XCTAssertEqual(toolCallResult.toolInvocationID, toolResult.toolInvocationID)
		XCTAssertTrue(toolCallResult.toolArgsJSON?.contains("prompt") == true)
		XCTAssertEqual(toolRunningResult.type, "tool_result")
		XCTAssertEqual(toolRunningResult.toolName, "mcp__RepoPrompt__workspace_context")
		XCTAssertEqual(toolRunningResult.toolIsError, false)
		XCTAssertTrue(toolRunningResult.toolResultJSON?.contains("running") == true)
		XCTAssertTrue(toolRunningResult.toolResultJSON?.contains("loading") == true)
		XCTAssertEqual(toolResult.type, "tool_result")
		XCTAssertEqual(toolResult.toolName, "mcp__RepoPrompt__workspace_context")
		XCTAssertEqual(toolResult.toolIsError, false)
		XCTAssertTrue(toolResult.toolResultJSON?.contains("done") == true)
		XCTAssertEqual(usageResult.type, "usage")
		XCTAssertEqual(usageResult.contextUsedTokens, 123)
		XCTAssertEqual(usageResult.modelContextWindow, 2000)
		XCTAssertEqual(usageResult.cost, 0.42)
	}

	func testOpenCodeACPHeadlessSuppressesNativeNonTerminalToolUpdates() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let statuses = ["in_progress", "running", "pending"]
		for status in statuses {
			let events = provider.normalizeSessionUpdate(
				[
					"sessionUpdate": "tool_call_update",
					"toolCallId": "tool-\(status)",
					"status": status,
					"rawInput": ["command": "sleep 30"]
				],
				sessionID: "session-1"
			)

			XCTAssertTrue(events.isEmpty, "Expected headless OpenCode to suppress native \(status) updates")
		}
	}

	func testOpenCodeACPAgentModeKeepsNativeNonTerminalToolUpdatesAsDurableResults() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false,
				toolProfile: .agentMode
			)
		)

		let cases: [(rawStatus: String, expectedStatus: String)] = [
			("in_progress", "running"),
			("running", "running"),
			("pending", "pending")
		]
		for testCase in cases {
			let events = provider.normalizeSessionUpdate(
				[
					"sessionUpdate": "tool_call_update",
					"toolCallId": "tool-\(testCase.rawStatus)",
					"status": testCase.rawStatus,
					"kind": "execute",
					"rawInput": ["command": "sleep 30"]
				],
				sessionID: "session-1"
			)
			guard case .stream(let result) = events.first else {
				return XCTFail("Expected durable tool_result for \(testCase.rawStatus)")
			}
			let payload = try parsedToolResultJSON(from: result)
			let rawInput = try XCTUnwrap(payload["rawInput"] as? [String: Any])

			XCTAssertEqual(events.count, 1)
			XCTAssertEqual(result.type, "tool_result")
			XCTAssertEqual(result.toolName, "bash")
			XCTAssertNotNil(result.toolInvocationID)
			XCTAssertEqual(result.toolIsError, false)
			XCTAssertTrue(result.toolArgsJSON?.contains("sleep 30") == true)
			XCTAssertEqual(payload["status"] as? String, testCase.expectedStatus)
			XCTAssertEqual(payload["title"] as? String, "bash")
			XCTAssertEqual(rawInput["command"] as? String, "sleep 30")
		}
	}

	func testOpenCodeACPHeadlessSuppressesNativeRunningToolUpdateWithTitleAndNoContent() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let events = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-title-only",
				"title": "Bash",
				"status": "running",
				"rawInput": ["command": "npm test"]
			],
			sessionID: "session-1"
		)

		XCTAssertTrue(events.isEmpty)
	}

	func testOpenCodeACPAgentModeCanonicalizesNativeRunningToolUpdateWithTitleAndNoContent() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false,
				toolProfile: .agentMode
			)
		)

		let events = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-title-only",
				"title": "Bash",
				"status": "running",
				"rawInput": ["command": "npm test"]
			],
			sessionID: "session-1"
		)
		guard case .stream(let result) = events.first else {
			return XCTFail("Expected durable title-only running tool_result")
		}
		let payload = try parsedToolResultJSON(from: result)
		let rawInput = try XCTUnwrap(payload["rawInput"] as? [String: Any])

		XCTAssertEqual(events.count, 1)
		XCTAssertEqual(result.type, "tool_result")
		XCTAssertEqual(result.toolName, "bash")
		XCTAssertEqual(result.toolIsError, false)
		XCTAssertTrue(result.toolArgsJSON?.contains("npm test") == true)
		XCTAssertEqual(payload["status"] as? String, "running")
		XCTAssertEqual(payload["title"] as? String, "bash")
		XCTAssertNil(payload["progress"])
		XCTAssertEqual(rawInput["command"] as? String, "npm test")
	}

	func testOpenCodeACPHeadlessSuppressesNativeToolCallsButKeepsRepoPromptMCP() {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let nativeEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "native-read",
				"title": "RepoPrompt/Services/AI/Providers/OpenCode/OpenCodeACPAgentProvider.swift",
				"kind": "read",
				"rawInput": ["filePath": "RepoPrompt/Services/AI/Providers/OpenCode/OpenCodeACPAgentProvider.swift"]
			],
			sessionID: "session-1"
		)
		let repoPromptEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "repo-tool",
				"title": "get_file_tree (RepoPrompt MCP Server)",
				"kind": "other",
				"rawInput": ["type": "roots"]
			],
			sessionID: "session-1"
		)

		XCTAssertTrue(nativeEvents.isEmpty)
		guard case .stream(let repoPromptResult) = repoPromptEvents.first else {
			return XCTFail("Expected RepoPrompt MCP tool_call to be preserved")
		}
		XCTAssertEqual(repoPromptEvents.count, 1)
		XCTAssertEqual(repoPromptResult.type, "tool_call")
		XCTAssertEqual(repoPromptResult.toolName, "mcp__RepoPrompt__get_file_tree")
		XCTAssertTrue(repoPromptResult.toolArgsJSON?.contains("roots") == true)
	}

	func testOpenCodeACPAgentModeCanonicalizesNativeToolCallNames() {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false,
				toolProfile: .agentMode
			)
		)

		let events = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "native-bash",
				"title": "Run npm test",
				"kind": "execute",
				"rawInput": ["command": "npm test"]
			],
			sessionID: "session-1"
		)

		guard case .stream(let result) = events.first else {
			return XCTFail("Expected native agent-mode tool_call")
		}
		XCTAssertEqual(events.count, 1)
		XCTAssertEqual(result.type, "tool_call")
		XCTAssertEqual(result.toolName, "bash")
		XCTAssertTrue(result.toolArgsJSON?.contains("npm test") == true)
	}

	func testOpenCodeACPHeadlessKeepsRepoPromptLabeledRunningToolUpdates() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let events = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "repo-running",
				"title": "Running RepoPrompt tool",
				"status": "running",
				"content": ["type": "text", "text": "loading"]
			],
			sessionID: "session-1"
		)

		guard case .stream(let result) = events.first else {
			return XCTFail("Expected RepoPrompt-labeled running update to be preserved")
		}
		let payload = try parsedToolResultJSON(from: result)
		XCTAssertEqual(events.count, 1)
		XCTAssertEqual(result.type, "tool_result")
		XCTAssertEqual(result.toolName, "Running RepoPrompt tool")
		XCTAssertEqual(payload["status"] as? String, "running")
		XCTAssertTrue(result.toolResultJSON?.contains("loading") == true)
	}

	func testOpenCodeACPSuppressesNoisySessionInfoTitles() {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let pathEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "session_info_update",
				"title": "RepoPrompt/Services/AI/Providers/OpenCode/OpenCodeACPAgentProvider.swift"
			],
			sessionID: "session-1"
		)
		let codeEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "session_info_update",
				"title": "let result = try await runner.run()"
			],
			sessionID: "session-1"
		)
		let resourcePathEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "session_info_update",
				"title": "Opened file README.md"
			],
			sessionID: "session-1"
		)
		let statusEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "session_info_update",
				"title": "Preparing context"
			],
			sessionID: "session-1"
		)

		XCTAssertTrue(pathEvents.isEmpty)
		XCTAssertTrue(codeEvents.isEmpty)
		XCTAssertTrue(resourcePathEvents.isEmpty)
		guard case .stream(let statusResult) = statusEvents.first else {
			return XCTFail("Expected concise status update to be preserved")
		}
		XCTAssertEqual(statusEvents.count, 1)
		XCTAssertEqual(statusResult.type, "status")
		XCTAssertEqual(statusResult.text, "Preparing context")
	}

	func testOpenCodeACPHeadlessKeepsMeaningfulNativeTerminalFailures() throws {
		let provider = OpenCodeACPAgentProvider(
			config: OpenCodeAgentConfig(
				includeManagedConfigOverlay: false,
				cleanupLegacyPersistentConfig: false
			)
		)

		let events = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "native-failure",
				"title": "Run npm test",
				"kind": "execute",
				"status": "error",
				"rawInput": ["command": "npm test"],
				"rawOutput": ["exitCode": 1, "stderr": "permission denied"]
			],
			sessionID: "session-1"
		)

		guard case .stream(let result) = events.first else {
			return XCTFail("Expected meaningful terminal failure to be preserved")
		}
		XCTAssertEqual(events.count, 1)
		XCTAssertEqual(result.type, "tool_result")
		XCTAssertEqual(result.toolName, "bash")
		XCTAssertEqual(result.toolIsError, true)
		XCTAssertTrue(result.toolArgsJSON?.contains("npm test") == true)
		XCTAssertTrue(result.toolResultJSON?.contains("permission denied") == true)

		let cancelledEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "native-cancelled",
				"title": "Run npm test",
				"kind": "execute",
				"status": "cancelled",
				"rawInput": ["command": "npm test"],
				"rawOutput": ["status": "cancelled", "error": "user cancelled"]
			],
			sessionID: "session-1"
		)
		guard case .stream(let cancelledResult) = cancelledEvents.first else {
			return XCTFail("Expected meaningful cancelled update to be preserved")
		}
		XCTAssertEqual(cancelledEvents.count, 1)
		XCTAssertEqual(cancelledResult.type, "tool_result")
		XCTAssertEqual(cancelledResult.toolName, "bash")
		XCTAssertEqual(cancelledResult.toolIsError, true)
		XCTAssertTrue(cancelledResult.toolResultJSON?.contains("user cancelled") == true)
	}

	func testCodexAppendTailZeroLimitDropsData() {
		var tail = Data()
		appendTail(&tail, chunk: Data("data".utf8), limit: 0)
		XCTAssertTrue(tail.isEmpty)
	}

	func testClaudeAppendTailRespectLimit() {
		var tail = Data()
		appendTail(&tail, chunk: Data(repeating: 0x41, count: 10), limit: 5)
		XCTAssertEqual(tail, Data(repeating: 0x41, count: 5))
	}

	// MARK: - Helpers

	private func parsedOpenCodeConfigContent(from launch: ACPLaunchConfiguration) throws -> [String: Any] {
		let json = try XCTUnwrap(launch.environment["OPENCODE_CONFIG_CONTENT"])
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	private func parsedToolResultJSON(from result: AIStreamResult) throws -> [String: Any] {
		let json = try XCTUnwrap(result.toolResultJSON)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	private func makeTemporaryExecutable(named name: String) throws -> URL {
		let fm = FileManager.default
		let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: directory, withIntermediateDirectories: true)
		let executableURL = directory.appendingPathComponent(name)
		try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
		addTeardownBlock {
			try? fm.removeItem(at: directory)
		}
		return executableURL
	}

	private func makeTemporaryImage(named name: String, bytes: [UInt8]) throws -> URL {
		let fm = FileManager.default
		let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: directory, withIntermediateDirectories: true)
		let imageURL = directory.appendingPathComponent(name)
		try Data(bytes).write(to: imageURL)
		addTeardownBlock {
			try? fm.removeItem(at: directory)
		}
		return imageURL
	}

	private func parsedEnvironmentOutput(_ data: Data) -> [String: String] {
		let text = String(data: data, encoding: .utf8) ?? ""
		var environment: [String: String] = [:]
		for line in text.split(whereSeparator: \.isNewline) {
			guard let equalsIndex = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<equalsIndex])
			let valueStart = line.index(after: equalsIndex)
			environment[key] = String(line[valueStart...])
		}
		return environment
	}

	private func mockRunner() -> CLIProcessRunner {
		CLIProcessRunner(config: CLIProcessConfiguration(command: "echo"))
	}
}

private final class OpenCodeCLIActiveProviderStoreTestProvider {}

private final class OpenCodeCapturingACPProvider: ACPAgentProvider, @unchecked Sendable {
	private let lock = NSLock()
	private let supportResult: ACPSupportResult
	private var _capturedRequests: [ACPRunRequest] = []

	var providerID: ACPProviderID { .openCode }

	var capturedRequests: [ACPRunRequest] {
		lock.lock()
		defer { lock.unlock() }
		return _capturedRequests
	}

	init(supportResult: ACPSupportResult) {
		self.supportResult = supportResult
	}

	func support(for request: ACPRunRequest) async -> ACPSupportResult {
		lock.lock()
		_capturedRequests.append(request)
		lock.unlock()
		return supportResult
	}

	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
		throw AIProviderError.invalidConfiguration(detail: "Not expected in capturing provider")
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		throw AIProviderError.invalidConfiguration(detail: "Not expected in capturing provider")
	}

	func buildPromptBlocks(
		for message: AgentMessage,
		request: ACPRunRequest
	) throws -> [[String: Any]] {
		throw AIProviderError.invalidConfiguration(detail: "Not expected in capturing provider")
	}

	func normalizeSessionUpdate(
		_ payload: [String: Any],
		sessionID: String
	) -> [NormalizedAgentRuntimeEvent] {
		[]
	}

	func normalizeError(_ error: Error) -> Error {
		error
	}
}
