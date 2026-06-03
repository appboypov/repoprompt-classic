// CLISymlinkManager.swift
// Installs a *stable* user-space symlink that points to the bundled
// "repoprompt-mcp" CLI, so external editors can locate it regardless of
// where the app bundle lives.
//
// ──────────────────────────────────────────────────────────────────────
// NEW: Debug vs Release separation
// • Debug builds →  ~/Library/Application Support/RepoPrompt/RepoPrompt_Debug
// • Release builds → ~/Library/Application Support/RepoPrompt/RepoPrompt
//
// Having two distinct paths means you can keep a production build
// installed while running a debug build side-by-side without conflicts.
// ──────────────────────────────────────────────────────────────────────

import Foundation
import OSLog

enum CLISymlinkManagerUserSpace {

    private static let logger = Logger(subsystem: "CLI.SymlinkMgr",
                                       category: "install")

    /// File name of the symlink (differs for debug builds).
    private static var linkName: String {
        #if DEBUG
        return "repoprompt_cli_debug"
        #else
        return "repoprompt_cli"
        #endif
    }

    /// Absolute path of the user-space link, e.g.
    /// ~/Library/Application Support/RepoPrompt/RepoPrompt[_Debug]
    static var userSymlinkPath: String {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("RepoPrompt", isDirectory: true)
        return supportDir.appendingPathComponent(linkName).path
    }
    
    /// Returns the stable CLI path, falling back to bundle path if symlink is invalid.
    /// This should be used by external integrations to ensure they always get a working path.
    static var stableCLIPath: String {
        // Try to ensure symlink exists first
        ensureLocalSymlink()
        
        // If symlink is valid, use it
        if validateSymlink() {
            return userSymlinkPath
        }
        
        // Fallback to direct bundle path
        if let cliURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") {
            logger.info("Symlink invalid, falling back to bundle path: \(cliURL.path)")
            return cliURL.path
        }
        
        // Last resort: return the symlink path anyway (will likely fail, but provides consistency)
        logger.error("Both symlink and bundle CLI paths are unavailable")
        return userSymlinkPath
    }

    /// Validates that the symlink exists and points to a valid, executable target.
    static func validateSymlink() -> Bool {
        let linkPath = userSymlinkPath
        let fm = FileManager.default
        
        // Check if symlink exists
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: linkPath, isDirectory: &isDirectory) else {
            logger.debug("Symlink does not exist at: \(linkPath)")
            return false
        }
        
        // Check if we can read the symlink destination
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            logger.debug("Cannot read symlink destination at: \(linkPath)")
            return false
        }
        
        // Check if the target file exists
        guard fm.fileExists(atPath: destination) else {
            logger.debug("Symlink target does not exist: \(destination)")
            return false
        }
        
        // Check if the target is executable
        guard fm.isExecutableFile(atPath: destination) else {
            logger.debug("Symlink target is not executable: \(destination)")
            return false
        }
        
        return true
    }
    
    /// Ensures the symlink exists and points to the current bundle's CLI.
    static func ensureLocalSymlink() {
        guard let cliURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") else {
            logger.error("Bundled CLI not found")
            return
        }

        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("RepoPrompt", isDirectory: true)

        let linkPath = supportDir.appendingPathComponent(linkName).path
        let destPath = cliURL.path
        let fm       = FileManager.default

        // Create container folder if missing
        try? fm.createDirectory(at: supportDir,
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])

        // Skip if link already correct and valid
        if let current = try? fm.destinationOfSymbolicLink(atPath: linkPath),
           current == destPath && validateSymlink() {
            return
        }

        // Replace atomically
        do {
            let tmp = supportDir.appendingPathComponent(UUID().uuidString).path
            try? fm.removeItem(atPath: tmp) // clean if exists
            try fm.createSymbolicLink(atPath: tmp, withDestinationPath: destPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
            try fm.replaceItemAt(URL(fileURLWithPath: linkPath),
                                 withItemAt: URL(fileURLWithPath: tmp))
            
            // Verify the symlink was created successfully
            if !validateSymlink() {
                logger.warning("Symlink created but validation failed - external integrations will fall back to bundle path")
            }
        } catch {
            logger.error("Failed to install user-space symlink: \(error.localizedDescription) - external integrations will fall back to bundle path")
        }
    }
}
