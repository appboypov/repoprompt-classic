//
//  FolderViewModelBatchInsertionTests.swift
//  RepoPromptTests
//

import Cocoa
import XCTest
@testable import RepoPrompt

@MainActor
final class FolderViewModelBatchInsertionTests: XCTestCase {
	private struct TestContext {
		let rootURL: URL
		let root: FolderViewModel
		let service: FileSystemService
	}

	private func makeContext(sortMethod: SortMethod = .nameAscending) async throws -> TestContext {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FolderViewModelBatchInsertionTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let root = FolderViewModel(
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			sortMethod: sortMethod
		)
		return TestContext(rootURL: rootURL, root: root, service: service)
	}

	private func makeFile(
		_ name: String,
		in context: TestContext,
		folderName: String? = nil,
		modificationDate: Date = Date()
	) -> FileViewModel {
		let parentURL = folderName.map { context.rootURL.appendingPathComponent($0, isDirectory: true) } ?? context.rootURL
		return FileViewModel(
			file: File(
				name: name,
				path: parentURL.appendingPathComponent(name).path,
				modificationDate: modificationDate
			),
			rootPath: context.rootURL.path,
			hierarchyLevel: folderName == nil ? 1 : 2,
			rootIdentifier: context.root.id,
			rootFolderPath: context.root.fullPath,
			fileSystemService: context.service
		)
	}

	private func makeFolder(
		_ name: String,
		in context: TestContext,
		modificationDate: Date = Date(),
		isExpanded: Bool = true
	) -> FolderViewModel {
		FolderViewModel(
			folder: Folder(
				name: name,
				path: context.rootURL.appendingPathComponent(name, isDirectory: true).path,
				modificationDate: modificationDate
			),
			rootPath: context.rootURL.path,
			hierarchyLevel: 1,
			isExpanded: isExpanded
		)
	}

	private func childNames(of folder: FolderViewModel) -> [String] {
		childNames(of: folder.children)
	}

	private func childNames(of children: [FileSystemItemType]) -> [String] {
		children.map { child in
			switch child {
			case .folder(let folder): folder.name
			case .file(let file): file.name
			}
		}
	}

	private func visibleOutlineNames(in controller: FileTreeViewController) -> [String] {
		(0..<controller.outlineView.numberOfRows).compactMap { row in
			guard let item = controller.outlineView.item(atRow: row) as? FileSystemItemType else { return nil }
			switch item {
			case .folder(let folder): return folder.name
			case .file(let file): return file.name
			}
		}
	}

	func testEmptyParentFileBatchSortsFilesAndAssignsParents() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let files = ["zeta.swift", "alpha.swift", "middle.swift"].map { makeFile($0, in: context) }

		context.root.addChildrenBatch(files.map(FileSystemItemType.file), recomputeCheckbox: true)

