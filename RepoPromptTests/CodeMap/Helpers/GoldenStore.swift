//
//  GoldenStore.swift
//  RepoPromptTests
//
//  Golden file storage and comparison utilities.
//  Supports reading, comparing, and optionally updating golden files.
//

import Foundation
import XCTest

/// Policy for handling golden file updates
enum GoldenUpdatePolicy {
    /// Never update goldens, only compare
    case never
    /// Always update goldens (for regeneration)
    case always
    /// Update goldens if the specified environment variable is set
    case ifEnvVarSet(String)
    
    var shouldUpdate: Bool {
        switch self {
        case .never:
            return false
        case .always:
            return true
        case .ifEnvVarSet(let envVar):
            return ProcessInfo.processInfo.environment[envVar] != nil
        }
    }
}

/// Result of a golden comparison
enum GoldenComparisonResult {
    case matched
    case mismatched(expected: String, actual: String)
    case goldenMissing
    case updated
}

/// Utilities for golden file management
struct GoldenStore {
    
    /// Standard JSON encoder configured for stable, readable output
    static var stableEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    
    /// Asserts that a value matches its golden file, with optional update capability
    /// - Parameters:
    ///   - value: The value to compare
    ///   - goldenURL: URL to the golden file
    ///   - updatePolicy: Policy for handling updates
    ///   - encoder: JSON encoder to use (defaults to stableEncoder)
    ///   - file: Source file for assertion failures
    ///   - line: Source line for assertion failures
    static func assertGolden<T: Encodable>(
        _ value: T,
        goldenURL: URL,
        updatePolicy: GoldenUpdatePolicy = .ifEnvVarSet("UPDATE_CODEMAP_GOLDENS"),
        encoder: JSONEncoder? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let enc = encoder ?? stableEncoder
        let actualData = try enc.encode(value)
        let actualString = String(data: actualData, encoding: .utf8)!
        
        let result = try compare(
            actualString: actualString,
            goldenURL: goldenURL,
            updatePolicy: updatePolicy
        )
        
        switch result {
        case .matched:
            // Success - no assertion needed
            break
            
        case .mismatched(let expected, let actual):
            // Generate a readable diff
            let diff = generateDiff(expected: expected, actual: actual)
            XCTFail("""
                Golden mismatch for \(goldenURL.lastPathComponent)
                
                \(diff)
                
                To update goldens, run with UPDATE_CODEMAP_GOLDENS=1
                """, file: file, line: line)
            
        case .goldenMissing:
            XCTFail("""
                Golden file missing: \(goldenURL.path)
                
                To generate goldens, run with UPDATE_CODEMAP_GOLDENS=1
                """, file: file, line: line)
            
        case .updated:
            // Golden was updated - this is informational, not a failure
            print("✅ Updated golden: \(goldenURL.lastPathComponent)")
        }
    }
    
    /// Compare actual string against golden file
    static func compare(
        actualString: String,
        goldenURL: URL,
        updatePolicy: GoldenUpdatePolicy
    ) throws -> GoldenComparisonResult {
        let fileManager = FileManager.default
        
        // Check if golden exists
        if fileManager.fileExists(atPath: goldenURL.path) {
            let expectedData = try Data(contentsOf: goldenURL)
            let expectedString = String(data: expectedData, encoding: .utf8)!
            
            // Normalize line endings for comparison
            let normalizedExpected = expectedString.replacingOccurrences(of: "\r\n", with: "\n")
            let normalizedActual = actualString.replacingOccurrences(of: "\r\n", with: "\n")
            
            if normalizedExpected == normalizedActual {
                return .matched
            } else if updatePolicy.shouldUpdate {
                try write(actualString, to: goldenURL)
                return .updated
            } else {
                return .mismatched(expected: normalizedExpected, actual: normalizedActual)
            }
        } else {
            // Golden doesn't exist
            if updatePolicy.shouldUpdate {
                try write(actualString, to: goldenURL)
                return .updated
            } else {
                return .goldenMissing
            }
        }
    }
    
    /// Write content to golden file, creating directories as needed
    private static func write(_ content: String, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    /// Generate a human-readable diff between expected and actual strings
    private static func generateDiff(expected: String, actual: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        
        var diff: [String] = []
        let maxLines = max(expectedLines.count, actualLines.count)
        var diffCount = 0
        let maxDiffs = 20 // Limit output size
        
        for i in 0..<maxLines {
            let expectedLine = i < expectedLines.count ? expectedLines[i] : nil
            let actualLine = i < actualLines.count ? actualLines[i] : nil
            
            if expectedLine != actualLine {
                diffCount += 1
                if diffCount <= maxDiffs {
                    diff.append("Line \(i + 1):")
                    if let exp = expectedLine {
                        diff.append("  - \(exp)")
                    } else {
                        diff.append("  - (missing)")
                    }
                    if let act = actualLine {
                        diff.append("  + \(act)")
                    } else {
                        diff.append("  + (missing)")
                    }
                }
            }
        }
        
        if diffCount > maxDiffs {
            diff.append("... and \(diffCount - maxDiffs) more differences")
        }
        
        return diff.isEmpty ? "(no visible diff)" : diff.joined(separator: "\n")
    }
}
