import SwiftUI
import Darwin
import Logging
import Foundation
import AppKit

struct RepoPromptFileLogHandler: LogHandler {
	private let stream: FileHandle
	var metadata: Logger.Metadata = [:]
	var logLevel: Logger.Level = .info

	init(label: String) {
		self.stream = FileHandle.standardError
	}

	subscript(metadataKey key: String) -> Logger.Metadata.Value? {
		get { metadata[key] }
		set { metadata[key] = newValue }
	}

	func log(
		level: Logger.Level,
		message: Logger.Message,
		metadata explicitMetadata: Logger.Metadata?,
		source: String,
		file: String,
		function: String,
		line: UInt
	) {
		guard level >= logLevel else { return }
		let text = renderMessage(message, metadata: explicitMetadata)
		if let data = (text + "\n").data(using: .utf8) {
			try? stream.write(contentsOf: data)
		}
	}

	private func renderMessage(_ message: Logger.Message, metadata explicitMetadata: Logger.Metadata?) -> String {
		var parts = [message.description]
		let merged = mergedMetadata(explicitMetadata)
		if !merged.isEmpty {
			parts.append(merged)
		}
		return parts.joined(separator: " ")
	}

	private func mergedMetadata(_ explicit: Logger.Metadata?) -> String {
		let combined = metadata.merging(explicit ?? [:]) { _, new in new }
		guard !combined.isEmpty else { return "" }
		return combined
			.map { "\($0.key)=\($0.value)" }
			.sorted()
			.joined(separator: " ")
	}
}

@main
struct RepoPromptApp: App {
	init() {
		LoggingSystem.bootstrap { label in
			var handler = RepoPromptFileLogHandler(label: label)
#if DEBUG
			handler.logLevel = .debug
#else
			handler.logLevel = .notice
#endif
			return handler
		}
		// Avoid process-killing SIGPIPE when the child closes stdin while we're still writing.
		signal(SIGPIPE, SIG_IGN)

		RemovedExternalServiceStateCleanup.perform()
		
		if !AppLaunchConfiguration.current.suppressesWindowRestore {
			WindowStatesManager.shared.loadWindowRestoreSessionIfNeeded()
		}

		let shell = WorkspaceShellViewModel()
		let actionService = WorkspaceShellActionService(viewModel: shell)
		Self.shellActionService = actionService
		AppDeepLinkRouter.shared.configure(actionService: actionService)
		_shellViewModel = StateObject(wrappedValue: shell)
		Task { @MainActor in
			await shell.start()
		}
	}

	/// The one action service, read by `AppDelegate` when it builds the MCP routing service.
	@MainActor private(set) static var shellActionService: WorkspaceShellActionService?

	/// The single-window shell: owns every workspace runtime and the one native window.
	@StateObject private var shellViewModel: WorkspaceShellViewModel

	/// Make sure we define AppDelegate first, so it's available in init
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
	/// Global version manager for the entire app
	@StateObject private var versionManager = VersionManager()
	
	/// Tracks all WindowState objects across multiple windows (singleton)
	@StateObject private var windowStatesManager = WindowStatesManager.shared

	/// Root font scaling source so inherited SwiftUI text updates when the preset changes.
	@StateObject private var fontScale = FontScaleManager.shared
	
	// MARK: - Body
	var body: some Scene {
		Window("Repo Prompt", id: "main") {
			WorkspaceShellRootView(shellViewModel: shellViewModel, actionService: Self.shellActionService!)
				.environmentObject(versionManager)
				.environmentObject(windowStatesManager)
				.environmentObject(shellViewModel)
				.environmentObject(fontScale)
				.toolbarRole(.automatic)
				.frame(minWidth: 948, idealWidth: 1080, minHeight: 600)
				// Override environment font
				.environment(\.font, fontScale.preset.font)
				.environment(\.repoPromptFontScalePreset, fontScale.preset)
				.sheet(
					isPresented: Binding(
						get: { versionManager.shouldShowTransitionNotice },
						set: { newValue in
							if newValue == false {
								versionManager.dismissTransitionNotice()
							}
						}
					)
				) {
					TransitionNoticeView {
						versionManager.dismissTransitionNotice()
					}
				}
				.onOpenURL { incomingURL in
					Task { @MainActor in
						await AppDeepLinkRouter.shared.route(url: incomingURL)
					}
				}
		}
		.windowStyle(.automatic)
		.windowToolbarStyle(.unified)
		.commands {
			// macOS standard "Settings…" (⌘,) menu item
			CommandGroup(replacing: .appSettings) {
				Button("Settings…") {
					// Identify the currently focused window (or fall back to latest)
					if let target = windowStatesManager
						.allWindows.first(where: { $0.isCurrentlyFocused })
						?? windowStatesManager.latestWindowState {
						SettingsWindowCoordinator.shared.open(windowState: target)
					}
				}
				.keyboardShortcut(",", modifiers: .command)
			}
			
			// The shell is the only window; nothing may reintroduce "New Window".
			CommandGroup(replacing: .newItem) {}

			WorkspaceCommands(windowStatesManager: windowStatesManager)

			CommandGroup(before: .saveItem) {
				Button("Close Window") {
					NSApplication.shared.keyWindow?.performClose(nil)
				}
				.keyboardShortcut("w", modifiers: [.command, .shift])
			}

			CommandGroup(replacing: .help) {
				HelpMenu()
					.environmentObject(versionManager)
			}
		}
	}
}
