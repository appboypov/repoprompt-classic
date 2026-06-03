import Foundation

// Pure helper for create preflight validation and root-alias checks.
enum CreatePathPreflight {
	/// Controls how strict the preflight validation is for multi-root workspaces.
	enum Mode: Sendable {
		/// Current behavior: always require alias prefix or absolute path when multiple roots are loaded.
		case strictRequireAliasInMultiRoot
		/// Relaxed mode for tool flows: allow relative paths without alias if they can be resolved
		/// unambiguously to a single root by a higher-level resolver.
		case allowImplicitRootIfUnambiguous
	}
	
	typealias Root = WorkspaceRootRef
	
	enum AliasPrefixCheck: Sendable, Equatable {
		case notPrefixed
		case uniqueRoot(root: Root, alias: String)
		case ambiguous(alias: String, matchingRoots: [Root])
	}
	
	enum Error: Swift.Error, Equatable {
		case emptyPath
		case ambiguousAlias(alias: String, matchingRoots: [Root])
		case missingAliasWithMultipleRoots(loadedRoots: [Root])
	}
	
	struct Result: Sendable, Equatable {
		let normalizedPath: String
		let aliasCheck: AliasPrefixCheck
		let isAbsolute: Bool
	}
	
	static func validate(
		userPath: String,
		visibleRoots: [Root],
		mode: Mode = .strictRequireAliasInMultiRoot
	) throws -> Result {
		let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw Error.emptyPath
		}
		
		let standardized = StandardizedPath.absolute(trimmed)
		let isAbsolute = standardized.hasPrefix("/")
		
		let aliasCheck: AliasPrefixCheck
		if !isAbsolute {
			aliasCheck = checkAliasPrefix(
				standardized,
				visibleRoots: visibleRoots,
				requireRemainder: true
			)
			switch aliasCheck {
			case .ambiguous(let alias, let matchingRoots):
				throw Error.ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
			case .notPrefixed:
				if visibleRoots.count > 1 && mode == .strictRequireAliasInMultiRoot {
					throw Error.missingAliasWithMultipleRoots(loadedRoots: visibleRoots)
				}
			case .uniqueRoot:
				break
			}
		} else {
			aliasCheck = .notPrefixed
		}
		
		return Result(normalizedPath: standardized, aliasCheck: aliasCheck, isAbsolute: isAbsolute)
	}
	
	static func checkAliasPrefix(
		_ userPath: String,
		visibleRoots: [Root],
		requireRemainder: Bool
	) -> AliasPrefixCheck {
		switch WorkspaceAliasResolver.resolve(
			userPath: userPath,
			roots: visibleRoots,
			options: RootAliasOptions(
				requireRemainder: requireRemainder,
				allowCompatibilityAlias: true,
				// Keep explicit alias detection in preflight. Tool-create performs richer
				// literal-vs-alias depth disambiguation later in
				// `RepoFileManagerViewModel.resolvedLiteralCreateResult(...)`.
				// Setting this to true would suppress alias info needed downstream.
				disambiguateRealSubpath: false
			)
		) {
		case .notAliasPrefixed, .bareRoot:
			return .notPrefixed
		case .prefixed(let root, let alias, _):
			return .uniqueRoot(root: root, alias: alias)
		case .ambiguous(let alias, let matchingRoots):
			return .ambiguous(alias: alias, matchingRoots: matchingRoots)
		}
	}
}
