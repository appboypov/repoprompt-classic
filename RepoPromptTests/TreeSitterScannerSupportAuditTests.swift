import CryptoKit
import Foundation
import XCTest

final class TreeSitterScannerSupportAuditTests: XCTestCase {
	private let supportRelativePath = "RepoPrompt/Support/C/TreeSitterScannerSupport"
	private let expectedChecksums = [
		"include/tree_sitter/alloc.h": "b29c1c9fb7cc82f58c84b376df1297d6e2737a1d655fd356db0859e3c29c2fea",
		"include/tree_sitter/array.h": "5bdf6ed1a78e3409fd443e085ca967a64c188a5d082aaf7f819bccd53a471c94",
		"include/tree_sitter/parser.h": "a1f6ef161fbaf48a0e10fca90ef5290a062462b307b3898aa562993853b9f80a",
		"src/javascript/scanner.c": "b3d3f64284d97bf80749c026862427782cf7ecc0b7dc094e6698ab311c9a42c7",
		"src/python/scanner.c": "e5e9958cff80e077dc96faa59f7c001117804ace6dceacf9a6f5d55b1536171a",
	]

	func testScannerSupportLayoutAndChecksumsRemainNarrow() throws {
		let rootURL = repositoryRootURL
		let supportURL = rootURL.appendingPathComponent(supportRelativePath, isDirectory: true)
		let actualFiles = try regularFiles(relativeTo: supportURL)

		XCTAssertEqual(actualFiles, Set(expectedChecksums.keys), "Scanner support must contain only the two missing scanners and their helper headers")

		for (relativePath, expectedChecksum) in expectedChecksums {
			let data = try Data(contentsOf: supportURL.appendingPathComponent(relativePath))
			XCTAssertEqual(sha256(data), expectedChecksum, "Unexpected scanner-support drift in \(relativePath)")
		}

		let manifestURL = rootURL.appendingPathComponent("ThirdPartyLicenses/tree-sitter/scanner-support.sha256")
		let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
		XCTAssertEqual(manifest, expectedManifest)

		let retiredGrammarURL = rootURL.appendingPathComponent("RepoPrompt/Infrastructure/SyntaxParsing/Grammars")
		XCTAssertFalse(FileManager.default.fileExists(atPath: retiredGrammarURL.path), "Retired local generated grammar parsers must not reappear")
	}

	private var repositoryRootURL: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}

	private var expectedManifest: String {
		[
			"include/tree_sitter/alloc.h",
			"include/tree_sitter/array.h",
			"include/tree_sitter/parser.h",
			"src/javascript/scanner.c",
			"src/python/scanner.c",
		]
		.map { relativePath in
			"\(expectedChecksums[relativePath]!)  \(supportRelativePath)/\(relativePath)"
		}
		.joined(separator: "\n") + "\n"
	}

	private func regularFiles(relativeTo rootURL: URL) throws -> Set<String> {
		guard let enumerator = FileManager.default.enumerator(
			at: rootURL,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else {
			XCTFail("Missing scanner-support directory at \(rootURL.path)")
			return []
		}

		var files = Set<String>()
		for case let fileURL as URL in enumerator {
			let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
			guard values.isRegularFile == true else { continue }
			files.insert(String(fileURL.path.dropFirst(rootURL.path.count + 1)))
		}
		return files
	}

	private func sha256(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}
