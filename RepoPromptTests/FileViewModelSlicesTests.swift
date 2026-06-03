import XCTest
@testable import RepoPrompt

final class FileViewModelSlicesTests: XCTestCase {
	func testFullFileAssemblyWhenRangesNil() {
		let content = """
		line 1
		line 2
		line 3
		"""
		
		let assembly = FileViewModel.buildSliceAssembly(from: content + "\n", ranges: nil)
		
		XCTAssertTrue(assembly.isFullFile)
		XCTAssertEqual(assembly.totalLines, 3)
		XCTAssertEqual(assembly.segments.count, 1)
		XCTAssertEqual(assembly.segments.first?.range, LineRange(start: 1, end: 3))
		XCTAssertEqual(assembly.segments.first?.text, content + "\n")
	}
	
	func testAssemblyUsesRequestedRange() {
		let content = """
		l1
		l2
		l3
		l4
		"""
		
		let assembly = FileViewModel.buildSliceAssembly(from: content, ranges: [LineRange(start: 2, end: 3)])
		
		XCTAssertFalse(assembly.isFullFile)
		XCTAssertEqual(assembly.usedRanges, [LineRange(start: 2, end: 3)])
		XCTAssertEqual(assembly.segments.count, 1)
		XCTAssertEqual(assembly.segments.first?.text, "l2\nl3\n")
		XCTAssertEqual(assembly.combinedText, "l2\nl3\n")
	}
	
	func testOverlappingRangesAreMerged() {
		let content = """
		a
		b
		c
		d
		e
		"""
		
		let ranges = [
			LineRange(start: 2, end: 4),
			LineRange(start: 3, end: 5)
		]
		
		let assembly = FileViewModel.buildSliceAssembly(from: content, ranges: ranges)
		
		XCTAssertFalse(assembly.isFullFile)
		XCTAssertEqual(assembly.usedRanges, [LineRange(start: 2, end: 5)])
		XCTAssertEqual(assembly.segments.count, 1)
		XCTAssertEqual(assembly.segments.first?.text, "b\nc\nd\ne")
	}
	
	func testOutOfBoundsRangesClampToFile() {
		let content = """
		one
		two
		three
		four
		five
		"""
		
		let assembly = FileViewModel.buildSliceAssembly(from: content, ranges: [LineRange(start: 4, end: 10)])
		
		XCTAssertFalse(assembly.isFullFile)
		XCTAssertEqual(assembly.usedRanges, [LineRange(start: 4, end: 5)])
		XCTAssertEqual(assembly.segments.first?.text, "four\nfive")
	}
	
	func testInvalidRangesFallbackToFullFile() {
		let content = """
		only line
		"""
		
		let assembly = FileViewModel.buildSliceAssembly(from: content, ranges: [LineRange(start: 10, end: 12)])
		
		XCTAssertTrue(assembly.isFullFile)
		XCTAssertEqual(assembly.segments.first?.text, content)
	}
	
	func testAdjacentRangesAreMerged() {
		let content = """
		aa
		bb
		cc
		dd
		"""
		
		let ranges = [
			LineRange(start: 2, end: 3),
			LineRange(start: 4, end: 4)
		]
		
		let assembly = FileViewModel.buildSliceAssembly(from: content, ranges: ranges)
		
		XCTAssertEqual(assembly.usedRanges, [LineRange(start: 2, end: 4)])
		XCTAssertEqual(assembly.segments.count, 1)
		XCTAssertFalse(assembly.isFullFile)
		XCTAssertEqual(assembly.segments.first?.text, "bb\ncc\ndd")
	}
}
