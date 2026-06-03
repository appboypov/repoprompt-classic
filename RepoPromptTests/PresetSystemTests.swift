import XCTest
@testable import RepoPrompt

@MainActor
class PresetSystemTests: XCTestCase {
    
    // MARK: - Setup & Teardown
    
    override func setUp() {
        super.setUp()
        // Note: Managers are singletons and maintain state across tests
        // Tests should be aware of this and clean up after themselves
    }
    
    override func tearDown() {
        // Clean up any test presets added
        let copyManager = CopyPresetManager.shared
        let chatManager = ChatPresetManager.shared
        
        // Remove test presets (identified by specific names used in tests)
        let testNames = ["Test Preset", "Custom Test Preset", "To Delete", "Visibility Test", 
                        "First", "Second", "Third", "Linked Copy", "Linked Chat", 
                        "Persist Test Copy", "Persist Test Chat", "Empty Prompts", "Original Name",
                        "Test Chat Preset", "Custom Chat Preset", "Original"]
        
        for preset in copyManager.userPresets {
            if testNames.contains(preset.name) {
                copyManager.deletePreset(preset)
            }
        }
        
        for preset in chatManager.userPresets {
            if testNames.contains(preset.name) {
                chatManager.deletePreset(preset)
            }
        }
        
        super.tearDown()
    }
    
    // MARK: - CopyPreset Model Tests
    
    func testCopyPresetInitialization() {
        let preset = CopyPreset(
            name: "Test Preset",
            builtInKind: .standard,
            description: "Test Description",
            icon: "🔧",
            isBuiltIn: false,
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: false,
            includeFileTree: true,
            xmlFormat: .diff,
            fileTreeMode: .files,
            codeMapUsage: .auto,
            gitInclusion: .selected,
            systemPromptFlavor: .architectPlan,
            storedPromptIds: [],
            notes: "Test notes"
        )
        
        XCTAssertEqual(preset.name, "Test Preset")
        XCTAssertEqual(preset.builtInKind, .standard)
        XCTAssertEqual(preset.description, "Test Description")
        XCTAssertEqual(preset.icon, "🔧")
        XCTAssertFalse(preset.isBuiltIn)
        XCTAssertEqual(preset.includeFiles, true)
        XCTAssertEqual(preset.includeUserPrompt, true)
        XCTAssertEqual(preset.includeMetaPrompts, false)
        XCTAssertEqual(preset.includeFileTree, true)
        XCTAssertEqual(preset.xmlFormat, .diff)
        XCTAssertEqual(preset.fileTreeMode, .files)
        XCTAssertEqual(preset.codeMapUsage, .auto)
        XCTAssertEqual(preset.gitInclusion, .selected)
        XCTAssertEqual(preset.systemPromptFlavor, .architectPlan)
        XCTAssertEqual(preset.notes, "Test notes")
    }
    
    func testCopyPresetEquality() {
        let preset1 = CopyPreset(name: "Test", isBuiltIn: false)
        let preset2 = CopyPreset(id: preset1.id, name: "Test Modified", isBuiltIn: false)
        let preset3 = CopyPreset(name: "Test", isBuiltIn: false)
        
        // CopyPreset equality is based on all properties, not just ID
        XCTAssertNotEqual(preset1, preset2, "Presets with different names are not equal")
        XCTAssertNotEqual(preset1, preset3, "Presets with different IDs should not be equal")
    }
    
    func testBuiltInCopyPresets() {
        let standard = BuiltInCopyPresets.standard
        XCTAssertEqual(standard.name, "Standard")
        XCTAssertEqual(standard.builtInKind, .standard)
        XCTAssertTrue(standard.isBuiltIn)
        
        let plan = BuiltInCopyPresets.plan
        XCTAssertEqual(plan.name, "Plan")
        XCTAssertEqual(plan.builtInKind, .plan)
        XCTAssertNil(plan.xmlFormat) // Plan doesn't use xmlFormat anymore
        
        let manual = BuiltInCopyPresets.manual
        XCTAssertEqual(manual.name, "Manual")
        XCTAssertEqual(manual.builtInKind, .manual)
        
        let editXML = BuiltInCopyPresets.editXML
        XCTAssertEqual(editXML.name, "XML Edit")
        XCTAssertEqual(editXML.builtInKind, .editXML)
        XCTAssertEqual(editXML.xmlFormat, .diff)
        
        let proEdit = BuiltInCopyPresets.proEdit
        XCTAssertEqual(proEdit.name, "XML Pro Edit")
        XCTAssertEqual(proEdit.builtInKind, .proEdit)
        
        let diffFollowUp = BuiltInCopyPresets.diffFollowUp
        XCTAssertEqual(diffFollowUp.name, "Diff Follow-Up")
        XCTAssertEqual(diffFollowUp.builtInKind, .diffFollowUp)
        XCTAssertEqual(diffFollowUp.gitInclusion, .selected)
        
        let codeReview = BuiltInCopyPresets.codeReview
        XCTAssertEqual(codeReview.name, "Review")
        XCTAssertEqual(codeReview.builtInKind, .codeReview)
        XCTAssertEqual(codeReview.gitInclusion, .selected)
    }
    
