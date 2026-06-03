import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Increase font scale: default Cmd+= (commonly used for "Cmd+").
    static let increaseFontScale = Self(
        "increaseFontScale",
        default: .init(.equal, modifiers: [.command])
    )
    
    /// Decrease font scale: default Cmd-.
    static let decreaseFontScale = Self(
        "decreaseFontScale",
        default: .init(.minus, modifiers: [.command])
    )
}