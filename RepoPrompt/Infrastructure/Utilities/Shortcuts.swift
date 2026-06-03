//
//  Shortcuts.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-09.
//

import KeyboardShortcuts

// Define your shortcut
extension KeyboardShortcuts.Name {
	static let cmdOptionC = Self("cmdOptionC", default: .init(.c, modifiers: [.command, .option]))
	//static let cmdOptionA = Self("cmdOptionA", default: .init(.a, modifiers: [.command, .option]))
	
	
	// Switch to presets with Cmd+Option+1..9
	static let switchToPreset1 = Self("swPreset1", default: .init(.one, modifiers: [.command, .option]))
	static let switchToPreset2 = Self("swPreset21", default: .init(.two, modifiers: [.command, .option]))
	static let switchToPreset3 = Self("swPreset31", default: .init(.three, modifiers: [.command, .option]))
	static let switchToPreset4 = Self("swPreset41", default: .init(.four, modifiers: [.command, .option]))
	static let switchToPreset5 = Self("swPreset51", default: .init(.five, modifiers: [.command, .option]))
	static let switchToPreset6 = Self("swPreset61", default: .init(.six, modifiers: [.command, .option]))
	static let switchToPreset7 = Self("swPreset71", default: .init(.seven, modifiers: [.command, .option]))
	static let switchToPreset8 = Self("swPreset81", default: .init(.eight, modifiers: [.command, .option]))
	static let switchToPreset9 = Self("swPreset91", default: .init(.nine, modifiers: [.command, .option]))
	
	// New shortcuts for saving workspace and presets
	static let cmdS       = Self("cmdS",       default: .init(.s, modifiers: [.command]))
	static let cmdShiftS  = Self("cmdShiftS3",  default: .init(.s, modifiers: [.command, .shift]))
	static let cmdOptionS = Self("cmdOptionS", default: .init(.s, modifiers: [.command, .option]))
	static let cmdOptionP = Self("cmdOptionP", default: .init(.p, modifiers: [.command, .option]))
	
	// Compose tab management
	static let newComposeTab = Self("composeTabNew", default: .init(.t, modifiers: [.command]))
	static let closeComposeTab = Self("composeTabClose", default: .init(.w, modifiers: [.command]))
	static let nextComposeTab = Self("composeTabNext", default: .init(.tab, modifiers: [.control]))
	static let previousComposeTab = Self("composeTabPrevious", default: .init(.tab, modifiers: [.control, .shift]))
	
	// Agent / IDE window chrome
	/// New Agent Mode session tab (same as the titlebar "New Session" control).
	static let agentNewChat = Self("agentNewChat", default: .init(.n, modifiers: [.command, .option]))
	/// Switch between IDE and Agent mode for the focused window.
	static let toggleAgentIDEMode = Self("toggleAgentIDEMode", default: .init(.a, modifiers: [.command, .option]))
	/// Toggle the primary navigation sidebar (file tree in IDE, sessions list in Agent mode).
	static let toggleNavigationSidebar = Self("toggleNavigationSidebar", default: .init(.b, modifiers: [.command, .option]))

	// Switch to compose tabs with Cmd+1..9
	static let switchToComposeTab1 = Self("swComposeTab1", default: .init(.one, modifiers: [.command]))
	static let switchToComposeTab2 = Self("swComposeTab2", default: .init(.two, modifiers: [.command]))
	static let switchToComposeTab3 = Self("swComposeTab3", default: .init(.three, modifiers: [.command]))
	static let switchToComposeTab4 = Self("swComposeTab4", default: .init(.four, modifiers: [.command]))
	static let switchToComposeTab5 = Self("swComposeTab5", default: .init(.five, modifiers: [.command]))
	static let switchToComposeTab6 = Self("swComposeTab6", default: .init(.six, modifiers: [.command]))
	static let switchToComposeTab7 = Self("swComposeTab7", default: .init(.seven, modifiers: [.command]))
	static let switchToComposeTab8 = Self("swComposeTab8", default: .init(.eight, modifiers: [.command]))
	static let switchToComposeTab9 = Self("swComposeTab9", default: .init(.nine, modifiers: [.command]))
}