    // MARK: - ChatPreset Model Tests
    
    func testChatPresetInitialization() {
        let preset = ChatPreset(
            name: "Test Chat Preset",
            mode: .chat,
            modelPresetName: "gpt-4",
            description: "Test Description",
            icon: "💬",
            isBuiltIn: false,
            fileTreeMode: .files,
            codeMapUsage: .complete,
            gitInclusion: .complete,
            storedPromptIds: []
        )
        
        XCTAssertEqual(preset.name, "Test Chat Preset")
        XCTAssertEqual(preset.mode, .chat)
        XCTAssertEqual(preset.modelPresetName, "gpt-4")
        XCTAssertEqual(preset.description, "Test Description")
        XCTAssertEqual(preset.icon, "💬")
        XCTAssertFalse(preset.isBuiltIn)
        XCTAssertEqual(preset.fileTreeMode, .files)
        XCTAssertEqual(preset.codeMapUsage, .complete)
        XCTAssertEqual(preset.gitInclusion, .complete)
    }
    
    func testChatPresetModes() {
        XCTAssertEqual(ChatPresetMode.chat.displayName, "Chat")
        XCTAssertEqual(ChatPresetMode.plan.displayName, "Plan")
        XCTAssertEqual(ChatPresetMode.edit.displayName, "Edit")
        XCTAssertEqual(ChatPresetMode.proEdit.displayName, "Pro Edit")
        
        XCTAssertEqual(ChatPresetMode.chat.description, "General discussion and queries")
        XCTAssertEqual(ChatPresetMode.plan.description, "Architecture and implementation planning")
        XCTAssertEqual(ChatPresetMode.edit.description, "Direct code modifications")
        XCTAssertEqual(ChatPresetMode.proEdit.description, "Advanced code modifications using configured edit agents or models")
    }
    
    func testBuiltInChatPresets() {
        let presets = ChatPreset.BuiltIn.all
        
        // Should have all built-in presets, including Pro Edit.
        XCTAssertEqual(presets.count, 6)
        
        let chat = presets.first { $0.name == "Chat" }
        XCTAssertNotNil(chat)
        XCTAssertEqual(chat?.mode, .chat)
        XCTAssertTrue(chat?.isBuiltIn ?? false)
        
        let plan = presets.first { $0.name == "Plan" }
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.mode, .plan)
        
        let edit = presets.first { $0.name == "Edit" }
        XCTAssertNotNil(edit)
        XCTAssertEqual(edit?.mode, .edit)
        
        let proEdit = presets.first { $0.name == "Pro Edit" }
        XCTAssertNotNil(proEdit)
        XCTAssertEqual(proEdit?.mode, .proEdit)
        
        let review = presets.first { $0.name == "Review" }
        XCTAssertNotNil(review)
        XCTAssertEqual(review?.gitInclusion, .selected)
        
