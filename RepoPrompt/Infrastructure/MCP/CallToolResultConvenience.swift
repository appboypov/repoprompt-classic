import MCP

/// Convenience helpers for building success or error replies from any tool.
extension CallTool.Result {
    /// Builds an error result with the supplied message.
    static func err(_ message: String) -> Self {
        .init(content: [MCP.Tool.Content.text(message)], isError: true)
    }

    /// Builds a plain-text success result.  Default text is "ok".
    static func ok(text: String = "ok") -> Self {
        .init(content: [MCP.Tool.Content.text(text)], isError: false)
    }
}
