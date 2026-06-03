
/*
import XCTest
@testable import RepoPrompt

class ChangedFileAndParserTests: XCTestCase {
	
	let piJSContent = """
	// PI Calculator Web JS
	// Calculating Pi number without limitation until 10k digits or more in your browser powered by JS without any third party library!
	// https://github.com/BaseMax/PiCalculatorWebJS
	
	const base = Math.pow(10, 11)
	const cell_size = Math.floor(Math.log(base) / Math.LN10)
	
	const digits = (count, array, first_value) => {
		for(let i = 1; i < count; i++)
			array[i] = null
		array[0] = first_value
	}
	
	const is_empty = (array) => {
		for(i = 0; i < array.length; i++)
			if(array[i])
				return false
		return true
	}
	
	const add = (n, array1, array2) => {
		let carry = 0
	
		for(let i = n - 1; i >= 0; i--) {
			array1[i] += array2[i] + carry
			if(array1[i] < base)
				carry = 0
			else {
				carry = 1
				array1[i] = array1[i] - base
			}
		}
	}
	
	const sub = (n, array1, array2) => {
		for(let i = n - 1; i >= 0; i--) {
			array1[i] -= array2[i]
			if(array1[i] < 0) {
				if(i > 0) {
					array1[i] += base
					array1[i - 1]--
				}
			}
		}
	}
	
	const mul = (n, array1, number) => {
		let carry = 0
	
		for(let i = n - 1; i >= 0; i--) {
			product = (array1[i]) * number
			product += carry
			if(product >= base) {
				carry = Math.floor(product / base)
				product -= (carry * base)
			}
			else
				carry = 0
			array1[i] = product
		}
	}
	
	const div = (n, array1, number, array2) => {
		carry = 0
		for(let i = 0; i < n; i++) {
			const value = array1[i] + (carry * base)
			const temp = Math.floor(value / number)
			carry = value - temp * number
			array2[i] = temp
		}
	}
	
	const arctan = (angle, n, array) => {
		const angles = []
		const adivK = []
		const angle_square = angle * angle
	
		let k = 3
		let sign = 0
	
		digits(n, array, 0)
		digits(n, angles, 1)
	
		div(n, angles, angle, angles)
		add(n, array, angles)
	
		while(!is_empty(angles)) {
			div(n, angles, angle_square, angles)
			div(n, angles, k, adivK)
	
			if(sign)
				add(n, array, adivK)
			else
				sub(n, array, adivK)
	
			k += 2
			sign = 1 - sign
		}
	}
	
	const calculate = (digit_number) => {
		digit_number = +digit_number + 5
	
		const time_start = new Date()
		const angle = [5, 239, 0]
		const coeff = [4, -1, 0]
		const len = Math.ceil(1 + digit_number / cell_size)
	
		const pi_digits = []
		const arctans = []
	
		digits(len, pi_digits, 0)
	
		for(var i = 0; coeff[i] != 0; i++) {
			arctan(angle[i], len, arctans)
			mul(len, arctans, Math.abs(coeff[i]))
			if(coeff[i] > 0)
				add(len, pi_digits, arctans)
			else
				sub(len, pi_digits, arctans)
		}
	
		mul(len, pi_digits, 4)
	
		let pi = ""
		for(i = 0; i < pi_digits.length; i++) {
			if(pi_digits[i].length < cell_size && i != 0)
				while(pi_digits[i].length < cell_size)
					pi_digits[i] = "0" + pi_digits[i]
			pi += pi_digits[i]
		}
	
		const time_end = new Date()
		const time_taken = (time_end.getTime() - time_start.getTime()) / 1000
	
		// console.warn(pi.startsWith("31415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679821480865"))
		// console.log("PI (" + digit_number + ") = " + pi + "\\n" + "It took: " + time_taken + " seconds\\n")
	
		return {
			digits: digit_number,
			pi: pi,
			time: time_taken // in seconds
		};
	}
	"""
	
	func testPiJSDiffApplicationAndParsing() {
		let aiMessage = """
		Based on the user instructions to delete the add method and refactor the mul method to make it simpler, I'll provide the necessary changes in the requested JSON format.
		###JSON_START###
		{
		  "file_path": "pi.js",
		  "changes": [
			{
			  "description": "Delete the add method",
			  "start_line": 19,
			  "chunk": [
				" }",
				" ",
				"-const add = (n, array1, array2) => {",
				"-    let carry = 0",
				"-",
				"-    for(let i = n - 1; i >= 0; i--) {",
				"-        array1[i] += array2[i] + carry",
				"-        if(array1[i] < base)",
				"-            carry = 0",
				"-        else {",
				"-            carry = 1",
				"-            array1[i] = array1[i] - base",
				"-        }",
				"-    }",
				"-}",
				" "
			  ]
			},
			{
			  "description": "Refactor the mul method to make it simpler",
			  "start_line": 47,
			  "chunk": [
				" const mul = (n, array1, number) => {",
				"-    let carry = 0",
				"-",
				"-    for(let i = n - 1; i >= 0; i--) {",
				"-        product = (array1[i]) * number",
				"-        product += carry",
				"-        if(product >= base) {",
				"-            carry = Math.floor(product / base)",
				"-            product -= (carry * base)",
				"-        }",
				"-        else",
				"-            carry = 0",
				"-        array1[i] = product",
				"-    }",
				"+    for(let i = n - 1; i >= 0; i--) {",
				"+        const product = array1[i] * number",
				"+        array1[i] = product % base",
				"+        if (i > 0) {",
				"+            array1[i - 1] += Math.floor(product / base)",
				"+        }",
				"+    }",
				" }"
			  ]
			}
		  ]
		}
		###JSON_END###
		###JSON_START###
		{
		  "overall_summary": "Deleted the add method and simplified the mul method by removing the carry variable and using a more concise approach for multiplication and handling overflow."
		}
		###JSON_END###
		"""
		
		let expectedOutput = """
		// PI Calculator Web JS
		// Calculating Pi number without limitation until 10k digits or more in your browser powered by JS without any third party library!
		// https://github.com/BaseMax/PiCalculatorWebJS
		
		const base = Math.pow(10, 11)
		const cell_size = Math.floor(Math.log(base) / Math.LN10)
		
		const digits = (count, array, first_value) => {
			for(let i = 1; i < count; i++)
				array[i] = null
			array[0] = first_value
		}
		
		const is_empty = (array) => {
			for(i = 0; i < array.length; i++)
				if(array[i])
					return false
			return true
		}
		
		const sub = (n, array1, array2) => {
			for(let i = n - 1; i >= 0; i--) {
				array1[i] -= array2[i]
				if(array1[i] < 0) {
					if(i > 0) {
						array1[i] += base
						array1[i - 1]--
					}
				}
			}
		}
		
		const mul = (n, array1, number) => {
			for(let i = n - 1; i >= 0; i--) {
				const product = array1[i] * number
				array1[i] = product % base
				if (i > 0) {
					array1[i - 1] += Math.floor(product / base)
				}
			}
		}
		
		const div = (n, array1, number, array2) => {
			carry = 0
			for(let i = 0; i < n; i++) {
				const value = array1[i] + (carry * base)
				const temp = Math.floor(value / number)
				carry = value - temp * number
				array2[i] = temp
			}
		}
		
		const arctan = (angle, n, array) => {
			const angles = []
			const adivK = []
			const angle_square = angle * angle
		
			let k = 3
			let sign = 0
		
			digits(n, array, 0)
			digits(n, angles, 1)
		
			div(n, angles, angle, angles)
			add(n, array, angles)
		
			while(!is_empty(angles)) {
				div(n, angles, angle_square, angles)
				div(n, angles, k, adivK)
		
				if(sign)
					add(n, array, adivK)
				else
					sub(n, array, adivK)
		
				k += 2
				sign = 1 - sign
			}
		}
		
		const calculate = (digit_number) => {
			digit_number = +digit_number + 5
		
			const time_start = new Date()
			const angle = [5, 239, 0]
			const coeff = [4, -1, 0]
			const len = Math.ceil(1 + digit_number / cell_size)
		
			const pi_digits = []
			const arctans = []
		
			digits(len, pi_digits, 0)
		
			for(var i = 0; coeff[i] != 0; i++) {
				arctan(angle[i], len, arctans)
				mul(len, arctans, Math.abs(coeff[i]))
				if(coeff[i] > 0)
					add(len, pi_digits, arctans)
				else
					sub(len, pi_digits, arctans)
			}
		
			mul(len, pi_digits, 4)
		
			let pi = ""
			for(i = 0; i < pi_digits.length; i++) {
				if(pi_digits[i].length < cell_size && i != 0)
					while(pi_digits[i].length < cell_size)
						pi_digits[i] = "0" + pi_digits[i]
				pi += pi_digits[i]
			}
		
			const time_end = new Date()
			const time_taken = (time_end.getTime() - time_start.getTime()) / 1000
		
			// console.warn(pi.startsWith("31415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679821480865"))
			// console.log("PI (" + digit_number + ") = " + pi + "\\n" + "It took: " + time_taken + " seconds\\n")
		
			return {
				digits: digit_number,
				pi: pi,
				time: time_taken // in seconds
			};
		}
		"""
		
		runTest(name: "Pi.js Diff Application and Parsing", initialContent: piJSContent, aiMessage: aiMessage, expectedOutput: expectedOutput)
	}
	
	func testPartialApplication() {
		let partialAiMessage = """
		###JSON_START###
		{
		  "file_path": "pi.js",
		  "changes": [
			{
			  "description": "Delete the add method",
			  "start_line": 19,
			  "chunk": [
				" }",
				" ",
				"-const add = (n, array1, array2) => {",
				"-    let carry = 0",
				"-",
				"-    for(let i = n - 1; i >= 0; i--) {",
				"-        array1[i] += array2[i] + carry",
				"-        if(array1[i] < base)",
				"-            carry = 0",
				"-        else {",
				"-            carry = 1",
				"-            array1[i] = array1[i] - base",
				"-        }",
				"-    }",
				"-}",
				" "
			  ]
			}
		  ]
		}
		###JSON_END###
		"""
		
		let expectedOutput = piJSContent.replacingOccurrences(of: """
		const add = (n, array1, array2) => {
			let carry = 0
		
			for(let i = n - 1; i >= 0; i--) {
				array1[i] += array2[i] + carry
				if(array1[i] < base)
					carry = 0
				else {
					carry = 1
					array1[i] = array1[i] - base
				}
			}
		}
		""", with: "")
		
		runTest(name: "Partial Application", initialContent: piJSContent, aiMessage: partialAiMessage, expectedOutput: expectedOutput)
	}
	
	func testChangesNearFileStart() {
		let nearStartMessage = """
		###JSON_START###
		{
		  "file_path": "pi.js",
		  "changes": [
			{
			  "description": "Add comment at the start of the file",
			  "start_line": 1,
			  "chunk": [
				"+// This is a new comment at the start of the file",
				" // PI Calculator Web JS"
			  ]
			}
		  ]
		}
		###JSON_END###
		"""
		
		let expectedOutput = "// This is a new comment at the start of the file\n" + piJSContent
		
		runTest(name: "Changes Near File Start", initialContent: piJSContent, aiMessage: nearStartMessage, expectedOutput: expectedOutput)
	}
	
	func testChangesNearFileEnd() {
		let nearEndMessage = """
		###JSON_START###
		{
		  "file_path": "pi.js",
		  "changes": [
			{
			  "description": "Add comment at the end of the file",
			  "start_line": 144,
			  "chunk": [
				" }",
				"+",
				"+// This is a new comment at the end of the file"
			  ]
			}
		  ]
		}
		###JSON_END###
		"""
		
		let expectedOutput = piJSContent + "\n// This is a new comment at the end of the file"
		
		runTest(name: "Changes Near File End", initialContent: piJSContent, aiMessage: nearEndMessage, expectedOutput: expectedOutput)
	}
	
	func testOverlappingChanges() {
		let overlappingMessage = """
		###JSON_START###
		{
		  "file_path": "pi.js",
		  "changes": [
			{
			  "description": "Modify the mul function",
			  "start_line": 47,
			  "chunk": [
				" const mul = (n, array1, number) => {",
				"-    let carry = 0",
				"+    let tempCarry = 0",
				" "
			  ]
			},
			{
			  "description": "Further modify the mul function",
			  "start_line": 48,
			  "chunk": [
				"-    let tempCarry = 0",
				"-",
				"+    // This is a new comment",
				"     for(let i = n - 1; i >= 0; i--) {"
			  ]
			}
		  ]
		}
		###JSON_END###
		"""
		
		let expectedOutput = piJSContent.replacingOccurrences(of: """
		const mul = (n, array1, number) => {
			let carry = 0
		
			for(let i = n - 1; i >= 0; i--) {
		""", with: """
		const mul = (n, array1, number) => {
			// This is a new comment
			for(let i = n - 1; i >= 0; i--) {
		""")
		
		runTest(name: "Overlapping Changes", initialContent: piJSContent, aiMessage: overlappingMessage, expectedOutput: expectedOutput)
	}
	
	func testChangeRatioCalculation() {
		// Setup
		let initialContent = "Line 1\nLine 2\nLine 3"
		let change = FileChange(id: UUID(), startLine: 2, description: "Add a line", diffChunk: DiffChunk(lines: [DiffLine(content: "+New Line")]))
		
		let changedFile = ChangedFile(relativePath: "test.txt",
									  fileContent: initialContent.components(separatedBy: .newlines),
									  changes: [change])
		
		// Pre-change ratio
		XCTAssertEqual(changedFile.calculateChangeRatio(), 0.0, accuracy: 0.01)
		
		// Apply change
		changedFile.applyChange(change)
		
		// Post-change ratio
		XCTAssertEqual(changedFile.calculateChangeRatio(), 0.25, accuracy: 0.01)
	}
	
	func testChangeGroups() {
		// Setup
		let initialContent = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
		let change1 = FileChange(id: UUID(), startLine: 1, description: "Change 1", diffChunk: DiffChunk(lines: [DiffLine(content: "+New Line 1")]))
		let change2 = FileChange(id: UUID(), startLine: 2, description: "Change 2", diffChunk: DiffChunk(lines: [DiffLine(content: "+New Line 2")]))
		let change3 = FileChange(id: UUID(), startLine: 5, description: "Change 3", diffChunk: DiffChunk(lines: [DiffLine(content: "+New Line 3")]))
		
		let changedFile = ChangedFile(relativePath: "test.txt",
									  fileContent: initialContent.components(separatedBy: .newlines),
									  changes: [change1, change2, change3])
		
		let groups = changedFile.getChangeGroups()
		
		print("Number of groups: \(groups.count)")
		for (index, group) in groups.enumerated() {
			print("Group \(index + 1) has \(group.changes.count) changes")
			for change in group.changes {
				print("  - Change at line \(change.startLine): \(change.description)")
			}
		}
		
		XCTAssertGreaterThan(groups.count, 0, "There should be at least one group")
		if groups.count > 0 {
			XCTAssertGreaterThan(groups[0].changes.count, 0, "The first group should have at least one change")
		}
		if groups.count > 1 {
			XCTAssertGreaterThan(groups[1].changes.count, 0, "The second group should have at least one change")
		}
	}

	private func runTest(name: String, initialContent: String, aiMessage: String, expectedOutput: String) {
		print("\n--- Starting test: \(name) ---")
		
		do {
			let fileContent = initialContent.components(separatedBy: .newlines)
			print("Initial content lines: \(fileContent.count)")
			
			// Parse the AI message
			let parser = IncrementalJSONParser()
			let parseResult = parser.parse(aiMessage)
			
			guard let fileChanges = parseResult.responses?.first else {
				throw TestError.parsingFailed("Failed to parse file changes")
			}
			
			print("Parsed file changes: \(fileChanges.changes.count)")
			
			XCTAssertEqual(fileChanges.relativePath, "pi.js", "File path does not match")
			XCTAssertFalse(fileChanges.changes.isEmpty, "No changes parsed")
			
			let changedFile = ChangedFile(relativePath: fileChanges.relativePath, fileContent: fileContent, changes: fileChanges.changes)
			
			// Test applying changes
			print("\nApplying changes:")
			for (index, change) in fileChanges.changes.enumerated() {
				print("Applying change \(index + 1): \(change.description)")
				changedFile.applyChange(change)
			}
			
			let finalContent = changedFile.fileContent.joined(separator: "\n")
			print("Final content lines: \(changedFile.fileContent.count)")
			
			assertEqualWithDetailedDiff(finalContent, expectedOutput)
			
			// Test reverting changes
			print("\nTesting reversion of changes:")
			for (index, change) in fileChanges.changes.enumerated().reversed() {
				print("Reverting change \(index + 1): \(change.description)")
				changedFile.revertChange(change)
			}
			
			let revertedContent = changedFile.fileContent.joined(separator: "\n")
			print("Reverted content lines: \(changedFile.fileContent.count)")
			
			assertEqualWithDetailedDiff(revertedContent, initialContent)
			
			// Test rejecting changes (after reverting)
			print("\nTesting rejection of changes:")
			for (index, change) in fileChanges.changes.enumerated() {
				print("Rejecting change \(index + 1): \(change.description)")
				changedFile.rejectChange(change)
			}
			
			let rejectedContent = changedFile.fileContent.joined(separator: "\n")
			print("Rejected content lines: \(changedFile.fileContent.count)")
			
			assertEqualWithDetailedDiff(rejectedContent, initialContent)
			
			// Test parsing of overall summary
			if let summary = parseResult.summary {
				print("\nOverall summary: \(summary)")
			} else {
				print("\nNo overall summary found")
			}
			
		} catch {
			XCTFail("Test failed with error: \(error)")
		}
		
		print("--- Test completed: \(name) ---\n")
	}
	func assertEqualWithDetailedDiff(_ actual: String, _ expected: String, file: StaticString = #file, line: UInt = #line) {
		let actualLines = actual.components(separatedBy: .newlines)
		let expectedLines = expected.components(separatedBy: .newlines)
		
		if actualLines != expectedLines {
			var diffMessage = "Strings are different. Detailed breakdown:\n"
			
			let minLineCount = min(actualLines.count, expectedLines.count)
			
			for i in 0..<minLineCount {
				if actualLines[i] != expectedLines[i] {
					diffMessage += "Line \(i + 1):\n"
					diffMessage += "  Expected: \"\(expectedLines[i])\"\n"
					diffMessage += "  Actual:   \"\(actualLines[i])\"\n\n"
				}
			}
			
			if actualLines.count != expectedLines.count {
				diffMessage += "Line count mismatch:\n"
				diffMessage += "  Expected: \(expectedLines.count) lines\n"
				diffMessage += "  Actual:   \(actualLines.count) lines\n"
				
				if actualLines.count > expectedLines.count {
					diffMessage += "Additional lines in actual content:\n"
					for i in minLineCount..<actualLines.count {
						diffMessage += "  Line \(i + 1): \"\(actualLines[i])\"\n"
					}
				} else {
					diffMessage += "Missing lines in actual content:\n"
					for i in minLineCount..<expectedLines.count {
						diffMessage += "  Line \(i + 1): \"\(expectedLines[i])\"\n"
					}
				}
			}
			
			XCTFail(diffMessage, file: file, line: line)
		}
	}
	
	enum TestError: Error {
		case parsingFailed(String)
	}
}
*/