        let manual = presets.first { $0.name == "Manual" }
        XCTAssertNotNil(manual)
    }
    
    // MARK: - CopyPresetManager Tests
    
    func testCopyPresetManagerInitialization() {
        let manager = CopyPresetManager.shared
        
        // Should have built-in presets loaded
        let presets = manager.allPresets
        XCTAssertTrue(presets.count > 0, "Should have built-in presets")
        
        // Check for standard built-in presets
        XCTAssertNotNil(presets.first { $0.builtInKind == .standard })
        XCTAssertNotNil(presets.first { $0.builtInKind == .manual })
        XCTAssertNotNil(presets.first { $0.builtInKind == .plan })
    }
    
    func testCopyPresetManagerAddPreset() {
        let manager = CopyPresetManager.shared
        let initialCount = manager.allPresets.count
        
        let newPreset = CopyPreset(
            name: "Custom Test Preset",
            description: "Test",
            isBuiltIn: false
        )
        
        manager.add(newPreset)
        
        XCTAssertEqual(manager.allPresets.count, initialCount + 1)
        XCTAssertNotNil(manager.allPresets.first { $0.id == newPreset.id })
    }
    
    func testCopyPresetManagerUpdatePreset() {
        let manager = CopyPresetManager.shared
        
        let preset = CopyPreset(
            name: "Original Name",
            isBuiltIn: false
        )
        manager.add(preset)
        
        let updatedPreset = CopyPreset(
            id: preset.id,
            name: "Original Name",
            description: "Updated Description",
            icon: "🎯",
            isBuiltIn: false
        )
        
        manager.update(updatedPreset)
        
        let retrieved = manager.allPresets.first { $0.id == preset.id }
        XCTAssertEqual(retrieved?.description, "Updated Description")
        XCTAssertEqual(retrieved?.icon, "🎯")
    }
    
    func testCopyPresetManagerDeletePreset() {
        let manager = CopyPresetManager.shared
        
        let preset = CopyPreset(
            name: "To Delete",
            isBuiltIn: false
        )
        manager.add(preset)
        
        XCTAssertNotNil(manager.allPresets.first { $0.id == preset.id })
        
        manager.deletePreset(preset)
        
        XCTAssertNil(manager.allPresets.first { $0.id == preset.id })
    }
    
    func testCopyPresetManagerCannotDeleteBuiltIn() {
        let manager = CopyPresetManager.shared
        let builtInPreset = BuiltInCopyPresets.standard
        let initialCount = manager.allPresets.filter { $0.isBuiltIn }.count
        
        manager.deletePreset(builtInPreset)
        
        let finalCount = manager.allPresets.filter { $0.isBuiltIn }.count
        XCTAssertEqual(initialCount, finalCount, "Built-in presets should not be deletable")
    }
    
    func testCopyPresetManagerVisibility() {
        let manager = CopyPresetManager.shared
        let preset = CopyPreset(name: "Visibility Test", isBuiltIn: false)
        manager.add(preset)
        
        // Should be visible by default
        XCTAssertTrue(manager.isPresetVisible(preset))
        
        // Toggle to hide preset
        manager.togglePresetVisibility(preset)
        XCTAssertFalse(manager.isPresetVisible(preset))
        
        // Toggle to show preset again
        manager.togglePresetVisibility(preset)
        XCTAssertTrue(manager.isPresetVisible(preset))
    }
    
    
    // MARK: - ChatPresetManager Tests
    
    func testChatPresetManagerInitialization() {
        let manager = ChatPresetManager.shared
        
        // Should have built-in presets loaded
        let presets = manager.allPresets
        XCTAssertTrue(presets.count > 0, "Should have built-in presets")
        
        // Check for standard built-in presets
        XCTAssertNotNil(presets.first { $0.mode == .chat })
        XCTAssertNotNil(presets.first { $0.mode == .plan })
        XCTAssertNotNil(presets.first { $0.mode == .edit })
    }
    
    func testChatPresetManagerAddPreset() {
        let manager = ChatPresetManager.shared
        let initialCount = manager.allPresets.count
        
        let newPreset = ChatPreset(
            name: "Custom Chat Preset",
            mode: .chat,
            description: "Test",
            isBuiltIn: false
        )
        
        manager.add(newPreset)
        
        XCTAssertEqual(manager.allPresets.count, initialCount + 1)
        XCTAssertNotNil(manager.allPresets.first { $0.id == newPreset.id })
    }
    
    func testChatPresetManagerUpdatePreset() {
        let manager = ChatPresetManager.shared
        
        let preset = ChatPreset(
            name: "Original",
            mode: .chat,
            isBuiltIn: false
        )
        manager.add(preset)
        
        let updatedPreset = ChatPreset(
            id: preset.id,
            name: "Original",
            mode: .chat,
            modelPresetName: "claude-3",
            isBuiltIn: false,
            fileTreeMode: .files
        )
        
        manager.update(updatedPreset)
        
        let retrieved = manager.allPresets.first { $0.id == preset.id }
        XCTAssertEqual(retrieved?.modelPresetName, "claude-3")
        XCTAssertEqual(retrieved?.fileTreeMode, .files)
    }
    
    func testChatPresetManagerDeletePreset() {
        let manager = ChatPresetManager.shared
        
        let preset = ChatPreset(
            name: "To Delete",
            mode: .plan,
            isBuiltIn: false
        )
        manager.add(preset)
        
        XCTAssertNotNil(manager.allPresets.first { $0.id == preset.id })
        
        manager.deletePreset(preset)
        
        XCTAssertNil(manager.allPresets.first { $0.id == preset.id })
    }
    
    func testChatPresetManagerVisibility() {
        let manager = ChatPresetManager.shared
        let preset = ChatPreset(name: "Visibility Test", mode: .edit, isBuiltIn: false)
        manager.add(preset)
        
        // Should be visible by default
        XCTAssertTrue(manager.isPresetVisible(preset))
        
        // Toggle to hide preset
        manager.togglePresetVisibility(preset)
        XCTAssertFalse(manager.isPresetVisible(preset))
        
        // Toggle to show preset again
        manager.togglePresetVisibility(preset)
        XCTAssertTrue(manager.isPresetVisible(preset))
    }
    
    // MARK: - Integration Tests
    
    func testChatPresetStandaloneFromCopyPresets() {
        let copyManager = CopyPresetManager.shared
        let chatManager = ChatPresetManager.shared
        
        // Create a copy preset
        let copyPreset = CopyPreset(
            name: "Linked Copy",
            isBuiltIn: false,
            xmlFormat: .diff,
            gitInclusion: .selected
        )
        copyManager.add(copyPreset)
        
        // Create a chat preset (no linkage to copy presets)
        let chatPreset = ChatPreset(
            name: "Linked Chat",
            mode: .edit,
            isBuiltIn: false
        )
        chatManager.add(chatPreset)
        
        // Ensure chat preset remains independent of copy presets
        XCTAssertNotNil(chatManager.allPresets.first { $0.id == chatPreset.id })
        XCTAssertNotNil(copyManager.allPresets.first { $0.id == copyPreset.id })
    }
    
    func testPresetPersistence() {
        let copyManager = CopyPresetManager.shared
        let chatManager = ChatPresetManager.shared
        
        // Add custom presets
        let copyPreset = CopyPreset(name: "Persist Test Copy", isBuiltIn: false)
        let chatPreset = ChatPreset(name: "Persist Test Chat", mode: .plan, isBuiltIn: false)
        
        copyManager.add(copyPreset)
        chatManager.add(chatPreset)
        
        // Save current state (happens automatically in add)
        copyManager.save()
        chatManager.save()
        
        // Reload from UserDefaults
        copyManager.load()
        chatManager.load()
        
        // Verify presets were persisted
        XCTAssertNotNil(copyManager.allPresets.first { $0.id == copyPreset.id })
        XCTAssertNotNil(chatManager.allPresets.first { $0.id == chatPreset.id })
    }
    
    
    // MARK: - Edge Cases
    
    func testEmptyStoredPromptIds() {
        let copyPreset = CopyPreset(
            name: "Empty Prompts",
            isBuiltIn: false,
            storedPromptIds: []
        )
        
        XCTAssertNotNil(copyPreset.storedPromptIds)
        XCTAssertEqual(copyPreset.storedPromptIds?.count, 0)
        
        let chatPreset = ChatPreset(
            name: "Empty Prompts",
            mode: .chat,
            isBuiltIn: false,
            storedPromptIds: nil
        )
        
        XCTAssertNil(chatPreset.storedPromptIds)
    }
    
    func testPresetWithAllOptionsNil() {
        let preset = CopyPreset(
            name: "All Nil",
            builtInKind: nil,
            description: nil,
            icon: nil,
            isBuiltIn: false,
            includeFiles: nil,
            includeUserPrompt: nil,
            includeMetaPrompts: nil,
            includeFileTree: nil,
            xmlFormat: nil,
            fileTreeMode: nil,
            codeMapUsage: nil,
            gitInclusion: nil,
            systemPromptFlavor: nil,
            storedPromptIds: nil,
            notes: nil
        )
        
        XCTAssertNil(preset.builtInKind)
        XCTAssertNil(preset.includeFiles)
        XCTAssertNil(preset.xmlFormat)
        XCTAssertNil(preset.gitInclusion)
    }
    
    func testGitInclusionModes() {
        XCTAssertEqual(GitInclusion.allCases.count, 3)
        XCTAssertTrue(GitInclusion.allCases.contains(.none))
        XCTAssertTrue(GitInclusion.allCases.contains(.selected))
        XCTAssertTrue(GitInclusion.allCases.contains(.complete))
    }
    
    func testCopyPresetKindCases() {
        XCTAssertEqual(CopyPresetKind.allCases.count, 11)
        XCTAssertTrue(CopyPresetKind.allCases.contains(.standard))
        XCTAssertTrue(CopyPresetKind.allCases.contains(.manual))
        XCTAssertTrue(CopyPresetKind.allCases.contains(.mcpAgent))
    }
}
