//
//  CodeMapFixtureLoopTests.swift
//  RepoPromptTests
//
//  Automated test loop that discovers and validates all codemap fixtures.
//  Runs the full pipeline (SyntaxManager → CodeMapGenerator → FileAPI) for each fixture
//  and compares against golden files.
//

import XCTest
@testable import RepoPrompt

final class CodeMapFixtureLoopTests: XCTestCase {
    
    // MARK: - Path Resolution
    
    /// Root of the test fixtures directory
    private var fixturesRoot: URL {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodeMap/
        return testsDir.appendingPathComponent("Fixtures", isDirectory: true)
    }
    
    /// Root of the golden files directory
    private var goldensRoot: URL {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodeMap/
        return testsDir.appendingPathComponent("Goldens", isDirectory: true)
    }
    
    // MARK: - Main Test Loop
    
    /// Discovers all fixtures and runs them through the codemap pipeline.
    /// Each fixture is validated for structural invariants and compared against its golden file.
    func testCodeMapFixtures_GoldenAndValidation() throws {
        let fixtures = try CodeMapFixtureRunner.discoverFixtures(fixturesRoot: fixturesRoot)
        
        XCTAssertFalse(fixtures.isEmpty, "No fixtures found in \(fixturesRoot.path)")
        
        print("🧪 Running codemap tests for \(fixtures.count) fixtures...")
        
        var passedCount = 0
        var failedFixtures: [String] = []
        
        for fixture in fixtures {
            XCTContext.runActivity(named: "Fixture: \(fixture.relativePath)") { _ in
                do {
                    try CodeMapFixtureRunner.runFixture(
                        fixture,
                        goldensRoot: goldensRoot
                    )
                    passedCount += 1
                } catch {
                    failedFixtures.append(fixture.relativePath)
                    XCTFail("[\(fixture.relativePath)] Pipeline error: \(error)")
                }
            }
        }
        
        print("✅ Passed: \(passedCount)/\(fixtures.count)")
        if !failedFixtures.isEmpty {
            print("❌ Failed: \(failedFixtures.joined(separator: ", "))")
        }
    }
    
    /// Tests that all discovered fixtures produce non-nil FileAPI with at least some content.
    /// This catches fixtures that are too minimal or malformed.
    func testAllFixtures_ProduceValidOutput() throws {
        let fixtures = try CodeMapFixtureRunner.discoverFixtures(fixturesRoot: fixturesRoot)
        
        for fixture in fixtures {
            XCTContext.runActivity(named: "Validate: \(fixture.relativePath)") { _ in
                do {
                    let captures = try SyntaxManager.shared.codeMap(
                        content: fixture.content,
                        fileExtension: fixture.fileExtension
                    )
                    
                    XCTAssertFalse(captures.isEmpty,
                                   "[\(fixture.relativePath)] No captures produced - fixture may be empty or malformed")
                    
                    let fileAPI = CodeMapGenerator.generateCodeMap(
                        from: captures,
                        content: fixture.content,
                        fullPath: fixture.virtualPath
                    )
                    
                    // Smoke fixtures should produce some output
                    if fixture.relativePath.contains("smoke") {
                        XCTAssertNotNil(fileAPI,
                                        "[\(fixture.relativePath)] Smoke fixture should produce FileAPI")
                        
                        if let api = fileAPI {
                            let hasContent = !api.classes.isEmpty ||
                                           !api.interfaces.isEmpty ||
                                           !api.functions.isEmpty ||
                                           !api.enums.isEmpty ||
                                           !api.globalVars.isEmpty
                            XCTAssertTrue(hasContent,
                                          "[\(fixture.relativePath)] Smoke fixture should have extractable content")
                        }
                    }
                } catch {
                    XCTFail("[\(fixture.relativePath)] Error: \(error)")
                }
            }
        }
    }
    
    // MARK: - Per-Language Tests
    
    /// Test that each supported language has at least one fixture
    func testAllSupportedLanguages_HaveFixtures() throws {
        let fixtures = try CodeMapFixtureRunner.discoverFixtures(fixturesRoot: fixturesRoot)
        let fixtureExtensions = Set(fixtures.map { $0.fileExtension })
        
        let missingLanguages = CodeMapFixtureRunner.supportedExtensions.subtracting(fixtureExtensions)
        
        if !missingLanguages.isEmpty {
            XCTFail("Missing fixtures for extensions: \(missingLanguages.sorted().joined(separator: ", "))")
        }
    }
    
    /// Runs fixtures for a specific language
    private func runFixturesForExtension(_ ext: String) throws {
        let fixtures = try CodeMapFixtureRunner.discoverFixtures(fixturesRoot: fixturesRoot)
            .filter { $0.fileExtension == ext }
        
        XCTAssertFalse(fixtures.isEmpty, "No fixtures found for extension: \(ext)")
        
        for fixture in fixtures {
            try CodeMapFixtureRunner.runFixture(fixture, goldensRoot: goldensRoot)
        }
    }
    
    // MARK: - Golden File Generation
    
    /// Generates all golden files unconditionally.
    /// Run this test to create/update all baselines.
    /// Note: Skipped by default - enable to regenerate goldens.
    func testGenerateAllGoldens() throws {
        // Skip unless explicitly running this test
        // Comment out the line below to regenerate goldens
        throw XCTSkip("Golden generation is disabled by default. Unskip to regenerate.")
        
        let fixtures = try CodeMapFixtureRunner.discoverFixtures(fixturesRoot: fixturesRoot)
        
        XCTAssertFalse(fixtures.isEmpty, "No fixtures found")
        
        print("🔄 Generating goldens for \(fixtures.count) fixtures...")
        
        for fixture in fixtures {
            try generateGoldenForFixture(fixture)
        }
        
        print("✅ Golden generation complete")
    }
    
