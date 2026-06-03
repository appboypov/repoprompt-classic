//
//  SwiftExamples.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-28.
//

import Foundation

/**
 * SwiftExamples implements CodeExamples for Swift-specific snippets.
 */
public struct SwiftExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" struct
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>struct User {",
				"<s4>let id: UUID",
				"<s4>var name: String",
				"<s0>}"
			]
		} else {
			return [
				"struct User {",
				"    let id: UUID",
				"    var name: String",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>struct User {",
				"<s4>let id: UUID",
				"<s4>var name: String",
				"<s4>var email: String",
				"<s0>}"
			]
		} else {
			return [
				"struct User {",
				"    let id: UUID",
				"    var name: String",
				"    var email: String",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "email" field
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import Foundation",
				"<s0>struct User {",
				"<s4>let id: UUID",
				"<s4>var name: String",
				"<s4>var email: String",
				"<s0>init(name: String, email: String) {",
				"<s4>self.id = UUID()",
				"<s4>self.name = name",
				"<s4>self.email = email",
				"<s0>}",
				"<s0>}"
			]
		} else {
			return [
				"import Foundation",
				"struct User {",
				"    let id: UUID",
				"    var name: String",
				"    var email: String",
				"",
				"    init(name: String, email: String) {",
				"        self.id = UUID()",
				"        self.name = name",
				"        self.email = email",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" file
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import UIKit",
				"<s0>@IBDesignable",
				"<s0>class RoundedButton: UIButton {",
				"<s4>@IBInspectable var cornerRadius: CGFloat = 0",
				"<s0>}"
			]
		} else {
			return [
				"import UIKit",
				"@IBDesignable",
				"class RoundedButton: UIButton {",
				"    @IBInspectable var cornerRadius: CGFloat = 0",
				"}"
			]
		}
	}
	
	// MARK: 4) Indentation-Preserving Example (async/await)
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class NetworkManager {",
				"<s4>func fetchData(from url: URL, completion: @escaping (Data?) -> Void) {",
				"<s8>// old code",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"class NetworkManager {",
				"    func fetchData(from url: URL, completion: @escaping (Data?) -> Void) {",
				"        // old code",
				"    }",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class NetworkManager {",
				"<s4>func fetchData(from url: URL) async throws -> Data {",
				"<s8>let (data, _) = try await URLSession.shared.data(from: url)",
				"<s8>return data",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"class NetworkManager {",
				"    func fetchData(from url: URL) async throws -> Data {",
				"        let (data, _) = try await URLSession.shared.data(from: url)",
				"        return data",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: - Negative Examples for Search/Replace
	
	/**
	 * Represents the "original file contents" portion for the negative example.
	 * If includeIndentation is true, we add <s0>, <s4>, etc.
	 */
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import Foundation",
				"<s0>class Example {",
				"<s0>    foo() {",
				"<s0>        Bar()",
				"<s0>    }",
				"<s0>}"
			]
		} else {
			return [
				"import Foundation",
				"class Example {",
				"    foo() {",
				"        Bar()",
				"    }",
				"}"
			]
		}
	}
	
	/**
	 * The mismatched search block for the negative example.
	 * Notice it omits or shifts whitespace from the original lines.
	 */
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>foo() {",
				"<s8>Bar()",
				"<s4>}"
			]
		} else {
			// Note: We now indent the first closing brace with 4 spaces.
			return [
				"    foo() {",
				"        Bar()",
				"    }"
			]
		}
	}
	
	/**
	 * The intended "new" content block for the negative example.
	 * Illustrates an added line (Bar2()) that won’t properly match because
	 * the search block is missing or has mismatched indentation/spacing.
	 */
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>foo() {",
				"<s8>Bar()",
				"<s8>Bar2()",
				"<s4>}"
			]
		} else {
			return [
				"    foo() {",
				"        Bar()",
				"        Bar2()",
				"    }"
			]
		}
	}
	
	/**
	 * Demonstrates a file that, when partially matched, can cause mismatched braces in the replacement content.
	 * The "foo() { ... }" block is correct, but the new content has an extra block plus an extra closing brace.
	 */
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>func someFunction() {",
				"<s4>foo() {",
				"<s8>Bar()",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"func someFunction() {",
				"    foo() {",
				"        Bar()",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>foo() {",
				"<s8>Bar()",
				"<s4>}"
			]
		} else {
			return [
				"    foo() {",
				"        Bar()",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>foo() {",
				"<s8>Bar()",
				"<s4>}",
				"",
				"<s4>bar() {",
				"<s8>foo2()",
				"<s4>}",
				"<s0>}"
			]
		} else {
			// All lines here are meant to be indented at the level of <s4>
			return [
				"    foo() {",
				"        Bar()",
				"    }",
				"",
				"    bar() {",
				"        foo2()",
				"    }",
				"}"
			]
		}
	}
	
	// New negative example: one-line search block (should be avoided)
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>var email: String" // Only one line – too short for a reliable search block.
			]
		} else {
			return [
				"var email: String" // Only one line – too short for a reliable search block.
			]
		}
	}
	
	// New negative example: one-line new block (content must match search block)
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>var emailNew: String" // Only one line – too short for a reliable search block.
			]
		} else {
			return [
				"var emailNew: String" // Only one line – too short for a reliable search block.
			]
		}
	}
	
	// New negative example: ambiguous search block (should be avoided)
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>}",
				"<s0>}"
			]
		} else {
			// Here we follow the token levels: one line at 4 spaces then one at 0.
			return [
				"    }",
				"}"
			]
		}
	}
	
	// New negative example: ambiguous new block (content must match search block)
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s8>foo() {",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			// Replace each token with its equivalent number of spaces:
			// <s8> → 8 spaces, <s4> → 4 spaces, <s0> → 0 spaces.
			return [
				"        foo() {",
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 5) Delegate Edit – Complex Replacement (concise markers)
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"func loadUserData() async throws {",
			"    // <rm legacy networking>",
			"    NetworkService.requestOld(endpoint: .user) { data in",
			"        // old completion‑handler logic",
			"    }",
			"    // </rm>",
			"",
			"    // <add async/await networking>",
			"    let data = try await api.fetchUser()",
			"    handle(data)",
			"    // </add>",
			"}"
		]
	}

	// MARK: 6) Delegate Edit – Addition + Deletion (concise markers)
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"func configureUI() {",
			"    // existing setup code",
			"",
			"    // <rm old colour assignment>",
			"    view.backgroundColor = .white",
			"    // </rm>",
			"",
			"    // … other mid‑section code …",
			"",
			"    // <add dark‑mode aware colour>",
			"    view.backgroundColor = UIColor(named: \"BackgroundColor\")",
			"    // </add>",
			"}"
		]
	}
	
	// MARK: 7) New Delegate Edit Examples
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"func heal(amount: Int) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999 in heal method",
			"    currentHealth = min(currentHealth + amount, maxHealth)",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"func heal(amount: Int) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999 in heal method",
			"    currentHealth = min(currentHealth + amount, maxHealth)",
			"}",
			"// ... existing code ...",
			"func collectItem() {",
			"    // REPOMARK:SCOPE: 2 - Add bonus score when collecting items in collectItem method",
			"    score += itemValue + 10",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"func processOrder(_ order: Order) {",
			"    validateOrder(order)",
			"    // REPOMARK:SCOPE: 1 - Update tax calculation, remove legacy discount, add logging in processOrder method",
			"    let subtotal = order.items.reduce(0) { $0 + $1.price }",
			"    let tax = subtotal * 0.0875  // Updated from 0.08",
			"    // Removed: let discount = subtotal * 0.05",
			"    let total = subtotal + tax",
			"    print(\"Order total: \\(total)\")",
			"    order.total = total",
			"    saveOrder(order)",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"class WorldGenerator {",
			"    var structures: [Structure] = []",
			"    ",
			"    // REPOMARK:SCOPE: 1 - Replace entire generateStructures method with randomized algorithm in WorldGenerator class",
			"    func generateStructures() {",
			"        let types = [StructureType.house, .tree, .rock]",
			"        for _ in 0..<10 {",
			"            let randomType = types.randomElement()!",
			"            let x = Int.random(in: 0..<worldSize)",
			"            let y = Int.random(in: 0..<worldSize)",
			"            structures.append(Structure(type: randomType, x: x, y: y))",
			"        }",
			"    }",
			"    ",
			"    func clearStructures() {",
			"        structures.removeAll()",
			"    }",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"class GameManager {",
			"    // REPOMARK:SCOPE: 1 - Add callback property and initialization/data loading logging",
			"    var onGameStateChanged: ((GameState) -> Void)?",
			"    ",
			"    private var currentState: GameState = .menu",
			"    private var score = 0",
			"    ",
			"    func viewDidLoad() {",
			"        super.viewDidLoad()",
			"        print(\"GameManager initialized\")",
			"        setupUI()",
			"        loadGameData()",
			"    }",
			"    ",
			"    func loadGameData() {",
			"        print(\"Loading game data...\")",
			"        // Load saved state",
			"        if let savedData = UserDefaults.standard.data(forKey: \"gameData\") {",
			"            // Decode and apply",
			"        }",
			"        print(\"Game data loaded\")",
			"    }",
			"    ",
			"    func generateRandomLayout() {",
			"        // This method is unchanged",
			"        for i in 0..<10 {",
			"            let x = Int.random(in: 0..<100)",
			"            let y = Int.random(in: 0..<100)",
			"            placeObject(at: x, y: y)",
			"        }",
			"    }",
			"}"
		]
	}
	
	public func commentSyntax() -> String {
		return "//"
	}
	
	// MARK: - File Editor Example Methods
	
	public func fileEditorExampleFileContents() -> [String] {
		return [
			"import Foundation",
			"",
			"class GameManager {",
			"    private var score: Int = 0",
			"    private var level: Int = 1",
			"    private var isRunning: Bool = false",
			"    ",
			"    func reset() {",
			"        score = 0",
			"        level = 1",
			"        isRunning = false",
			"    }",
			"    ",
			"    func checkProximity(to position: CGPoint) -> Float {",
			"        // Calculate distance logic here",
			"        return 0.0",
			"    }",
			"}"
		]
	}
	
	public func fileEditorExampleChange1() -> [String] {
		return [
			"        // ... existing code ...",
			"        private var isRunning: Bool = false",
			"        ",
			"        init() {",
			"            print(\"GameManager initialized\")",
			"        }",
			"        ",
			"        func reset() {",
			"        // ... existing code ..."
		]
	}
	
	public func fileEditorExampleChange2() -> [String] {
		return [
			"        // ... existing code ...",
			"        }",
			"        ",
			"        deinit {",
			"            print(\"GameManager cleaned up\")",
			"        }",
			"    }"
		]
	}
	
	public func fileEditorExampleSearchBlock() -> [String] {
		return [
			"    private var isRunning: Bool = false",
			"    ",
			"    func reset() {"
		]
	}
	
	public func fileEditorExampleContentBlock() -> [String] {
		return [
			"    private var isRunning: Bool = false",
			"    ",
			"    init() {",
			"        print(\"GameManager initialized\")",
			"    }",
			"    ",
			"    func reset() {"
		]
	}
	
	public func fileEditorExampleSearchBlock2() -> [String] {
		return [
			"        return 0.0",
			"    }",
			"}"
		]
	}
	
	public func fileEditorExampleContentBlock2() -> [String] {
		return [
			"        return 0.0",
			"    }",
			"    ",
			"    deinit {",
			"        print(\"GameManager cleaned up\")",
			"    }",
			"}"
		]
	}
	
	// MARK: - Rewrite-Only File Editor Example Methods
	
	public func fileEditorRewriteExampleFileContents() -> [String] {
		return [
			"import Foundation",
			"",
			"class UserService {",
			"    private var users: [User] = []",
			"    ",
			"    init() {",
			"        // Initialize service",
			"    }",
			"    ",
			"    func processUser(_ userData: UserData) -> User {",
			"        // Process user data",
			"        let user = User(",
			"            id: userData.id,",
			"            name: userData.name",
			"        )",
			"        return user",
			"    }",
			"    ",
			"    func saveUser(_ user: User) {",
			"        // Save user to database",
			"        users.append(user)",
			"    }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"    func processUser(_ userData: UserData) -> User {",
			"        // Add validation",
			"        guard !userData.id.isEmpty,",
			"              !userData.name.isEmpty else {",
			"            throw UserServiceError.invalidUserData",
			"        }",
			"        ",
			"        // ... existing code ...",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"    func saveUser(_ user: User) {",
			"        do {",
			"            // ... existing code ...",
			"            print(\"User saved successfully\")",
			"        } catch {",
			"            print(\"Failed to save user: \\(error)\")",
			"            throw error",
			"        }",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"import Foundation",
			"",
			"enum UserServiceError: Error {",
			"    case invalidUserData",
			"}",
			"",
			"class UserService {",
			"    private var users: [User] = []",
			"    ",
			"    init() {",
			"        // Initialize service",
			"    }",
			"    ",
			"    func processUser(_ userData: UserData) throws -> User {",
			"        // Add validation",
			"        guard !userData.id.isEmpty,",
			"              !userData.name.isEmpty else {",
			"            throw UserServiceError.invalidUserData",
			"        }",
			"        ",
			"        // Process user data",
			"        let user = User(",
			"            id: userData.id,",
			"            name: userData.name",
			"        )",
			"        return user",
			"    }",
			"    ",
			"    func saveUser(_ user: User) throws {",
			"        do {",
			"            // Save user to database",
			"            users.append(user)",
			"            print(\"User saved successfully\")",
			"        } catch {",
			"            print(\"Failed to save user: \\(error)\")",
			"            throw error",
			"        }",
			"    }",
			"}"
		]
	}
}