		XCTAssertEqual(context.root.files.map(\.name), ["alpha.swift", "middle.swift", "zeta.swift"])
		XCTAssertEqual(childNames(of: context.root), ["alpha.swift", "middle.swift", "zeta.swift"])
		XCTAssertEqual(Set(context.root.children.map(\.id)).count, context.root.children.count)
		for file in files {
			XCTAssertTrue(file.parentFolder === context.root)
		}
	}

	func testNonEmptyParentMergePlacesNewFilesBeforeBetweenAndAfterExistingExactlyOnce() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let existing = ["bravo.swift", "delta.swift"].map { makeFile($0, in: context) }
		context.root.addChildrenBatch(existing.map(FileSystemItemType.file), recomputeCheckbox: true)
		let inserted = ["echo.swift", "alpha.swift", "charlie.swift"].map { makeFile($0, in: context) }

		context.root.addChildrenBatch(inserted.map(FileSystemItemType.file), recomputeCheckbox: true)

		let expected = ["alpha.swift", "bravo.swift", "charlie.swift", "delta.swift", "echo.swift"]
		XCTAssertEqual(context.root.files.map(\.name), expected)
		XCTAssertEqual(childNames(of: context.root), expected)
		XCTAssertEqual(Set(context.root.children.map(\.id)).count, expected.count)
		for name in expected {
			XCTAssertEqual(context.root.files.filter { $0.name == name }.count, 1)
		}
		for file in existing + inserted {
			XCTAssertTrue(file.parentFolder === context.root)
		}
	}

	func testMixedFolderAndFileBatchSortsWithinKindsAndPublishesFoldersFirst() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let folders = ["Sources", "Assets"].map { makeFolder($0, in: context) }
		let files = ["zeta.swift", "alpha.swift"].map { makeFile($0, in: context) }
		let children: [FileSystemItemType] = [
			.folder(folders[0]),
			.file(files[0]),
			.folder(folders[1]),
			.file(files[1])
		]

		context.root.addChildrenBatch(children, recomputeCheckbox: true)

		XCTAssertEqual(context.root.subfolders.map(\.name), ["Assets", "Sources"])
		XCTAssertEqual(context.root.files.map(\.name), ["alpha.swift", "zeta.swift"])
		XCTAssertEqual(childNames(of: context.root), ["Assets", "Sources", "alpha.swift", "zeta.swift"])
		for folder in folders {
			XCTAssertTrue(folder.parent === context.root)
		}
		for file in files {
			XCTAssertTrue(file.parentFolder === context.root)
		}
	}

	func testBatchInsertionUpdatesCheckboxMetricsForPrecheckedFiles() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let checked = makeFile("checked.swift", in: context)
		let unchecked = makeFile("unchecked.swift", in: context)
		checked.setIsChecked(true)

		context.root.addChildrenBatch([.file(unchecked), .file(checked)], recomputeCheckbox: true)

		XCTAssertEqual(context.root.checkboxState, .mixed)
		XCTAssertTrue(checked.parentFolder === context.root)
		XCTAssertTrue(unchecked.parentFolder === context.root)
	}

	func testDateSortedNonEmptyParentMergePreservesDateOrdering() async throws {
		let context = try await makeContext(sortMethod: .dateNewest)
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
		let existing = [
			makeFile("middle.swift", in: context, modificationDate: baseDate.addingTimeInterval(100)),
			makeFile("old.swift", in: context, modificationDate: baseDate)
		]
		context.root.addChildrenBatch(existing.map(FileSystemItemType.file), recomputeCheckbox: true)
		let inserted = [
			makeFile("between.swift", in: context, modificationDate: baseDate.addingTimeInterval(150)),
			makeFile("newest.swift", in: context, modificationDate: baseDate.addingTimeInterval(200))
		]

		context.root.addChildrenBatch(inserted.map(FileSystemItemType.file), recomputeCheckbox: true)

		let expected = ["newest.swift", "between.swift", "middle.swift", "old.swift"]
		XCTAssertEqual(context.root.files.map(\.name), expected)
		XCTAssertEqual(childNames(of: context.root), expected)
		for file in existing + inserted {
			XCTAssertTrue(file.parentFolder === context.root)
		}
	}

	func testUnsortedBatchSortsOnDemandWithoutCheckboxRecompute() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let sources = makeFolder("Sources", in: context)
		let assets = makeFolder("Assets", in: context)
		let zeta = makeFile("zeta.swift", in: context)
		let alpha = makeFile("alpha.swift", in: context)

		context.root.addChildrenBatch(
			[.folder(sources), .folder(assets), .file(zeta), .file(alpha)],
			options: .init(
				recomputeCheckbox: false,
				ensureSorted: false,
				rebuildChildren: true,
				assumeAllUnchecked: true
			)
		)

		XCTAssertEqual(childNames(of: context.root), ["Sources", "Assets", "zeta.swift", "alpha.swift"])

		context.root.sortChildrenIfNeeded(
			.nameAscending,
			recomputeCheckbox: false,
			recursion: .depth(0)
		)

		XCTAssertEqual(childNames(of: context.root), ["Assets", "Sources", "alpha.swift", "zeta.swift"])
	}

	func testIDENativeSnapshotUsesConfiguredNonDefaultSortMethodForDirtyRootChildren() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
		let oldFile = makeFile("old.swift", in: context, modificationDate: baseDate)
		let newFile = makeFile("new.swift", in: context, modificationDate: baseDate.addingTimeInterval(100))

		context.root.addChildrenBatch(
			[.file(oldFile), .file(newFile)],
			options: .init(
				recomputeCheckbox: false,
				ensureSorted: false,
				rebuildChildren: true,
				assumeAllUnchecked: true
			)
		)

		let controller = FileTreeViewController()
		controller.loadViewIfNeeded()
		controller.localRoots = [context.root]
		controller._setSnapshotSortMethodForTesting(.dateNewest)
		controller.premarkExpandedBranch(for: context.root)
		controller.applyNewSnapshot(suppressExpansionSync: true)

		XCTAssertEqual(childNames(of: controller.snapshotChildren(of: context.root)), ["new.swift", "old.swift"])
	}

	func testIDENativeSnapshotReloadsRenderedBranchWhenSameChildrenReorder() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
		let alpha = makeFile("alpha.swift", in: context, modificationDate: baseDate)
		let zeta = makeFile("zeta.swift", in: context, modificationDate: baseDate.addingTimeInterval(100))

		context.root.addChildrenBatch(
			[.file(alpha), .file(zeta)],
			options: .init(
				recomputeCheckbox: false,
				ensureSorted: false,
				rebuildChildren: true,
				assumeAllUnchecked: true
			)
		)

		let controller = FileTreeViewController()
		controller.loadViewIfNeeded()
		controller.outlineView.dataSource = controller
		controller.localRoots = [context.root]
		controller._setSnapshotSortMethodForTesting(.nameAscending)
		controller.premarkExpandedBranch(for: context.root)
		controller.applyNewSnapshot(suppressExpansionSync: true)

		let rootItem = try XCTUnwrap(controller.snapshotRootItems().first)
		controller.outlineView.expandItem(rootItem)
		XCTAssertEqual(visibleOutlineNames(in: controller), [context.root.name, "alpha.swift", "zeta.swift"])

		controller._setSnapshotSortMethodForTesting(.dateNewest)
		controller.applyNewSnapshot(suppressExpansionSync: true)

		XCTAssertEqual(childNames(of: controller.snapshotChildren(of: context.root)), ["zeta.swift", "alpha.swift"])
		XCTAssertEqual(visibleOutlineNames(in: controller), [context.root.name, "zeta.swift", "alpha.swift"])
	}

	func testIDENativeSnapshotSortsDirtyVisibleBranchesAndLeavesCollapsedBranchesUnsorted() async throws {
		let context = try await makeContext()
		defer { try? FileManager.default.removeItem(at: context.rootURL) }
		let expandedFolder = makeFolder("Expanded", in: context, isExpanded: true)
		let collapsedFolder = makeFolder("Collapsed", in: context, isExpanded: false)

		expandedFolder.addChildrenBatch(
			[
				.file(makeFile("zeta.swift", in: context, folderName: expandedFolder.name)),
				.file(makeFile("alpha.swift", in: context, folderName: expandedFolder.name))
			],
			options: .init(
				recomputeCheckbox: false,
				ensureSorted: false,
				rebuildChildren: true,
				assumeAllUnchecked: true
			)
		)
		collapsedFolder.addChildrenBatch(
			[
				.file(makeFile("delta.swift", in: context, folderName: collapsedFolder.name)),
				.file(makeFile("charlie.swift", in: context, folderName: collapsedFolder.name))
			],
			options: .init(
				recomputeCheckbox: false,
				ensureSorted: false,
				rebuildChildren: true,
				assumeAllUnchecked: true
			)
		)
		context.root.addChildrenBatch(
			[.folder(expandedFolder), .folder(collapsedFolder)],
			options: .init(
				recomputeCheckbox: false,
				ensureSorted: false,
				rebuildChildren: true,
				assumeAllUnchecked: true
			)
		)

		let controller = FileTreeViewController()
		controller.loadViewIfNeeded()
		controller.localRoots = [context.root]
		controller.premarkExpandedBranch(for: context.root)
		controller.applyNewSnapshot(suppressExpansionSync: true)

		XCTAssertEqual(childNames(of: controller.snapshotChildren(of: context.root)), ["Collapsed", "Expanded"])
		XCTAssertEqual(childNames(of: controller.snapshotChildren(of: expandedFolder)), ["alpha.swift", "zeta.swift"])
		XCTAssertEqual(controller.snapshotChildren(of: collapsedFolder), [])
		XCTAssertEqual(childNames(of: collapsedFolder), ["delta.swift", "charlie.swift"])
	}
}
