//
//  BundleVerificationService.swift
//  RepoPrompt
//
//  Created by Claude on 2025-11-30.
//

import Foundation

/// Actor that handles bundle signature verification off the main thread.
/// Using an actor ensures the heavy Security.framework calls don't block the main thread
/// while maintaining full security verification on every launch.
actor BundleVerificationService {
    
    /// Verifies the bundle signature.
    /// Performs FULL verification on every launch - no caching.
    /// - Parameter bundle: The bundle to verify (defaults to main bundle)
    /// - Returns: `true` if verification succeeds
    /// - Throws: `BundleVerifier.VerificationError` if verification fails
    func verify(bundle: Bundle = .main) throws -> Bool {
        #if DEBUG
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("[BundleVerificationService] Full verification completed in \(String(format: "%.3f", elapsed))s")
        }
        #endif
        
        // Add random delay to make timing attacks harder
        let randomDelay = Double.random(in: 0.001...0.05)
        Thread.sleep(forTimeInterval: randomDelay)
        
        // Run the heavy Security.framework call (SecStaticCodeCheckValidity)
        // This runs on the actor's executor, not the main thread
        try BundleVerifier.verifyBundleSignature(bundle: bundle)
        
        return true
    }
}
