import Foundation

public enum GitDiffCompareSpec: Sendable, Equatable, Codable {
	case uncommitted(base: String)
	case uncommittedMergeBase(base: String)
	case staged(base: String)
	case stagedMergeBase(base: String)
	case unstaged
	case revspec(String)

	private enum Kind: String, Codable, Sendable {
		case uncommitted
		case uncommittedMergeBase
		case staged
		case stagedMergeBase
		case unstaged
		case revspec
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case base
		case spec
	}

	private enum LegacyCodingKeys: String, CodingKey {
		case uncommitted
		case uncommittedMergeBase
		case staged
		case stagedMergeBase
		case unstaged
		case revspec
	}

	private struct BasePayload: Codable {
		let base: String
	}

	private struct SpecPayload: Codable {
		let _0: String
	}

	public static func parse(_ raw: String?) -> GitDiffCompareSpec {
		guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return .uncommitted(base: "HEAD")
		}
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let lowered = trimmed.lowercased()

		if lowered == "uncommitted" {
			return .uncommitted(base: "HEAD")
		}
		if lowered.hasPrefix("uncommitted:") {
			let baseRaw = trimmed.dropFirst("uncommitted:".count)
			let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			return .uncommitted(base: base.isEmpty ? "HEAD" : base)
		}
		if lowered.hasPrefix("mergebase:") {
			let baseRaw = trimmed.dropFirst("mergebase:".count)
			let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			return .uncommittedMergeBase(base: base.isEmpty ? "HEAD" : base)
		}
		if lowered.hasPrefix("uncommitted-mergebase:") {
			let baseRaw = trimmed.dropFirst("uncommitted-mergebase:".count)
			let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			return .uncommittedMergeBase(base: base.isEmpty ? "HEAD" : base)
		}
		if lowered == "staged" {
			return .staged(base: "HEAD")
		}
		if lowered.hasPrefix("staged:") {
			let baseRaw = trimmed.dropFirst("staged:".count)
			let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			return .staged(base: base.isEmpty ? "HEAD" : base)
		}
		if lowered.hasPrefix("staged-mergebase:") {
			let baseRaw = trimmed.dropFirst("staged-mergebase:".count)
			let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			return .stagedMergeBase(base: base.isEmpty ? "HEAD" : base)
		}
		if lowered == "unstaged" {
			return .unstaged
		}
		if lowered.hasPrefix("back:") {
			let countRaw = trimmed.dropFirst("back:".count)
			let count = Int(countRaw.trimmingCharacters(in: .whitespacesAndNewlines))
			if let count, count > 0 {
				return .revspec("HEAD~\(count)..HEAD")
			}
		}

		return .revspec(trimmed)
	}

	public var rawKey: String {
		switch self {
		case .uncommitted(let base):
			return "uncommitted:\(base)"
		case .uncommittedMergeBase(let base):
			return "uncommitted-mergebase:\(base)"
		case .staged(let base):
			return "staged:\(base)"
		case .stagedMergeBase(let base):
			return "staged-mergebase:\(base)"
		case .unstaged:
			return "unstaged"
		case .revspec(let spec):
			return "revspec:\(spec)"
		}
	}

	public var displayString: String {
		switch self {
		case .uncommitted(let base):
			return base == "HEAD" ? "uncommitted" : "uncommitted:\(base)"
		case .uncommittedMergeBase(let base):
			return "mergebase:\(base)"
		case .staged(let base):
			return base == "HEAD" ? "staged" : "staged:\(base)"
		case .stagedMergeBase(let base):
			return "staged-mergebase:\(base)"
		case .unstaged:
			return "unstaged"
		case .revspec(let spec):
			return spec
		}
	}

	public init(from decoder: Decoder) throws {
		if let container = try? decoder.container(keyedBy: CodingKeys.self),
			let kind = try? container.decode(Kind.self, forKey: .kind) {
			switch kind {
			case .uncommitted:
				let base = try container.decodeIfPresent(String.self, forKey: .base) ?? "HEAD"
				self = .uncommitted(base: base)
			case .uncommittedMergeBase:
				let base = try container.decodeIfPresent(String.self, forKey: .base) ?? "HEAD"
				self = .uncommittedMergeBase(base: base)
			case .staged:
				let base = try container.decodeIfPresent(String.self, forKey: .base) ?? "HEAD"
				self = .staged(base: base)
			case .stagedMergeBase:
				let base = try container.decodeIfPresent(String.self, forKey: .base) ?? "HEAD"
				self = .stagedMergeBase(base: base)
			case .unstaged:
				self = .unstaged
			case .revspec:
				self = .revspec(try container.decode(String.self, forKey: .spec))
			}
			return
		}

		let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
		if legacy.contains(.uncommitted) {
			let payload = try legacy.decode(BasePayload.self, forKey: .uncommitted)
			self = .uncommitted(base: payload.base)
			return
		}
		if legacy.contains(.uncommittedMergeBase) {
			let payload = try legacy.decode(BasePayload.self, forKey: .uncommittedMergeBase)
			self = .uncommittedMergeBase(base: payload.base)
			return
		}
		if legacy.contains(.staged) {
			let payload = try legacy.decode(BasePayload.self, forKey: .staged)
			self = .staged(base: payload.base)
			return
		}
		if legacy.contains(.stagedMergeBase) {
			let payload = try legacy.decode(BasePayload.self, forKey: .stagedMergeBase)
			self = .stagedMergeBase(base: payload.base)
			return
		}
		if legacy.contains(.unstaged) {
			self = .unstaged
			return
		}
		if legacy.contains(.revspec) {
			let payload = try legacy.decode(SpecPayload.self, forKey: .revspec)
			self = .revspec(payload._0)
			return
		}

		throw DecodingError.dataCorrupted(
			.init(codingPath: decoder.codingPath, debugDescription: "Invalid GitDiffCompareSpec payload")
		)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .uncommitted(let base):
			try container.encode(Kind.uncommitted, forKey: .kind)
			try container.encode(base, forKey: .base)
		case .uncommittedMergeBase(let base):
			try container.encode(Kind.uncommittedMergeBase, forKey: .kind)
			try container.encode(base, forKey: .base)
		case .staged(let base):
			try container.encode(Kind.staged, forKey: .kind)
			try container.encode(base, forKey: .base)
		case .stagedMergeBase(let base):
			try container.encode(Kind.stagedMergeBase, forKey: .kind)
			try container.encode(base, forKey: .base)
		case .unstaged:
			try container.encode(Kind.unstaged, forKey: .kind)
		case .revspec(let spec):
			try container.encode(Kind.revspec, forKey: .kind)
			try container.encode(spec, forKey: .spec)
		}
	}
}
