import XCTest
@testable import RepoPrompt

final class CreatePathPreflightTests: XCTestCase {
	private func makeRoot(id: UUID = UUID(), name: String, fullPath: String) -> CreatePathPreflight.Root {
		CreatePathPreflight.Root(id: id, name: name, fullPath: fullPath)
	}
	
	func testEmptyPathThrows() {
		do {
			_ = try CreatePathPreflight.validate(userPath: "  \n\t ", visibleRoots: [])
			XCTFail("Expected empty path error")
		} catch let error as CreatePathPreflight.Error {
			XCTAssertEqual(error, .emptyPath)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
	
	func testAbsolutePathSkipsAliasChecks() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try CreatePathPreflight.validate(
			userPath: "/Users/test/RepoPrompt/Views/File.swift",
			visibleRoots: [root]
		)
		XCTAssertTrue(result.isAbsolute)
		XCTAssertEqual(result.normalizedPath, "/Users/test/RepoPrompt/Views/File.swift")
		if case .notPrefixed = result.aliasCheck {
			// ok
		} else {
			XCTFail("Expected notPrefixed for absolute paths")
		}
	}
	
	func testRelativePathSingleRootNoAliasOk() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try CreatePathPreflight.validate(
			userPath: "Views/File.swift",
			visibleRoots: [root]
		)
		XCTAssertFalse(result.isAbsolute)
		XCTAssertEqual(result.normalizedPath, "Views/File.swift")
		if case .notPrefixed = result.aliasCheck {
			// ok
		} else {
			XCTFail("Expected notPrefixed for single root relative path")
		}
	}
	
	func testRelativePathMultiRootRequiresAlias() {
		let rootA = makeRoot(name: "AppA", fullPath: "/Users/test/AppA")
		let rootB = makeRoot(name: "AppB", fullPath: "/Users/test/AppB")
		do {
			_ = try CreatePathPreflight.validate(userPath: "Views/File.swift", visibleRoots: [rootA, rootB])
			XCTFail("Expected missing alias error")
		} catch let error as CreatePathPreflight.Error {
			switch error {
			case .missingAliasWithMultipleRoots(let loadedRoots):
				XCTAssertEqual(Set(loadedRoots), Set([rootA, rootB]))
			default:
				XCTFail("Unexpected error: \(error)")
			}
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
	
	func testAliasPrefixedResolvesUniqueRoot() throws {
		let root = makeRoot(name: "RepoPrompt", fullPath: "/Users/test/RepoPrompt")
		let result = try CreatePathPreflight.validate(
			userPath: "RepoPrompt/Views/File.swift",
			visibleRoots: [root]
		)
		if case .uniqueRoot(let resolvedRoot, let alias) = result.aliasCheck {
			XCTAssertEqual(resolvedRoot, root)
			XCTAssertEqual(alias, "RepoPrompt")
		} else {
			XCTFail("Expected uniqueRoot alias resolution")
		}
	}
	
	func testAliasPrefixedUsesLastPathComponentFallback() throws {
		let root = makeRoot(name: "Workspace", fullPath: "/Users/test/BombSquad")
		let result = try CreatePathPreflight.validate(
			userPath: "BombSquad/src/File.swift",
			visibleRoots: [root]
		)
		if case .uniqueRoot(let resolvedRoot, let alias) = result.aliasCheck {
			XCTAssertEqual(resolvedRoot, root)
			XCTAssertEqual(alias, "BombSquad")
		} else {
			XCTFail("Expected uniqueRoot alias resolution")
		}
	}

	func testAliasPrefixedUsesStandardizedLastPathComponentFallback() throws {
		let root = makeRoot(name: "Workspace", fullPath: "/Users/test/BombSquad/./src/..")
		let result = try CreatePathPreflight.validate(
			userPath: "BombSquad/src/File.swift",
			visibleRoots: [root]
		)
		if case .uniqueRoot(let resolvedRoot, let alias) = result.aliasCheck {
			XCTAssertEqual(resolvedRoot, root)
			XCTAssertEqual(alias, "BombSquad")
		} else {
			XCTFail("Expected uniqueRoot alias resolution")
		}
	}

	func testAliasPrefixedStillResolvesWhenSameNameSubfolderExists() throws {
		let root = makeRoot(name: "BombSquad", fullPath: "/Users/test/BombSquad")
		let result = try CreatePathPreflight.validate(
			userPath: "BombSquad/src/File.swift",
			visibleRoots: [root]
		)
		if case .uniqueRoot(let resolvedRoot, let alias) = result.aliasCheck {
			XCTAssertEqual(resolvedRoot, root)
			XCTAssertEqual(alias, "BombSquad")
		} else {
			XCTFail("Expected uniqueRoot alias resolution even when a same-name subfolder exists")
		}
	}
	
	func testAmbiguousAliasThrows() {
		let rootA = makeRoot(id: UUID(), name: "App", fullPath: "/Users/test/AppA")
		let rootB = makeRoot(id: UUID(), name: "App", fullPath: "/Users/test/AppB")
		do {
			_ = try CreatePathPreflight.validate(userPath: "App/Views/File.swift", visibleRoots: [rootA, rootB])
			XCTFail("Expected ambiguous alias error")
		} catch let error as CreatePathPreflight.Error {
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
}
