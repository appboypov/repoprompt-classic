import XCTest
@testable import RepoPrompt

final class MovePathResolverTests: XCTestCase {
	private func makeRoot(id: UUID = UUID(), name: String, fullPath: String) -> MovePathResolver.Root {
		MovePathResolver.Root(id: id, name: name, fullPath: fullPath)
	}
	
	func testRelativePathWithoutAliasReturnsAsIs() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "Views/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "Views/File.swift")
	}
	
	func testAliasPrefixedDropsAliasWhenNoSubfolder() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "RepoPrompt/Views/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "Views/File.swift")
	}
	
	func testAliasPrefixedConsumesOnlyTheLeadingRootAliasWhenSameNameSubfolderExists() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "RepoPrompt/Views/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "Views/File.swift")
	}

	func testAliasDoublePrefixedCollapsesWhenNestedSubfolderMissing() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "RepoPrompt/RepoPrompt/Views/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "RepoPrompt/Views/File.swift")
	}

	func testAliasDoublePrefixedKeepsOneLiteralSameNameSegment() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "RepoPrompt/RepoPrompt/Views/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "RepoPrompt/Views/File.swift")
	}
	
	func testAliasPrefixedUsesLastPathComponentFallback() throws {
		let root = makeRoot(name: "Workspace", fullPath: "/Users/test/BombSquad")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "BombSquad/src/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "src/File.swift")
	}

	func testAliasPrefixedUsesStandardizedLastPathComponentFallback() throws {
		let root = makeRoot(name: "Workspace", fullPath: "/Users/test/BombSquad/./src/..")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "BombSquad/src/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "src/File.swift")
	}
	
	func testAliasPrefixedForDifferentRootThrows() {
		let rootA = makeRoot(name: "AppA", fullPath: "/Users/test/AppA")
		let rootB = makeRoot(name: "AppB", fullPath: "/Users/test/AppB")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "AppB/Views/File.swift",
				sourceRoot: rootA,
				visibleRoots: [rootA, rootB]
			)
			XCTFail("Expected cross-root alias error")
		} catch let error as MovePathResolver.Error {
			switch error {
			case .crossRootAlias(let alias, let resolvedRoot):
				XCTAssertEqual(alias, "AppB")
				XCTAssertEqual(resolvedRoot, rootB)
			default:
				XCTFail("Unexpected error: \(error)")
			}
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
	
	func testAmbiguousAliasThrows() {
		let rootA = makeRoot(id: UUID(), name: "App", fullPath: "/Users/test/AppA")
		let rootB = makeRoot(id: UUID(), name: "App", fullPath: "/Users/test/AppB")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "App/Views/File.swift",
				sourceRoot: rootA,
				visibleRoots: [rootA, rootB]
			)
			XCTFail("Expected ambiguous alias error")
		} catch let error as MovePathResolver.Error {
			switch error {
			case .ambiguousAlias(let alias, let matchingRoots):
				XCTAssertEqual(alias, "App")
				XCTAssertEqual(Set(matchingRoots), Set([rootA, rootB]))
			default:
				XCTFail("Unexpected error: \(error)")
			}
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
	
	func testRelativePathEscapingRootThrows() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "../Other/Views/File.swift",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected destination outside root error")
		} catch let error as MovePathResolver.Error {
			switch error {
			case .destinationOutsideRoot(let errRoot):
				XCTAssertEqual(errRoot, root)
			default:
				XCTFail("Unexpected error: \(error)")
			}
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testDotDestinationThrowsEmptyDestination() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: ".",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected empty destination error")
		} catch let error as MovePathResolver.Error {
			XCTAssertEqual(error, .emptyDestination)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testParentCancellingDestinationThrowsEmptyDestination() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "src/..",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected empty destination error")
		} catch let error as MovePathResolver.Error {
			XCTAssertEqual(error, .emptyDestination)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testAliasPrefixedDestinationCollapsingToRootThrowsEmptyDestination() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "RepoPrompt/src/..",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected empty destination error")
		} catch let error as MovePathResolver.Error {
			XCTAssertEqual(error, .emptyDestination)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
	
	func testAbsolutePathInsideRootReturnsRelative() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try MovePathResolver.resolveRelativePathInRoot(
			userPath: "/Users/test/RepoPrompt/Views/File.swift",
			sourceRoot: root,
			visibleRoots: [root]
		)
		XCTAssertEqual(result, "Views/File.swift")
	}

	func testAbsoluteRootPathThrowsEmptyDestination() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "/Users/test/RepoPrompt/.",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected empty destination error")
		} catch let error as MovePathResolver.Error {
			XCTAssertEqual(error, .emptyDestination)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testAbsolutePathCollapsingToRootThrowsEmptyDestination() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "/Users/test/RepoPrompt/src/..",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected empty destination error")
		} catch let error as MovePathResolver.Error {
			XCTAssertEqual(error, .emptyDestination)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
	
	func testAbsolutePathOutsideRootThrows() {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		do {
			_ = try MovePathResolver.resolveRelativePathInRoot(
				userPath: "/Users/test/Other/Views/File.swift",
				sourceRoot: root,
				visibleRoots: [root]
			)
			XCTFail("Expected destination outside root error")
		} catch let error as MovePathResolver.Error {
			switch error {
			case .destinationOutsideRoot(let errRoot):
				XCTAssertEqual(errRoot, root)
			default:
				XCTFail("Unexpected error: \(error)")
			}
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
}