    /// Helper to manually generate golden files for a fixture
    private func generateGoldenForFixture(_ fixture: CodeMapFixture) throws {
        let captures = try SyntaxManager.shared.codeMap(
            content: fixture.content,
            fileExtension: fixture.fileExtension
        )
        
        let fileAPI = CodeMapGenerator.generateCodeMap(
            from: captures,
            content: fixture.content,
            fullPath: fixture.virtualPath
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        
        // Golden path: lang/lang_filename.fileapi.json (unique naming)
        let fixtureDir = (fixture.relativePath as NSString).deletingLastPathComponent
        let fixtureBasename = (fixture.relativePath as NSString).lastPathComponent
            .replacingOccurrences(of: ".\(fixture.fileExtension)", with: "")
        
        // FileAPI golden
        let fileAPIGoldenBasename = "\(fixtureDir)_\(fixtureBasename).fileapi.json"
        let fileAPIGoldenPath = "\(fixtureDir)/\(fileAPIGoldenBasename)"
        let fileAPIGoldenURL = goldensRoot.appendingPathComponent(fileAPIGoldenPath)
        
        // Create directory if needed
        try FileManager.default.createDirectory(
            at: fileAPIGoldenURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        if let api = fileAPI {
            let snapshot = FileAPISnapshot(api: api, stablePath: fixture.virtualPath)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileAPIGoldenURL)
        } else {
            let empty = EmptyFileAPIMarker(fixture: fixture.virtualPath, reason: "No extractable code structure")
            let data = try encoder.encode(empty)
            try data.write(to: fileAPIGoldenURL)
        }
        
        // Captures golden
        let captureGoldenBasename = "\(fixtureDir)_\(fixtureBasename).captures.json"
        let captureGoldenPath = "\(fixtureDir)/\(captureGoldenBasename)"
        let captureGoldenURL = goldensRoot.appendingPathComponent(captureGoldenPath)
        
        let captureSnapshot = CaptureSnapshot(fixture: fixture.virtualPath, captures: captures)
        let captureData = try encoder.encode(captureSnapshot)
        try captureData.write(to: captureGoldenURL)
        
        print("  ✅ Generated goldens for \(fixture.relativePath)")
    }
    
    // MARK: - Individual Language Tests (for focused debugging)
    
    func testSwiftFixtures() throws {
        try runFixturesForExtension("swift")
    }
    
    func testTypeScriptFixtures() throws {
        try runFixturesForExtension("ts")
    }
    
    func testTSXFixtures() throws {
        try runFixturesForExtension("tsx")
    }
    
    func testJavaScriptFixtures() throws {
        try runFixturesForExtension("js")
    }
    
    func testPythonFixtures() throws {
        try runFixturesForExtension("py")
    }
    
    func testGoFixtures() throws {
        try runFixturesForExtension("go")
    }
    
    func testRustFixtures() throws {
        try runFixturesForExtension("rs")
    }
    
    func testCFixtures() throws {
        try runFixturesForExtension("c")
    }
    
    func testCppFixtures() throws {
        try runFixturesForExtension("cpp")
    }
    
    func testCSharpFixtures() throws {
        try runFixturesForExtension("cs")
    }
    
    func testJavaFixtures() throws {
        try runFixturesForExtension("java")
    }
    
    func testDartFixtures() throws {
        try runFixturesForExtension("dart")
    }
    
    func testPHPFixtures() throws {
        try runFixturesForExtension("php")
    }
    
    // MARK: - Regex Smoke Tests
    
    /// Smoke test to ensure all LanguageTypeExtractor regex patterns compile without crashing.
    /// Swift static let properties are initialized lazily per-property, so we must exercise
    /// each code path that touches a regex to ensure it initializes without crashing.
    func testLanguageTypeExtractorRegexInitialization() {
        // Exercise ALL function regex patterns (one per language)
        // If any pattern is invalid, this test will crash rather than silently fail
        let funcLine = "func test() {}"
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .swift)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .ts)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .tsx)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .js)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .go)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .rust)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .python)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .java)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .c_sharp)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .c)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .cpp)
        _ = LanguageTypeExtractor.matchAnyFunctionLine(funcLine, language: .dart)
        
        // Exercise ALL variable regex patterns (one per language)
        // Each language may have different variable regex patterns that need initialization
        _ = LanguageTypeExtractor.matchAnyVariableLine("let x: Int = 1", language: .swift)
        _ = LanguageTypeExtractor.matchAnyVariableLine("const café: string = 'hi'", language: .ts)
        _ = LanguageTypeExtractor.matchAnyVariableLine("const x: string = 'hi'", language: .tsx)
        _ = LanguageTypeExtractor.matchAnyVariableLine("const x = 1", language: .js)
        _ = LanguageTypeExtractor.matchAnyVariableLine("var x int = 1", language: .go)
        _ = LanguageTypeExtractor.matchAnyVariableLine("let x: i32 = 1;", language: .rust)
        _ = LanguageTypeExtractor.matchAnyVariableLine("x = 1", language: .python)
        _ = LanguageTypeExtractor.matchAnyVariableLine("private int x;", language: .java)
        _ = LanguageTypeExtractor.matchAnyVariableLine("private int x;", language: .c_sharp)
        _ = LanguageTypeExtractor.matchAnyVariableLine("int x = 0;", language: .c)
        _ = LanguageTypeExtractor.matchAnyVariableLine("int x = 0;", language: .cpp)
        _ = LanguageTypeExtractor.matchAnyVariableLine("final String x = '';", language: .dart)
        // Note: PHP variables are handled purely by AST captures, no regex
        
        // If we get here without crashing, all regex patterns are valid
        XCTAssertTrue(true, "All regex patterns initialized successfully")
    }
}
