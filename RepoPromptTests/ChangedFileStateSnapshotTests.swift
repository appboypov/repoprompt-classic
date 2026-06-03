import XCTest
@testable import RepoPrompt

@MainActor
final class ChangedFileStateSnapshotTests: XCTestCase {
	func testMakeStateSnapshotPreservesSavedContentLineEndingsAfterAppliedChange() async {
		let file = await makeChangedFileWithAppliedEdit()
		let snapshot = file.makeStateSnapshot()
		let expected = "alpha\r\nbeta updated\r\n"
		let naiveJoinedContent = file.fileContent.joined(separator: "\n")
		
		XCTAssertEqual(file.getContentForSaving(), expected)
		XCTAssertEqual(snapshot.finalContent, expected)
		XCTAssertEqual(snapshot.relativePath, "test.txt")
		XCTAssertEqual(snapshot.action, FileAction.modify.rawValue)
		XCTAssertEqual(snapshot.acceptedChanges, [file.changes[0].id])
		XCTAssertEqual(snapshot.acceptedContentKeys, [file.changes[0].contentKey])
		XCTAssertNotEqual(snapshot.finalContent, naiveJoinedContent)
	}
	
	func testAIResponseViewModelProduceChangedFileStatesUsesSavedContentSnapshot() async {
		let fileManager = RepoFileManagerViewModel()
		let viewModel = AIResponseViewModel(fileManager: fileManager)
		let file = await makeChangedFileWithAppliedEdit()
		let expected = "alpha\r\nbeta updated\r\n"
		
		viewModel.updateResponses([file])
		let states = viewModel.produceChangedFileStates()
		
		XCTAssertEqual(states.count, 1)
		XCTAssertEqual(states[0].finalContent, expected)
		XCTAssertEqual(states[0].acceptedContentKeys, [file.changes[0].contentKey])
		XCTAssertNotEqual(states[0].finalContent, file.fileContent.joined(separator: "\n"))
	}
	
	func testMakeStateSnapshotPreservesSavedContentForDelegateEditAction() async {
		let file = await makeChangedFileWithAppliedEdit(fileAction: .delegateEdit)
		let snapshot = file.makeStateSnapshot()
		let expected = "alpha\r\nbeta updated\r\n"
		
		XCTAssertEqual(snapshot.action, FileAction.delegateEdit.rawValue)
		XCTAssertEqual(snapshot.finalContent, expected)
		XCTAssertEqual(snapshot.acceptedContentKeys, [file.changes[0].contentKey])
	}
	
	private func makeChangedFileWithAppliedEdit(fileAction: FileAction = .modify) async -> ChangedFile {
		let change = FileChange(
			startLine: 1,
			description: "Update beta line",
			diffChunk: DiffChunk(
				lines: [
					DiffLine(content: "-beta"),
					DiffLine(content: "+beta updated")
				],
				startLine: 1
			)
		)
		let file = ChangedFile(
			relativePath: "test.txt",
			fileContent: "alpha\r\nbeta\r\n",
			changes: [change],
			fileAction: fileAction
		)
		
		await file.applyChange(change)
		return file
	}
}
