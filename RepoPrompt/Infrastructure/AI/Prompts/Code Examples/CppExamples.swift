//
//  CppExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * CppExamples implements CodeExamples for C++-specific snippets.
 */
public struct CppExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s0>public:",
				"<s4>std::string id;",
				"<s4>std::string name;",
				"<s0>};"
			]
		} else {
			return [
				"class User {",
				"public:",
				"    std::string id;",
				"    std::string name;",
				"};"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s0>public:",
				"<s4>std::string id;",
				"<s4>std::string name;",
				"<s4>std::string email;",
				"<s0>};"
			]
		} else {
			return [
				"class User {",
				"public:",
				"    std::string id;",
				"    std::string name;",
				"    std::string email;",
				"};"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "email" field
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>#pragma once",
				"<s0>#include <string>",
				"<s0>#include <uuid/uuid.h>",
				"<s0>",
				"<s0>class User {",
				"<s0>private:",
				"<s4>std::string id;",
				"<s4>std::string name;",
				"<s4>std::string email;",
				"<s0>",
				"<s0>public:",
				"<s4>User(const std::string& name, const std::string& email) ",
				"<s8>: name(name), email(email) {",
				"<s8>// Generate UUID",
				"<s8>uuid_t uuid;",
				"<s8>uuid_generate(uuid);",
				"<s8>char uuid_str[37];",
				"<s8>uuid_unparse(uuid, uuid_str);",
				"<s8>id = std::string(uuid_str);",
				"<s4>}",
				"<s4>",
				"<s4>const std::string& getId() const { return id; }",
				"<s4>const std::string& getName() const { return name; }",
				"<s4>const std::string& getEmail() const { return email; }",
				"<s0>};"
			]
		} else {
			return [
				"#pragma once",
				"#include <string>",
				"#include <uuid/uuid.h>",
				"",
				"class User {",
				"private:",
				"    std::string id;",
				"    std::string name;",
				"    std::string email;",
				"",
				"public:",
				"    User(const std::string& name, const std::string& email) ",
				"        : name(name), email(email) {",
				"        // Generate UUID",
				"        uuid_t uuid;",
				"        uuid_generate(uuid);",
				"        char uuid_str[37];",
				"        uuid_unparse(uuid, uuid_str);",
				"        id = std::string(uuid_str);",
				"    }",
				"",
				"    const std::string& getId() const { return id; }",
				"    const std::string& getName() const { return name; }",
				"    const std::string& getEmail() const { return email; }",
				"};"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" file
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>#pragma once",
				"<s0>#include <QPushButton>",
				"<s0>",
				"<s0>class RoundedButton : public QPushButton {",
				"<s4>Q_OBJECT",
				"<s4>Q_PROPERTY(double cornerRadius READ cornerRadius WRITE setCornerRadius)",
				"<s0>",
				"<s0>private:",
				"<s4>double m_cornerRadius;",
				"<s0>",
				"<s0>public:",
				"<s4>explicit RoundedButton(QWidget* parent = nullptr)",
				"<s8>: QPushButton(parent), m_cornerRadius(0.0) {}",
				"<s4>",
				"<s4>double cornerRadius() const { return m_cornerRadius; }",
				"<s4>void setCornerRadius(double radius) { ",
				"<s8>m_cornerRadius = radius;",
				"<s8>update();",
				"<s4>}",
				"<s0>};"
			]
		} else {
			return [
				"#pragma once",
				"#include <QPushButton>",
				"",
				"class RoundedButton : public QPushButton {",
				"    Q_OBJECT",
				"    Q_PROPERTY(double cornerRadius READ cornerRadius WRITE setCornerRadius)",
				"",
				"private:",
				"    double m_cornerRadius;",
				"",
				"public:",
				"    explicit RoundedButton(QWidget* parent = nullptr)",
				"        : QPushButton(parent), m_cornerRadius(0.0) {}",
				"",
				"    double cornerRadius() const { return m_cornerRadius; }",
				"    void setCornerRadius(double radius) { ",
				"        m_cornerRadius = radius;",
				"        update();",
				"    }",
				"};"
			]
		}
	}
	
	// MARK: 4) NetworkManager async/await conversion
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>void fetchData(const std::string& url, std::function<void(std::string)> completion) {",
				"<s4>std::thread([url, completion]() {",
				"<s8>// Simulated blocking network call",
				"<s8>std::string response = performBlockingRequest(url);",
				"<s8>completion(response);",
				"<s4>}).detach();",
				"<s0>}"
			]
		} else {
			return [
				"void fetchData(const std::string& url, std::function<void(std::string)> completion) {",
				"    std::thread([url, completion]() {",
				"        // Simulated blocking network call",
				"        std::string response = performBlockingRequest(url);",
				"        completion(response);",
				"    }).detach();",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>std::future<std::string> fetchData(const std::string& url) {",
				"<s4>return std::async(std::launch::async, [url]() {",
				"<s8>// Async network call",
				"<s8>return performAsyncRequest(url);",
				"<s4>});",
				"<s0>}"
			]
		} else {
			return [
				"std::future<std::string> fetchData(const std::string& url) {",
				"    return std::async(std::launch::async, [url]() {",
				"        // Async network call",
				"        return performAsyncRequest(url);",
				"    });",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>#include \"user_service.h\"",
				"<s0>#include \"logger.h\"",
				"<s0>",
				"<s0>void UserService::processUser(User* user) {",
				"<s4>if (user == nullptr) {",
				"<s8>Logger::error(\"User is nullptr\");",
				"<s8>return;",
				"<s4>}",
				"<s4>Logger::info(\"Processing user: \" + user->getName());",
				"<s0>}"
			]
		} else {
			return [
				"#include \"user_service.h\"",
				"#include \"logger.h\"",
				"",
				"void UserService::processUser(User* user) {",
				"    if (user == nullptr) {",
				"        Logger::error(\"User is nullptr\");",
				"        return;",
				"    }",
				"    Logger::info(\"Processing user: \" + user->getName());",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing braces
		if includeIndentation {
			return [
				"<s4>if (user == nullptr)",
				"<s8>Logger::error(\"User is nullptr\");"
			]
		} else {
			return [
				"    if (user == nullptr)",
				"        Logger::error(\"User is nullptr\");"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>if (user == nullptr || user->getName().empty()) {",
				"<s8>Logger::error(\"User is invalid\");",
				"<s8>throw std::invalid_argument(\"Invalid user\");",
				"<s4>}"
			]
		} else {
			return [
				"    if (user == nullptr || user->getName().empty()) {",
				"        Logger::error(\"User is invalid\");",
				"        throw std::invalid_argument(\"Invalid user\");",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		return userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>Logger::info(\"Processing user: \" + user->getName());",
				"<s0>}"
			]
		} else {
			return [
				"    }",
				"    Logger::info(\"Processing user: \" + user->getName());",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>Logger::info(\"Processing user: \" + user->getName());",
				"<s4>// Additional validation",
				"<s4>validateUser(user);",
				"<s0>}",
				"<s0>}"  // Extra brace
			]
		} else {
			return [
				"    }",
				"    Logger::info(\"Processing user: \" + user->getName());",
				"    // Additional validation",
				"    validateUser(user);",
				"}",
				"}"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s4>Logger::info(\"Processing user: \" + user->getName());"]
		} else {
			return ["    Logger::info(\"Processing user: \" + user->getName());"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s4>Logger::debug(\"Processing user: \" + user->getName() + \" (ID: \" + user->getId() + \")\");"]
		} else {
			return ["    Logger::debug(\"Processing user: \" + user->getName() + \" (ID: \" + user->getId() + \")\");"]
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
			"std::future<User> loadUserData(int userId) {",
			"    // REPOMARK:SCOPE: 1 - Replace blocking call with async HTTP client",
			"    return std::async(std::launch::async, [userId]() {",
			"        HttpClient client;",
			"        auto response = client.get(\"/api/users/\" + std::to_string(userId));",
			"        ",
			"        if (response.status() == 200) {",
			"            return User::fromJson(response.body());",
			"        }",
			"        throw std::runtime_error(\"Failed to load user \" + std::to_string(userId));",
			"    });",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"void configureUI() {",
			"    // REPOMARK:SCOPE: 1 - Delete hard-coded color and add theme support",
			"    // ... existing code ...",
			"    backgroundColor = ThemeManager::instance()->getBackgroundColor();",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"class Player {",
			"private:",
			"    int currentHealth;",
			"    int maxHealth = 200;",
			"public:",
			"    void heal(int amount) {",
			"        // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"        currentHealth = std::min(currentHealth + amount, maxHealth);",
			"        // ... existing code ...",
			"    }",
			"};"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"class Player {",
			"public:",
			"    void heal(int amount) {",
			"        // REPOMARK:SCOPE: 1 - Cap health at maxHealth",
			"        currentHealth = std::min(currentHealth + amount, maxHealth);",
			"        // ... existing code ...",
			"    }",
			"    ",
			"    void collectBonus(const Bonus& bonus) {",
			"        // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"        score += bonus.value + 10;",
			"        // ... existing code ...",
			"    }",
			"};"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"void processOrder(Order& order) {",
			"    // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"    double subtotal = 0.0;",
			"    for (const auto& item : order.items) {",
			"        subtotal += item.price * item.quantity;",
			"    }",
			"    double tax = subtotal * getTaxRate(order.shippingAddress);",
			"    // Legacy discount logic removed",
			"    double total = subtotal + tax;",
			"    ",
			"    LOG_INFO << \"Order \" << order.id << \": subtotal=\" << subtotal",
			"             << \", tax=\" << tax << \", total=\" << total;",
			"    order.total = total;",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"class WorldGenerator {",
			"    // ... existing code ...",
			"    // REPOMARK:SCOPE: 1 - Replace generateStructures with randomized algorithm",
			"    void generateStructures() {",
			"        std::random_device rd;",
			"        std::mt19937 gen(rd());",
			"        std::uniform_int_distribution<> countDist(5, 15);",
			"        std::uniform_int_distribution<> xDist(0, worldWidth - 1);",
			"        std::uniform_int_distribution<> zDist(0, worldDepth - 1);",
			"        std::uniform_int_distribution<> typeDist(0, 2);",
			"        ",
			"        int structureCount = countDist(gen);",
			"        for (int i = 0; i < structureCount; ++i) {",
			"            int x = xDist(gen);",
			"            int z = zDist(gen);",
			"            auto type = static_cast<StructureType>(typeDist(gen));",
			"            placeStructure(x, z, type);",
			"        }",
			"    }",
			"    // ... existing code ...",
			"};"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"class GameManager {",
			"public:",
			"    // REPOMARK:SCOPE: 1 - Add onGameStateChanged callback property",
			"    std::function<void(GameState)> onGameStateChanged;",
			"    // ... existing code ...",
			"    ",
			"private:",
			"    GameState currentState;",
			"    int playerCount;",
			"    ",
			"    void init() {",
			"        std::cout << \"GameManager initializing...\" << std::endl;",
			"        loadGameData();",
			"    }",
			"    ",
			"    void update() {",
			"        handleInput();",
			"        updateGameState();",
			"    }",
			"    ",
			"    void loadGameData() {",
			"        // Load save data",
			"        auto saveData = SaveSystem::loadGame();",
			"        if (saveData) {",
			"            restoreGameState(*saveData);",
			"        }",
			"    }",
			"    ",
			"    void generateRandomLayout() {",
			"        // Generate world",
			"        for (int x = 0; x < 100; ++x) {",
			"            for (int y = 0; y < 100; ++y) {",
			"                tiles[x][y] = getRandomTile();",
			"            }",
			"        }",
			"    }",
			"};"
		]
	}
	
	public func commentSyntax() -> String {
		return "//"
	}
	
	// File editor examples use default implementation from protocol extension
	
	// MARK: - Rewrite-Only File Editor Example Methods
	
	public func fileEditorRewriteExampleFileContents() -> [String] {
		return [
			"#include <iostream>",
			"#include <vector>",
			"#include <string>",
			"#include <stdexcept>",
			"",
			"struct User {",
			"    std::string id;",
			"    std::string name;",
			"};",
			"",
			"class UserService {",
			"private:",
			"    std::vector<User> users;",
			"    ",
			"public:",
			"    UserService() {",
			"        // Initialize service",
			"    }",
			"    ",
			"    User processUser(const User& userData) {",
			"        // Process user data",
			"        User user;",
			"        user.id = userData.id;",
			"        user.name = userData.name;",
			"        return user;",
			"    }",
			"    ",
			"    void saveUser(const User& user) {",
			"        // Save user to database",
			"        users.push_back(user);",
			"    }",
			"};"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"    User processUser(const User& userData) {",
			"        // Add validation",
			"        if (userData.id.empty() || userData.name.empty()) {",
			"            throw std::invalid_argument(\"Invalid user data\");",
			"        }",
			"        ",
			"        // ... existing code ...",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"    void saveUser(const User& user) {",
			"        try {",
			"            // ... existing code ...",
			"            std::cout << \"User saved successfully\" << std::endl;",
			"        } catch (const std::exception& e) {",
			"            std::cerr << \"Failed to save user: \" << e.what() << std::endl;",
			"            throw;",
			"        }",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"#include <iostream>",
			"#include <vector>",
			"#include <string>",
			"#include <stdexcept>",
			"",
			"struct User {",
			"    std::string id;",
			"    std::string name;",
			"};",
			"",
			"class UserService {",
			"private:",
			"    std::vector<User> users;",
			"    ",
			"public:",
			"    UserService() {",
			"        // Initialize service",
			"    }",
			"    ",
			"    User processUser(const User& userData) {",
			"        // Add validation",
			"        if (userData.id.empty() || userData.name.empty()) {",
			"            throw std::invalid_argument(\"Invalid user data\");",
			"        }",
			"        ",
			"        // Process user data",
			"        User user;",
			"        user.id = userData.id;",
			"        user.name = userData.name;",
			"        return user;",
			"    }",
			"    ",
			"    void saveUser(const User& user) {",
			"        try {",
			"            // Save user to database",
			"            users.push_back(user);",
			"            std::cout << \"User saved successfully\" << std::endl;",
			"        } catch (const std::exception& e) {",
			"            std::cerr << \"Failed to save user: \" << e.what() << std::endl;",
			"            throw;",
			"        }",
			"    }",
			"};"
		]
	}
}