import XCTest
@testable import RepoPrompt

final class ModelPresetTests: XCTestCase {
    
    // MARK: - Name Validation Tests
    
    func testValidateNameWithValidNames() {
        // Valid names should pass
        XCTAssertTrue(ModelPreset.validateName("MyPreset").isValid)
        XCTAssertTrue(ModelPreset.validateName("preset_123").isValid)
        XCTAssertTrue(ModelPreset.validateName("GPT-4-Turbo").isValid)
        XCTAssertTrue(ModelPreset.validateName("A").isValid)
        XCTAssertTrue(ModelPreset.validateName("1234").isValid)
        XCTAssertTrue(ModelPreset.validateName("test-preset_2024").isValid)
    }
    
    func testValidateNameWithInvalidNames() {
        // Empty name
        let emptyResult = ModelPreset.validateName("")
        XCTAssertFalse(emptyResult.isValid)
        XCTAssertEqual(emptyResult.error, "Name cannot be empty")
        
        // Whitespace only
        let whitespaceResult = ModelPreset.validateName("   ")
        XCTAssertFalse(whitespaceResult.isValid)
        XCTAssertEqual(whitespaceResult.error, "Name cannot be empty")
        
        // Too long
        let longName = String(repeating: "a", count: 31)
        let longResult = ModelPreset.validateName(longName)
        XCTAssertFalse(longResult.isValid)
        XCTAssertEqual(longResult.error, "Name must be 30 characters or less")
        
        // Contains spaces
        let spaceResult = ModelPreset.validateName("My Preset")
        XCTAssertFalse(spaceResult.isValid)
        XCTAssertEqual(spaceResult.error, "Name cannot contain spaces or tabs")
        
        // Contains special characters
        let specialResult = ModelPreset.validateName("preset@home")
        XCTAssertFalse(specialResult.isValid)
        XCTAssertEqual(specialResult.error, "Name can only contain letters, numbers, underscores, and hyphens")
        
        // Starts with special character
        let startResult = ModelPreset.validateName("-preset")
        XCTAssertFalse(startResult.isValid)
        XCTAssertEqual(startResult.error, "Name must start with a letter or number")
    }
    
    // MARK: - Name Sanitization Tests
    
    func testSanitizeName() {
        // Basic sanitization
        XCTAssertEqual(ModelPreset.sanitizeName("My Preset"), "My_Preset")
        XCTAssertEqual(ModelPreset.sanitizeName("  trimmed  "), "trimmed")
        
        // Special characters
        XCTAssertEqual(ModelPreset.sanitizeName("preset@home!"), "preset_home_")
        XCTAssertEqual(ModelPreset.sanitizeName("test/preset"), "test_preset")
        
        // Consecutive underscores
        XCTAssertEqual(ModelPreset.sanitizeName("a    b"), "a_b")
        XCTAssertEqual(ModelPreset.sanitizeName("test___preset"), "test_preset")
        
        // Starting with invalid character
        XCTAssertEqual(ModelPreset.sanitizeName("-preset"), "preset_-preset")
        XCTAssertEqual(ModelPreset.sanitizeName("_test"), "preset__test")
        
        // Length limiting
        let longName = String(repeating: "a", count: 40)
        XCTAssertEqual(ModelPreset.sanitizeName(longName).count, 30)
        
        // Empty or whitespace only
        XCTAssertTrue(ModelPreset.sanitizeName("").hasPrefix("preset_"))
        XCTAssertTrue(ModelPreset.sanitizeName("   ").hasPrefix("preset_"))
    }
    
    // MARK: - Fuzzy Matching Tests
    
    func testFindBestMatchExact() {
        let names = ["GPT4", "Claude", "Gemini", "DeepSeek"]
        
        // Exact match
        XCTAssertEqual(ModelPreset.findBestMatch("GPT4", among: names), "GPT4")
        XCTAssertEqual(ModelPreset.findBestMatch("Claude", among: names), "Claude")
    }
    
