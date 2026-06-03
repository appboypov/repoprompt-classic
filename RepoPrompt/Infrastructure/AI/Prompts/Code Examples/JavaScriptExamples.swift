//
//  JavaScriptExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * JavaScriptExamples implements CodeExamples for JavaScript-specific snippets.
 */
public struct JavaScriptExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s2>constructor(id, name) {",
				"<s4>this.id = id;",
				"<s4>this.name = name;",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class User {",
				"  constructor(id, name) {",
				"    this.id = id;",
				"    this.name = name;",
				"  }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s2>constructor(id, name, email) {",
				"<s4>this.id = id;",
				"<s4>this.name = name;",
				"<s4>this.email = email;",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class User {",
				"  constructor(id, name, email) {",
				"    this.id = id;",
				"    this.name = name;",
				"    this.email = email;",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite All Lines
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s2>constructor(id, name, email, role = 'user') {",
				"<s4>this.id = id;",
				"<s4>this.name = name;",
				"<s4>this.email = email;",
				"<s4>this.role = role;",
				"<s4>this.createdAt = new Date();",
				"<s2>}",
				"",
				"<s2>getDisplayName() {",
				"<s4>return `${this.name} (${this.email})`;",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class User {",
				"  constructor(id, name, email, role = 'user') {",
				"    this.id = id;",
				"    this.name = name;",
				"    this.email = email;",
				"    this.role = role;",
				"    this.createdAt = new Date();",
				"  }",
				"",
				"  getDisplayName() {",
				"    return `${this.name} (${this.email})`;",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: 3) Create All Lines
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>// models/User.js",
				"<s0>export class User {",
				"<s2>constructor(id, name, email) {",
				"<s4>this.id = id;",
				"<s4>this.name = name;",
				"<s4>this.email = email;",
				"<s2>}",
				"",
				"<s2>toJSON() {",
				"<s4>return {",
				"<s6>id: this.id,",
				"<s6>name: this.name,",
				"<s6>email: this.email",
				"<s4>};",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"// models/User.js",
				"export class User {",
				"  constructor(id, name, email) {",
				"    this.id = id;",
				"    this.name = name;",
				"    this.email = email;",
				"  }",
				"",
				"  toJSON() {",
				"    return {",
				"      id: this.id,",
				"      name: this.name,",
				"      email: this.email",
				"    };",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: 4) NetworkManager Example
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class APIClient {",
				"<s2>async fetchData(endpoint) {",
				"<s4>const response = await fetch(endpoint);",
				"<s4>return response.json();",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class APIClient {",
				"  async fetchData(endpoint) {",
				"    const response = await fetch(endpoint);",
				"    return response.json();",
				"  }",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class APIClient {",
				"<s2>async fetchData(endpoint, options = {}) {",
				"<s4>try {",
				"<s6>const response = await fetch(endpoint, {",
				"<s8>...options,",
				"<s8>headers: {",
				"<s10>'Content-Type': 'application/json',",
				"<s10>...options.headers",
				"<s8>}",
				"<s6>});",
				"<s6>",
				"<s6>if (!response.ok) {",
				"<s8>throw new Error(`HTTP ${response.status}: ${response.statusText}`);",
				"<s6>}",
				"<s6>",
				"<s6>return response.json();",
				"<s4>} catch (error) {",
				"<s6>console.error('API request failed:', error);",
				"<s6>throw error;",
				"<s4>}",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class APIClient {",
				"  async fetchData(endpoint, options = {}) {",
				"    try {",
				"      const response = await fetch(endpoint, {",
				"        ...options,",
				"        headers: {",
				"          'Content-Type': 'application/json',",
				"          ...options.headers",
				"        }",
				"      });",
				"      ",
				"      if (!response.ok) {",
				"        throw new Error(`HTTP ${response.status}: ${response.statusText}`);",
				"      }",
				"      ",
				"      return response.json();",
				"    } catch (error) {",
				"      console.error('API request failed:', error);",
				"      throw error;",
				"    }",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: 5) Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		return [
			"class User {",
			"  constructor(id, name) {",
			"    this.id = id;",
			"    this.name = name;",
			"    this.isActive = true;",
			"  }",
			"  ",
			"  getInfo() {",
			"    return `User: ${this.name}`;",
			"  }",
			"}"
		]
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		return [
			"  constructor(id, name) {",
			"    this.id = id;",
			"    this.name = name;"
		]
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		return [
			"  constructor(id, name, email) {",
			"    this.id = id;",
			"    this.name = name;",
			"    this.email = email;"
		]
	}
	
	// Brace mismatch example
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		return [
			"function processData(items) {",
			"  if (items.length > 0) {",
			"    items.forEach(item => {",
			"      console.log(item);",
			"    });",
			"  }",
			"}"
		]
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		return [
			"  if (items.length > 0) {",
			"    items.forEach(item => {",
			"      console.log(item);"
		]
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		return [
			"  if (items.length > 0) {",
			"    console.log(`Processing ${items.length} items`);",
			"    items.forEach(item => {",
			"      console.log(item);"
		]
	}
	
	// One-line search block
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		return ["console.log(item);"]
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		return ["console.log('Item:', item);"]
	}
	
	// Ambiguous search block
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		return ["}"]
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		return [
			"  }",
			"}"
		]
	}
	
	// MARK: 6) Delegate Edit Examples
	
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"class GameEngine {",
			"  constructor() {",
			"    this.score = 0;",
			"    this.level = 1;",
			"  }",
			"  ",
			"  // DELETE THIS METHOD",
			"  oldUpdate() {",
			"    // Legacy update logic",
			"  }",
			"  ",
			"  // ADD NEW METHOD BELOW",
			"  update(deltaTime) {",
			"    // Modern update with delta time",
			"    this.updatePhysics(deltaTime);",
			"    this.updateGraphics(deltaTime);",
			"  }",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"class Player {",
			"  constructor(name) {",
			"    this.name = name;",
			"    // DELETE the next line",
			"    this.x = 0; this.y = 0;  // old position tracking",
			"    // ADD position object instead",
			"    this.position = { x: 0, y: 0 };",
			"    this.health = 100;",
			"  }",
			"  ",
			"  move(dx, dy) {",
			"    // DELETE old movement",
			"    // this.x += dx;",
			"    // this.y += dy;",
			"    // ADD new movement",
			"    this.position.x += dx;",
			"    this.position.y += dy;",
			"  }",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"// REPOMARK:SCOPE: 1 - Add validation check at start of heal() and console log after health update",
			"heal(amount) {",
			"  if (amount <= 0) return;  // Added validation",
			"  // ... existing code ...",
			"  this.currentHealth = Math.min(this.currentHealth + amount, this.maxHealth);",
			"  console.log(`Healed for ${amount}`);  // Added logging",
			"  // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"// REPOMARK:SCOPE: 1 - Add validation check at start of heal() and console log after health update",
			"heal(amount) {",
			"  if (amount <= 0) return;  // Added validation",
			"  // ... existing code ...",
			"  this.currentHealth = Math.min(this.currentHealth + amount, this.maxHealth);",
			"  // ... existing code ...",
			"}",
			"",
			"// ... existing code ...",
			"",
			"// REPOMARK:SCOPE: 2 - Add console log after score calculation in updateScore()",
			"updateScore(points) {",
			"  // ... existing code ...",
			"  this.score += points;",
			"  console.log(`Score updated: ${this.score}`);  // Added",
			"  // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"// REPOMARK:SCOPE: 1 - Add validation at start, logging before processing, and email sending after receipt generation",
			"async processOrder(order) {",
			"  // Validate order first (added)",
			"  if (!order || !order.items || order.items.length === 0) {",
			"    throw new Error('Invalid order: must contain items');",
			"  }",
			"  ",
			"  console.log(`Processing order ${order.id}...`);  // Added logging",
			"  // ... existing code ...",
			"  const receipt = await this.generateReceipt(order);",
			"  ",
			"  // Send confirmation email (added)",
			"  if (order.customerEmail) {",
			"    await this.emailService.sendConfirmation(order.customerEmail, receipt);",
			"  }",
			"  ",
			"  // ... existing code ...",
			"  return receipt;",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"// REPOMARK:SCOPE: 1 - Replace entire generateStructures() method body with new randomized algorithm",
			"generateStructures() {",
			"  let y = 0;",
			"  for (let level = 0; level < Math.floor(Math.random() * 4) + 2; level++) {",
			"    const height = Math.random() * 0.7 + 0.3;",
			"    const offset = (Math.random() - 0.5) * 0.1;",
			"    // assemble level with new algorithm",
			"    y += height + offset;",
			"  }",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"// ❌ NEVER DO THIS - Including entire unchanged methods/classes",
			"// REPOMARK:SCOPE: 1 - Add health property to constructor and logging to init() and loadData() (BAD - includes entire class)",
			"class GameManager {",
			"  constructor() {",
			"    this.score = 0;",
			"    this.health = 100;  // Added",
			"    this.level = 1;",
			"    this.isPaused = false;",
			"  }",
			"  ",
			"  init() {",
			"    this.setupUI();",
			"    this.loadAssets();",
			"    this.startGameLoop();",
			"  }",
			"  ",
			"  update() {",
			"    if (!this.isPaused) {",
			"      this.updateEntities();",
			"      this.checkCollisions();",
			"      this.render();",
			"    }",
			"  }",
			"  ",
			"  loadData() {",
			"    console.log('Loading...');  // Added",
			"    // ... 50 more unchanged lines ...",
			"  }",
			"}"
		]
	}
	
	public func commentSyntax() -> String {
		return "//"
	}
	
	// MARK: - File Editor Example Methods
	
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
		// Using the default implementation from the protocol extension
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