import Foundation

/// What one sidebar row shows. Derived from the published snapshot, never from a runtime.
struct WorkspaceRowModel: Identifiable, Equatable, Sendable {
	let id: UUID
	let name: String
	let rootCount: Int
	let isVisible: Bool
	let isAvailable: Bool
	let hasRunningAgents: Bool
	/// Uppercased first characters of the first two words of the name, for the collapsed rail.
	let initials: String

	init(summary: MCPWorkspaceSummary) {
		id = summary.id
		name = summary.name
		rootCount = summary.rootCount
		isVisible = summary.isVisible
		isAvailable = summary.isAvailable
		hasRunningAgents = summary.hasRunningAgents
		initials = Self.initials(for: summary.name)
	}

	static func initials(for name: String) -> String {
		let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
		let letters = words.compactMap { $0.first }.map { String($0).uppercased() }
		return letters.joined()
	}
}
