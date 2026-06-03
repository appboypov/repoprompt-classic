//
//  CodeExamples.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-28.
//

import Foundation

/**
 * CodeExamples protocol is a generic interface for providing code snippets
 * in various languages. SwiftExamples is our Swift-specific implementation.
 */
public protocol CodeExamples {
	func userSearchReplaceOldLines(includeIndentation: Bool) -> [String]
	func userSearchReplaceNewLines(includeIndentation: Bool) -> [String]
	
	func userRewriteAllLines(includeIndentation: Bool) -> [String]
	func userCreateAllLines(includeIndentation: Bool) -> [String]
	
	func networkManagerOldLines(includeIndentation: Bool) -> [String]
	func networkManagerNewLines(includeIndentation: Bool) -> [String]
	
	// Negative example for search/replace (mismatched search block)
	func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String]
	func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String]
	func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String]
	
	// Additional negative example for mismatched braces
	func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String]
	func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String]
	func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String]
	
	// New negative example: one-line search block (should be avoided)
	func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String]
	// New block for one-line negative example (content must match search block)
	func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String]
	
	// New negative example: ambiguous search block (should be avoided)
	func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String]
	// New block for ambiguous negative example (content must match search block)
	func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String]
	
	/// Delegate‑edit example that shows a complex replacement
	/// (explicitly marks a block to remove, then one to add).
	func delegateEditComplexReplaceLines() -> [String]

	/// Delegate‑edit example that shows a pure delete followed by
	/// a separate addition elsewhere in the same method.
	func delegateEditComplexAddDeleteLines() -> [String]
	
	// New delegate edit examples with proper scope markers
	func delegateEditInlineTweakSingleScope() -> [String]
	func delegateEditInlineTweaksTwoScopes() -> [String]
	func delegateEditComplexSingleScope() -> [String]
	func delegateEditFullScopeSwap() -> [String]
	func delegateEditNegativeVerbose() -> [String]
	
	/// Returns the comment syntax for this language (e.g., "//" for Swift/C, "#" for Python)
	func commentSyntax() -> String
	
	// File editor example methods
	func fileEditorExampleFileContents() -> [String]
	func fileEditorExampleChange1() -> [String]
	func fileEditorExampleChange2() -> [String]
	func fileEditorExampleSearchBlock() -> [String]
	func fileEditorExampleContentBlock() -> [String]
	func fileEditorExampleSearchBlock2() -> [String]
	func fileEditorExampleContentBlock2() -> [String]
	
	// File editor rewrite-only example methods
	func fileEditorRewriteExampleFileContents() -> [String]
	func fileEditorRewriteExampleChange1() -> [String]
	func fileEditorRewriteExampleChange2() -> [String]
	func fileEditorRewriteExampleCompleteFile() -> [String]
}

// MARK: - Default Implementations for File Editor Examples
extension CodeExamples {
	// Default implementations using generic JavaScript-like syntax
	public func fileEditorExampleFileContents() -> [String] {
		return [
			"class GameManager {",
			"  constructor() {",
			"    this.score = 0;",
			"    this.level = 1;",
			"    this.isRunning = false;",
			"  }",
			"  ",
			"  reset() {",
			"    this.score = 0;",
			"    this.level = 1;",
			"    this.isRunning = false;",
			"  }",
			"  ",
			"  checkProximity(position) {",
			"    // Calculate distance logic here",
			"    return 0.0;",
			"  }",
			"}"
		]
	}
	
	public func fileEditorExampleChange1() -> [String] {
		return [
			"    // ... existing code ...",
			"    this.isRunning = false;",
			"    ",
			"    console.log('GameManager initialized');",
			"  }",
			"  ",
			"  reset() {",
			"    // ... existing code ..."
		]
	}
	
	public func fileEditorExampleChange2() -> [String] {
		return [
			"    // ... existing code ...",
			"  }",
			"  ",
			"  destroy() {",
			"    console.log('GameManager cleaned up');",
			"  }",
			"}"
		]
	}
	
	public func fileEditorExampleSearchBlock() -> [String] {
		return [
			"    this.isRunning = false;",
			"  }",
			"  ",
			"  reset() {"
		]
	}
	
	public func fileEditorExampleContentBlock() -> [String] {
		return [
			"    this.isRunning = false;",
			"    ",
			"    console.log('GameManager initialized');",
			"  }",
			"  ",
			"  reset() {"
		]
	}
	
	public func fileEditorExampleSearchBlock2() -> [String] {
		return [
			"    return 0.0;",
			"  }",
			"}"
		]
	}
	
	public func fileEditorExampleContentBlock2() -> [String] {
		return [
			"    return 0.0;",
			"  }",
			"  ",
			"  destroy() {",
			"    console.log('GameManager cleaned up');",
			"  }",
			"}"
		]
	}
	
	// MARK: - Rewrite-Only File Editor Example Methods
	
	public func fileEditorRewriteExampleFileContents() -> [String] {
		return [
			"class UserService {",
			"  constructor() {",
			"    this.users = [];",
			"  }",
			"  ",
			"  processUser(userData) {",
			"    // Process user data",
			"    const user = {",
			"      id: userData.id,",
			"      name: userData.name",
			"    };",
			"    return user;",
			"  }",
			"  ",
			"  saveUser(user) {",
			"    // Save user to database",
			"    this.users.push(user);",
			"  }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"  processUser(userData) {",
			"    // Add validation",
			"    if (!userData || !userData.id || !userData.name) {",
			"      throw new Error('Invalid user data');",
			"    }",
			"    ",
			"    // ... existing code ...",
			"  }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"  saveUser(user) {",
			"    try {",
			"      // ... existing code ...",
			"      console.log('User saved successfully');",
			"    } catch (error) {",
			"      console.error('Failed to save user:', error);",
			"      throw error;",
			"    }",
			"  }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"class UserService {",
			"  constructor() {",
			"    this.users = [];",
			"  }",
			"  ",
			"  processUser(userData) {",
			"    // Add validation",
			"    if (!userData || !userData.id || !userData.name) {",
			"      throw new Error('Invalid user data');",
			"    }",
			"    ",
			"    // Process user data",
			"    const user = {",
			"      id: userData.id,",
			"      name: userData.name",
			"    };",
			"    return user;",
			"  }",
			"  ",
			"  saveUser(user) {",
			"    try {",
			"      // Save user to database",
			"      this.users.push(user);",
			"      console.log('User saved successfully');",
			"    } catch (error) {",
			"      console.error('Failed to save user:', error);",
			"      throw error;",
			"    }",
			"  }",
			"}"
		]
	}
}