    func testFindBestMatchCaseInsensitive() {
        let names = ["GPT4", "Claude", "Gemini", "DeepSeek"]
        
        // Case insensitive
        XCTAssertEqual(ModelPreset.findBestMatch("gpt4", among: names), "GPT4")
        XCTAssertEqual(ModelPreset.findBestMatch("CLAUDE", among: names), "Claude")
        XCTAssertEqual(ModelPreset.findBestMatch("gemini", among: names), "Gemini")
    }
    
    func testFindBestMatchPrefix() {
        let names = ["GPT4-Turbo", "Claude-Instant", "Gemini-Pro", "DeepSeek-Coder"]
        
        // Prefix matching
        XCTAssertEqual(ModelPreset.findBestMatch("GPT", among: names), "GPT4-Turbo")
        XCTAssertEqual(ModelPreset.findBestMatch("Clau", among: names), "Claude-Instant")
        XCTAssertEqual(ModelPreset.findBestMatch("gem", among: names), "Gemini-Pro")
    }
    
    func testFindBestMatchContains() {
        let names = ["fast-gpt4", "claude-3-opus", "google-gemini", "deep-seek-v2"]
        
        // Contains matching
        XCTAssertEqual(ModelPreset.findBestMatch("gpt4", among: names), "fast-gpt4")
        XCTAssertEqual(ModelPreset.findBestMatch("opus", among: names), "claude-3-opus")
        XCTAssertEqual(ModelPreset.findBestMatch("gemini", among: names), "google-gemini")
    }
    
    func testFindBestMatchFuzzy() {
        let names = ["GPT4-Turbo", "Claude-Sonnet", "Gemini-Pro", "DeepSeek"]

        // Hyphen/formatting variations (realistic for AI model requests)
        XCTAssertEqual(ModelPreset.findBestMatch("GPT4Turbo", among: names), "GPT4-Turbo")
        XCTAssertEqual(ModelPreset.findBestMatch("ClaudeSonnet", among: names), "Claude-Sonnet")

        // Prefix matches
        XCTAssertEqual(ModelPreset.findBestMatch("Claud", among: names), "Claude-Sonnet")
        XCTAssertEqual(ModelPreset.findBestMatch("Gemini", among: names), "Gemini-Pro")
        XCTAssertEqual(ModelPreset.findBestMatch("Deep", among: names), "DeepSeek")
    }
    
    func testFindBestMatchNoMatch() {
        let names = ["GPT4", "Claude", "Gemini"]
        
        // No reasonable match
        XCTAssertNil(ModelPreset.findBestMatch("Llama", among: names))
        XCTAssertNil(ModelPreset.findBestMatch("xyz", among: names))
        XCTAssertNil(ModelPreset.findBestMatch("123", among: names))
    }
    
    func testFindBestMatchWithUnderscores() {
        let names = ["gpt_4_turbo", "claude_3_sonnet", "gemini_1_5_pro"]
        
        // Matching with underscores vs hyphens
        XCTAssertEqual(ModelPreset.findBestMatch("gpt-4-turbo", among: names), "gpt_4_turbo")
        XCTAssertEqual(ModelPreset.findBestMatch("claude 3 sonnet", among: names), "claude_3_sonnet")
        XCTAssertEqual(ModelPreset.findBestMatch("gemini_1_5", among: names), "gemini_1_5_pro")
    }
    
    func testFindBestMatchPriority() {
        // Test that exact matches take priority over fuzzy matches
        let names = ["test", "test123", "testing", "test-preset"]
        
        // Exact should win
        XCTAssertEqual(ModelPreset.findBestMatch("test", among: names), "test")
        
        // Prefix should win over contains
        let names2 = ["production-test", "test-production", "testing"]
        XCTAssertEqual(ModelPreset.findBestMatch("test", among: names2), "test-production")
    }
    
    // MARK: - Model Preset Storage Tests
    
