//
//  Service.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//


import Foundation
import SwiftUI
import MCP

@preconcurrency
protocol Service {
    var tools: [Tool] { get async }

    var isActivated: Bool { get async }
    func activate() async throws
}

// ---------------------------------------------------------------------
//  Default no-op behaviour – a Service can become "active" lazily
// ---------------------------------------------------------------------
extension Service {
    var isActivated: Bool { get async { true } }
    func activate() async throws {}

    /// Dispatch a tool call to the matching `Tool` implementation
    func call(tool name: String,
              with arguments: [String : Value]) async throws -> Value? {
        // Reject immediately when the tool is disabled via settings
        if let reason = await ToolAvailabilityStore.shared.globalSuppressionReason(for: name) {
            throw MCPError.invalidParams("Tool \"\(name)\" is unavailable: \(reason)")
        }
        guard await ToolAvailabilityStore.shared.isEnabled(name) else {
            throw MCPError.invalidParams("Tool \"\(name)\" is disabled by the user.")
        }

        // Normal dispatch
        for tool in await tools where tool.name == name {
            return try await tool.callAsFunction(arguments)
        }
        return nil
    }
}

// ---------------------------------------------------------------------
//  Convenience builder so individual services can declare their tools
//  with a clean DSL style (`@ToolBuilder var tools: [Tool] { … }`)
// ---------------------------------------------------------------------
@resultBuilder
struct ToolBuilder {
    static func buildBlock(_ tools: Tool...) -> [Tool] { tools }
}
