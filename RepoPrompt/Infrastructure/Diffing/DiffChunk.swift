import SwiftUI

struct DiffChunk: Equatable {
	var lines: [DiffLine]
	var startLine: Int
	
	init(lines: [DiffLine], startLine: Int) {
		self.lines = lines
		self.startLine = startLine
	}
	
	func lineCountDifference() -> Int {
		lines.reduce(0) { count, line in
			switch line.type {
			case .addition: return count + 1
			case .removal: return count - 1
			case .context: return count
			}
		}
	}
	
	/// Number of lines that appear in the old version (context + removals)
	var oldLineCount: Int {
		lines.filter { $0.type == .context || $0.type == .removal }.count
	}
	
	/// Number of lines that appear in the new version (context + additions)
	var newLineCount: Int {
		lines.filter { $0.type == .context || $0.type == .addition }.count
	}
	
	func getChunkWithEncodedIndendation() -> DiffChunk {
		let encodedLines = self.lines.map { line in
			let prefix = line.prefix
			return DiffLine(content: prefix + String.encodeIndentation(line.content))
		}
		return DiffChunk(lines: encodedLines, startLine: self.startLine)
	}
	
	func getChunkWithDecodedIndentation() -> DiffChunk {
		let decodedLines = self.lines.map { line in
			let prefix = line.prefix
			return DiffLine(content: prefix + String.decodeIndentation(line.content))
		}
		return DiffChunk(lines: decodedLines, startLine: self.startLine)
	}
	
	private func scoreMatch(in content: [String], startingAt line: Int) -> Int {
		var score = 0
		let windowSize = min(lines.count, 3)
		
		for i in 0..<windowSize {
			if line + i < content.count && lines[i].type == .context {
				let contextLine = lines[i].content
				let contentLine = content[line + i]
				if contextLine.isSimilar(to: contentLine, threshold: 0.8) {
					score += 1
				}
			}
		}
		
		return score
	}
	
	// Implement Equatable
	static func == (lhs: DiffChunk, rhs: DiffChunk) -> Bool {
		return lhs.lines == rhs.lines
	}
}

import Foundation

struct DiffLine: Equatable {
	enum LineType: Equatable {
		case addition
		case removal
		case context
	}
	
	let type: LineType
	var content: String
	let rawContent: String
	
	init(content: String) {
		self.rawContent = content
		switch content.prefix(1) {
		case "+":
			self.type = .addition
			self.content = String(content.dropFirst())
		case "-":
			self.type = .removal
			self.content = String(content.dropFirst())
		default:
			self.type = .context
			self.content = String(content.dropFirst())
		}
	}
	
	var prefix: String {
		switch type {
		case .addition: return "+"
		case .removal: return "-"
		case .context: return " "
		}
	}
	
	var prefixColor: Color {
		switch type {
		case .addition: return .green
		case .removal: return .red
		case .context: return .primary
		}
	}
	
	var contentColor: Color {
		switch type {
		case .addition, .removal: return .primary
		case .context: return .secondary
		}
	}
	
	var backgroundColor: Color {
		switch type {
		case .addition: return Color.green.opacity(0.1)
		case .removal: return Color.red.opacity(0.1)
		case .context: return Color.clear
		}
	}
	
	// Implement Equatable with fuzzy comparison
	static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
		return lhs.type == rhs.type &&
		lhs.content.isSimilar(to: rhs.content, threshold: 0.9) &&
		lhs.rawContent.isSimilar(to: rhs.rawContent, threshold: 0.9)
	}
}