    func testPresetInitialization() {
        let preset = ModelPreset(
            name: "My GPT 4",
            model: .gpt4o,
            description: "Fast responses",
            supportedModes: SupportedModes(chat: true, plan: false, edit: true, review: false)
        )

        // Name should be sanitized
        XCTAssertEqual(preset.name, "My_GPT_4")
        XCTAssertEqual(preset.model, .gpt4o)
        XCTAssertEqual(preset.description, "Fast responses")
        XCTAssertNotNil(preset.supportedModes)
        XCTAssertTrue(preset.supportedModes!.chat)
        XCTAssertFalse(preset.supportedModes!.plan)
        XCTAssertTrue(preset.supportedModes!.edit)
        XCTAssertFalse(preset.supportedModes!.review)
    }
    
    func testSupportedModesDisplayString() {
        // All modes (including review)
        let allModes = SupportedModes(chat: true, plan: true, edit: true, review: true)
        XCTAssertEqual(allModes.displayString, "All modes")

        // Some modes
        let someModes = SupportedModes(chat: true, plan: false, edit: true, review: false)
        XCTAssertEqual(someModes.displayString, "Chat, Edit")

        // Single mode
        let singleMode = SupportedModes(chat: false, plan: true, edit: false, review: false)
        XCTAssertEqual(singleMode.displayString, "Plan")

        // No modes
        let noModes = SupportedModes(chat: false, plan: false, edit: false, review: false)
        XCTAssertEqual(noModes.displayString, "No modes enabled")
        XCTAssertFalse(noModes.hasEnabledModes)

        // Review mode only
        let reviewOnly = SupportedModes(chat: false, plan: false, edit: false, review: true)
        XCTAssertEqual(reviewOnly.displayString, "Review")
        XCTAssertTrue(reviewOnly.hasEnabledModes)
    }

    // MARK: - Backward Compatibility Tests

    func testSupportedModesBackwardCompatibilityDecoding() throws {
        // Old JSON without 'review' key - should decode with review defaulting to true
        let oldJSON = """
        {"chat": true, "plan": false, "edit": true}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SupportedModes.self, from: oldJSON)

        XCTAssertTrue(decoded.chat)
        XCTAssertFalse(decoded.plan)
        XCTAssertTrue(decoded.edit)
        XCTAssertTrue(decoded.review, "Missing 'review' key should default to true")
    }

    func testSupportedModesFullDecoding() throws {
        // New JSON with all keys including 'review'
        let newJSON = """
        {"chat": true, "plan": true, "edit": false, "review": false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SupportedModes.self, from: newJSON)

        XCTAssertTrue(decoded.chat)
        XCTAssertTrue(decoded.plan)
        XCTAssertFalse(decoded.edit)
        XCTAssertFalse(decoded.review)
    }

