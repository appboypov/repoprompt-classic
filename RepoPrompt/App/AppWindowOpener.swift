//
//  AppWindowOpener.swift
//  RepoPrompt
//
//  Created by Claude on 2025-01-15.
//
//  Singleton to store the SwiftUI openWindow action, enabling programmatic
//  window creation from non-SwiftUI contexts like WindowStatesManager.
//

import SwiftUI

/// Enables programmatic opening of new windows from non-SwiftUI contexts.
///
/// WindowStatesManager cannot directly access `@Environment(\.openWindow)`,
/// so this singleton stores the action captured from a SwiftUI view.
///
/// Usage:
/// 1. A SwiftUI view calls `install(openMainWindow:)` to register the action
/// 2. Non-SwiftUI code calls `openMainWindow()` to trigger window creation
@MainActor
final class AppWindowOpener {
    static let shared = AppWindowOpener()
    
    private var openMainWindowImpl: (() -> Void)?
    
    private init() {}
    
    /// Installs the openWindow action from a SwiftUI view.
    /// Called from ContentView_WithState on appear.
    func install(openMainWindow: @escaping () -> Void) {
        self.openMainWindowImpl = openMainWindow
    }
    
    /// Opens a new main window.
    /// - Throws: `WindowOpenError.openerUnavailable` if no action has been installed.
    func openMainWindow() throws {
        guard let impl = openMainWindowImpl else {
            throw WindowOpenError.openerUnavailable
        }
        impl()
    }
    
    /// Checks if the opener is ready to create windows.
    var isAvailable: Bool {
        openMainWindowImpl != nil
    }

#if DEBUG
    func installForTesting(openMainWindow: @escaping () -> Void) {
        openMainWindowImpl = openMainWindow
    }

    func resetForTesting() {
        openMainWindowImpl = nil
    }
#endif
}

/// Errors that can occur when opening windows programmatically.
enum WindowOpenError: Error, LocalizedError {
    case openerUnavailable
    
    var errorDescription: String? {
        switch self {
        case .openerUnavailable:
            return "Window opener not available. No SwiftUI view has installed the openWindow action."
        }
    }
}
