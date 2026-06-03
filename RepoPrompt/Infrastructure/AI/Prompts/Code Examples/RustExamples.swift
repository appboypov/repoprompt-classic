//
//  RustExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * RustExamples implements CodeExamples for Rust-specific snippets.
 */
public struct RustExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" struct
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>pub struct User {",
				"<s4>pub id: Uuid,",
				"<s4>pub name: String,",
				"<s0>}"
			]
		} else {
			return [
				"pub struct User {",
				"    pub id: Uuid,",
				"    pub name: String,",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>pub struct User {",
				"<s4>pub id: Uuid,",
				"<s4>pub name: String,",
				"<s4>pub email: String,",
				"<s0>}"
			]
		} else {
			return [
				"pub struct User {",
				"    pub id: Uuid,",
				"    pub name: String,",
				"    pub email: String,",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "email" field
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>use uuid::Uuid;",
				"<s0>",
				"<s0>#[derive(Debug, Clone)]",
				"<s0>pub struct User {",
				"<s4>pub id: Uuid,",
				"<s4>pub name: String,",
				"<s4>pub email: String,",
				"<s0>}",
				"<s0>",
				"<s0>impl User {",
				"<s4>pub fn new(name: String, email: String) -> Self {",
				"<s8>Self {",
				"<s12>id: Uuid::new_v4(),",
				"<s12>name,",
				"<s12>email,",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"use uuid::Uuid;",
				"",
				"#[derive(Debug, Clone)]",
				"pub struct User {",
				"    pub id: Uuid,",
				"    pub name: String,",
				"    pub email: String,",
				"}",
				"",
				"impl User {",
				"    pub fn new(name: String, email: String) -> Self {",
				"        Self {",
				"            id: Uuid::new_v4(),",
				"            name,",
				"            email,",
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" file
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>use iced::{Button, Element, Length, Sandbox};",
				"<s0>",
				"<s0>pub struct RoundedButton {",
				"<s4>corner_radius: f32,",
				"<s4>button: Button,",
				"<s0>}",
				"<s0>",
				"<s0>impl RoundedButton {",
				"<s4>pub fn new() -> Self {",
				"<s8>Self {",
				"<s12>corner_radius: 0.0,",
				"<s12>button: Button::new(),",
				"<s8>}",
				"<s4>}",
				"<s4>",
				"<s4>pub fn corner_radius(mut self, radius: f32) -> Self {",
				"<s8>self.corner_radius = radius;",
				"<s8>self",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"use iced::{Button, Element, Length, Sandbox};",
				"",
				"pub struct RoundedButton {",
				"    corner_radius: f32,",
				"    button: Button,",
				"}",
				"",
				"impl RoundedButton {",
				"    pub fn new() -> Self {",
				"        Self {",
				"            corner_radius: 0.0,",
				"            button: Button::new(),",
				"        }",
				"    }",
				"",
				"    pub fn corner_radius(mut self, radius: f32) -> Self {",
				"        self.corner_radius = radius;",
				"        self",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 4) NetworkManager async/await conversion
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>pub fn fetch_data(url: &str, completion: impl FnOnce(String)) {",
				"<s4>let response = reqwest::blocking::get(url)",
				"<s8>.expect(\"Failed to fetch\")",
				"<s8>.text()",
				"<s8>.expect(\"Failed to read\");",
				"<s4>completion(response);",
				"<s0>}"
			]
		} else {
			return [
				"pub fn fetch_data(url: &str, completion: impl FnOnce(String)) {",
				"    let response = reqwest::blocking::get(url)",
				"        .expect(\"Failed to fetch\")",
				"        .text()",
				"        .expect(\"Failed to read\");",
				"    completion(response);",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>pub async fn fetch_data(url: &str) -> Result<String, reqwest::Error> {",
				"<s4>let response = reqwest::get(url)",
				"<s8>.await?",
				"<s8>.text()",
				"<s8>.await?;",
				"<s4>Ok(response)",
				"<s0>}"
			]
		} else {
			return [
				"pub async fn fetch_data(url: &str) -> Result<String, reqwest::Error> {",
				"    let response = reqwest::get(url)",
				"        .await?",
				"        .text()",
				"        .await?;",
				"    Ok(response)",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>use log::{error, info};",
				"<s0>",
				"<s0>pub fn process_user(user: Option<&User>) {",
				"<s4>match user {",
				"<s8>None => {",
				"<s12>error!(\"User is None\");",
				"<s12>return;",
				"<s8>}",
				"<s8>Some(u) => {",
				"<s12>info!(\"Processing user: {}\", u.name);",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"use log::{error, info};",
				"",
				"pub fn process_user(user: Option<&User>) {",
				"    match user {",
				"        None => {",
				"            error!(\"User is None\");",
				"            return;",
				"        }",
				"        Some(u) => {",
				"            info!(\"Processing user: {}\", u.name);",
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing match arm structure
		if includeIndentation {
			return [
				"<s8>None => {",
				"<s12>error!(\"User is None\");"
			]
		} else {
			return [
				"        None => {",
				"            error!(\"User is None\");"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s8>None => {",
				"<s12>error!(\"User is None or invalid\");",
				"<s12>panic!(\"Cannot process invalid user\");",
				"<s8>}"
			]
		} else {
			return [
				"        None => {",
				"            error!(\"User is None or invalid\");",
				"            panic!(\"Cannot process invalid user\");",
				"        }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		return userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<s8>}",
				"<s4>}",
				"<s4>// Additional validation",
				"<s4>validate_user(user);",
				"<s0>}",
				"<s0>}"  // Extra brace
			]
		} else {
			return [
				"        }",
				"    }",
				"    // Additional validation",
				"    validate_user(user);",
				"}",
				"}"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s12>info!(\"Processing user: {}\", u.name);"]
		} else {
			return ["            info!(\"Processing user: {}\", u.name);"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s12>debug!(\"Processing user: {} (ID: {})\", u.name, u.id);"]
		} else {
			return ["            debug!(\"Processing user: {} (ID: {})\", u.name, u.id);"]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		// Just closing braces - ambiguous
		if includeIndentation {
			return [
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>// TODO: Add more processing",
				"<s0>}"
			]
		} else {
			return [
				"    }",
				"    // TODO: Add more processing",
				"}"
			]
		}
	}
	
	// MARK: Delegate Edit Examples
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"pub async fn load_user_data(user_id: u64) -> Result<User, Error> {",
			"    // REPOMARK:SCOPE: 1 - Replace blocking call with async client",
			"    let url = format!(\"/api/users/{}\", user_id);",
			"    let response = client.get(&url).send().await?;",
			"    ",
			"    if response.status().is_success() {",
			"        let user = response.json::<User>().await?;",
			"        Ok(user)",
			"    } else {",
			"        Err(Error::HttpError(response.status()))",
			"    }",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"fn configure_ui(&mut self) {",
			"    // REPOMARK:SCOPE: 1 - Delete hard-coded color and add theme support",
			"    // ... existing code ...",
			"    self.background_color = theme::current().background_color();",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"pub struct Player {",
			"    current_health: i32,",
			"    max_health: i32,",
			"}",
			"",
			"impl Player {",
			"    pub fn heal(&mut self, amount: i32) {",
			"        // REPOMARK:SCOPE: 1 - Cap health at max_health instead of 999",
			"        self.current_health = (self.current_health + amount).min(self.max_health);",
			"        // ... existing code ...",
			"    }",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"impl Player {",
			"    pub fn heal(&mut self, amount: i32) {",
			"        // REPOMARK:SCOPE: 1 - Cap health at max_health",
			"        self.current_health = (self.current_health + amount).min(self.max_health);",
			"        // ... existing code ...",
			"    }",
			"    ",
			"    pub fn collect_bonus(&mut self, bonus: &Bonus) {",
			"        // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"        self.score += bonus.value + 10;",
			"        // ... existing code ...",
			"    }",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"fn process_order(&mut self, order: &Order) {",
			"    // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"    let subtotal = order.items.iter()",
			"        .map(|item| item.price * item.quantity as f64)",
			"        .sum::<f64>();",
			"    let tax = subtotal * get_tax_rate(&order.shipping_address);",
			"    // Legacy discount logic removed",
			"    let total = subtotal + tax;",
			"    ",
			"    info!(\"Order {}: subtotal={:.2}, tax={:.2}, total={:.2}\",",
			"          order.id, subtotal, tax, total);",
			"    order.total = total;",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"impl WorldGenerator {",
			"    // ... existing code ...",
			"    // REPOMARK:SCOPE: 1 - Replace generate_structures with randomized algorithm",
			"    pub fn generate_structures(&mut self) {",
			"        use rand::Rng;",
			"        let mut rng = rand::thread_rng();",
			"        let structure_count = rng.gen_range(5..15);",
			"        ",
			"        for _ in 0..structure_count {",
			"            let x = rng.gen_range(0..self.world_width);",
			"            let z = rng.gen_range(0..self.world_depth);",
			"            let structure_type = rng.gen_range(0..3).into();",
			"            ",
			"            self.place_structure(x, z, structure_type);",
			"        }",
			"    }",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"pub struct GameManager {",
			"    // REPOMARK:SCOPE: 1 - Add on_game_state_changed callback property",
			"    pub on_game_state_changed: Option<Box<dyn Fn(GameState)>>,",
			"    // ... existing code ...",
			"    current_state: GameState,",
			"    player_count: usize,",
			"}",
			"",
			"impl GameManager {",
			"    pub fn init(&mut self) {",
			"        println!(\"GameManager initializing...\");",
			"        self.load_game_data();",
			"    }",
			"    ",
			"    pub fn update(&mut self) {",
			"        self.handle_input();",
			"        self.update_game_state();",
			"    }",
			"    ",
			"    fn load_game_data(&mut self) {",
			"        // Load save data",
			"        if let Some(save_data) = SaveSystem::load_game() {",
			"            self.restore_game_state(save_data);",
			"        }",
			"    }",
			"    ",
			"    fn generate_random_layout(&mut self) {",
			"        // Generate world",
			"        for x in 0..100 {",
			"            for y in 0..100 {",
			"                self.tiles[x][y] = get_random_tile();",
			"            }",
			"        }",
			"    }",
			"}"
		]
	}
	
	public func commentSyntax() -> String {
		return "//"
	}
	
	// File editor examples use default implementation from protocol extension
	
	// MARK: - Rewrite-Only File Editor Example Methods
	
	public func fileEditorRewriteExampleFileContents() -> [String] {
		return [
			"use std::error::Error;",
			"",
			"#[derive(Debug, Clone)]",
			"struct User {",
			"    id: String,",
			"    name: String,",
			"}",
			"",
			"struct UserService {",
			"    users: Vec<User>,",
			"}",
			"",
			"impl UserService {",
			"    fn new() -> Self {",
			"        UserService {",
			"            users: Vec::new(),",
			"        }",
			"    }",
			"    ",
			"    fn process_user(&self, user_data: &User) -> Result<User, Box<dyn Error>> {",
			"        // Process user data",
			"        let user = User {",
			"            id: user_data.id.clone(),",
			"            name: user_data.name.clone(),",
			"        };",
			"        Ok(user)",
			"    }",
			"    ",
			"    fn save_user(&mut self, user: User) -> Result<(), Box<dyn Error>> {",
			"        // Save user to database",
			"        self.users.push(user);",
			"        Ok(())",
			"    }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"    fn process_user(&self, user_data: &User) -> Result<User, Box<dyn Error>> {",
			"        // Add validation",
			"        if user_data.id.is_empty() || user_data.name.is_empty() {",
			"            return Err(\"Invalid user data\".into());",
			"        }",
			"        ",
			"        // ... existing code ...",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"    fn save_user(&mut self, user: User) -> Result<(), Box<dyn Error>> {",
			"        // ... existing code ...",
			"        println!(\"User saved successfully\");",
			"        Ok(())",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"use std::error::Error;",
			"",
			"#[derive(Debug, Clone)]",
			"struct User {",
			"    id: String,",
			"    name: String,",
			"}",
			"",
			"struct UserService {",
			"    users: Vec<User>,",
			"}",
			"",
			"impl UserService {",
			"    fn new() -> Self {",
			"        UserService {",
			"            users: Vec::new(),",
			"        }",
			"    }",
			"    ",
			"    fn process_user(&self, user_data: &User) -> Result<User, Box<dyn Error>> {",
			"        // Add validation",
			"        if user_data.id.is_empty() || user_data.name.is_empty() {",
			"            return Err(\"Invalid user data\".into());",
			"        }",
			"        ",
			"        // Process user data",
			"        let user = User {",
			"            id: user_data.id.clone(),",
			"            name: user_data.name.clone(),",
			"        };",
			"        Ok(user)",
			"    }",
			"    ",
			"    fn save_user(&mut self, user: User) -> Result<(), Box<dyn Error>> {",
			"        // Save user to database",
			"        self.users.push(user);",
			"        println!(\"User saved successfully\");",
			"        Ok(())",
			"    }",
			"}"
		]
	}
}