    func testChatPresetMappingsBackwardCompatibilityDecoding() throws {
        // Old JSON without 'reviewPresetID' key
        let oldJSON = """
        {"chatPresetID": "550e8400-e29b-41d4-a716-446655440000", "planPresetID": null, "editPresetID": "550e8400-e29b-41d4-a716-446655440001"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChatPresetMappings.self, from: oldJSON)

        XCTAssertEqual(decoded.chatPresetID?.uuidString, "550E8400-E29B-41D4-A716-446655440000")
        XCTAssertNil(decoded.planPresetID)
        XCTAssertEqual(decoded.editPresetID?.uuidString, "550E8400-E29B-41D4-A716-446655440001")
        XCTAssertNil(decoded.reviewPresetID, "Missing 'reviewPresetID' key should default to nil")
    }

    func testModelPresetBackwardCompatibilityDecoding() throws {
        // Old JSON with supportedModes missing 'review' key
        let oldJSON = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "name": "OldPreset",
            "modelString": "gpt-4o",
            "description": "Test preset",
            "supportedModes": {"chat": true, "plan": true, "edit": false}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ModelPreset.self, from: oldJSON)

        XCTAssertEqual(decoded.name, "OldPreset")
        XCTAssertEqual(decoded.modelString, "gpt-4o")
        XCTAssertNotNil(decoded.supportedModes)
        XCTAssertTrue(decoded.supportedModes!.chat)
        XCTAssertTrue(decoded.supportedModes!.plan)
        XCTAssertFalse(decoded.supportedModes!.edit)
        XCTAssertTrue(decoded.supportedModes!.review, "Missing review in supportedModes should default to true")
        XCTAssertEqual(decoded.proEditingOverride, .useDefault, "Missing proEditingOverride should default to .useDefault")
        XCTAssertNil(decoded.chatPresetMappings, "Missing chatPresetMappings should be nil")
    }
    
    // MARK: - Model Presets Manager Tests
    
    func testClaudeCodeGranularModelPresetRoundTrips() throws {
        let model = AIModel.claudeCodeModel(specifier: "claude-opus-4-7:xhigh")
        let preset = ModelPreset(name: "ClaudeOpus47XHigh", model: model)

        XCTAssertEqual(preset.modelString, "claude_code__claude-opus-4-7:xhigh")
        XCTAssertEqual(preset.optionalModel, model)

        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ModelPreset.self, from: encoded)

        XCTAssertEqual(decoded.modelString, "claude_code__claude-opus-4-7:xhigh")
        XCTAssertEqual(decoded.optionalModel, model)
    }

    @MainActor
    func testPresetsManagerCRUD() {
        let manager = ModelPresetsManager.shared
        
        // Clear any existing presets
        manager.presets.forEach { manager.removePreset($0) }
        
        // Add preset
        let preset1 = ModelPreset(name: "Test1", model: .gpt4o)
        manager.addPreset(preset1)
        XCTAssertEqual(manager.presets.count, 1)
        
        // Find by name
        XCTAssertNotNil(manager.preset(named: "Test1"))
        XCTAssertNil(manager.preset(named: "NonExistent"))
        
        // Find by ID
        XCTAssertNotNil(manager.preset(withID: preset1.id))
        
        // Update preset
        let updatedPreset = ModelPreset(
            id: preset1.id,
            name: preset1.name,
            model: preset1.model,
            description: "Updated description",
            supportedModes: preset1.supportedModes
        )
        manager.updatePreset(updatedPreset)
        
        let retrieved = manager.preset(withID: preset1.id)
        XCTAssertEqual(retrieved?.description, "Updated description")
        
        // Remove preset
        manager.removePreset(preset1)
        XCTAssertEqual(manager.presets.count, 0)
    }
    
    @MainActor
    func testAvailablePresetsForMode() {
        let manager = ModelPresetsManager.shared
        
        // Clear any existing presets
        manager.presets.forEach { manager.removePreset($0) }
        
        // Add presets with different mode restrictions
        let chatOnly = ModelPreset(
            name: "ChatOnly",
            model: .gpt4o,
            supportedModes: SupportedModes(chat: true, plan: false, edit: false, review: false)
        )
        let planEdit = ModelPreset(
            name: "PlanEdit",
            model: .claude4Sonnet,
            supportedModes: SupportedModes(chat: false, plan: true, edit: true, review: false)
        )
        let unrestricted = ModelPreset(
            name: "Unrestricted",
            model: .gpt41,
            supportedModes: nil
        )
        
        manager.addPreset(chatOnly)
        manager.addPreset(planEdit)
        manager.addPreset(unrestricted)
        
        // Test filtering by mode
        let chatPresets = manager.availablePresets(for: "chat")
        XCTAssertEqual(chatPresets.count, 2) // chatOnly + unrestricted
        XCTAssertTrue(chatPresets.contains { $0.name == "ChatOnly" })
        XCTAssertTrue(chatPresets.contains { $0.name == "Unrestricted" })
        
        let planPresets = manager.availablePresets(for: "plan")
        XCTAssertEqual(planPresets.count, 2) // planEdit + unrestricted
        XCTAssertTrue(planPresets.contains { $0.name == "PlanEdit" })
        XCTAssertTrue(planPresets.contains { $0.name == "Unrestricted" })
        
        // Clean up
        manager.removePreset(chatOnly)
        manager.removePreset(planEdit)
        manager.removePreset(unrestricted)
    }
}