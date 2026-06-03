//
//  PHPExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * PHPExamples implements CodeExamples for PHP-specific snippets.
 */
public struct PHPExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User",
				"<s0>{",
				"<s4>public $id;",
				"<s4>public $name;",
				"<s0>}"
			]
		} else {
			return [
				"class User",
				"{",
				"    public $id;",
				"    public $name;",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User",
				"<s0>{",
				"<s4>public $id;",
				"<s4>public $name;",
				"<s4>public $email;",
				"<s0>}"
			]
		} else {
			return [
				"class User",
				"{",
				"    public $id;",
				"    public $name;",
				"    public $email;",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "Email" property
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0><?php",
				"<s0>",
				"<s0>namespace Models;",
				"<s0>",
				"<s0>class User",
				"<s0>{",
				"<s4>public $id;",
				"<s4>public $name;",
				"<s4>public $email;",
				"<s4>",
				"<s4>public function __construct($name, $email)",
				"<s4>{",
				"<s8>$this->id = uniqid();",
				"<s8>$this->name = $name;",
				"<s8>$this->email = $email;",
				"<s4>}",
				"<s4>",
				"<s4>public function toArray()",
				"<s4>{",
				"<s8>return [",
				"<s12>'id' => $this->id,",
				"<s12>'name' => $this->name,",
				"<s12>'email' => $this->email,",
				"<s8>];",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"<?php",
				"",
				"namespace Models;",
				"",
				"class User",
				"{",
				"    public $id;",
				"    public $name;",
				"    public $email;",
				"",
				"    public function __construct($name, $email)",
				"    {",
				"        $this->id = uniqid();",
				"        $this->name = $name;",
				"        $this->email = $email;",
				"    }",
				"",
				"    public function toArray()",
				"    {",
				"        return [",
				"            'id' => $this->id,",
				"            'name' => $this->name,",
				"            'email' => $this->email,",
				"        ];",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" component
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0><?php",
				"<s0>",
				"<s0>namespace Components;",
				"<s0>",
				"<s0>class RoundedButton",
				"<s0>{",
				"<s4>private $text;",
				"<s4>private $onClick;",
				"<s4>private $borderRadius;",
				"<s4>private $backgroundColor;",
				"<s4>",
				"<s4>public function __construct($text, $onClick = null, $borderRadius = '8px', $backgroundColor = '#007bff')",
				"<s4>{",
				"<s8>$this->text = $text;",
				"<s8>$this->onClick = $onClick;",
				"<s8>$this->borderRadius = $borderRadius;",
				"<s8>$this->backgroundColor = $backgroundColor;",
				"<s4>}",
				"<s4>",
				"<s4>public function render()",
				"<s4>{",
				"<s8>$style = \"background-color: {$this->backgroundColor}; border-radius: {$this->borderRadius}; border: none; padding: 10px 20px; color: white; cursor: pointer;\";",
				"<s8>$onClickAttr = $this->onClick ? \"onclick='{$this->onClick}'\" : '';",
				"<s8>",
				"<s8>return \"<button style='$style' $onClickAttr>{$this->text}</button>\";",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"<?php",
				"",
				"namespace Components;",
				"",
				"class RoundedButton",
				"{",
				"    private $text;",
				"    private $onClick;",
				"    private $borderRadius;",
				"    private $backgroundColor;",
				"",
				"    public function __construct($text, $onClick = null, $borderRadius = '8px', $backgroundColor = '#007bff')",
				"    {",
				"        $this->text = $text;",
				"        $this->onClick = $onClick;",
				"        $this->borderRadius = $borderRadius;",
				"        $this->backgroundColor = $backgroundColor;",
				"    }",
				"",
				"    public function render()",
				"    {",
				"        $style = \"background-color: {$this->backgroundColor}; border-radius: {$this->borderRadius}; border: none; padding: 10px 20px; color: white; cursor: pointer;\";",
				"        $onClickAttr = $this->onClick ? \"onclick='{$this->onClick}'\" : '';",
				"",
				"        return \"<button style='$style' $onClickAttr>{$this->text}</button>\";",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 4) NetworkManager cURL to Guzzle conversion
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public function fetchData($url, $completion)",
				"<s0>{",
				"<s4>$ch = curl_init();",
				"<s4>curl_setopt($ch, CURLOPT_URL, $url);",
				"<s4>curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);",
				"<s4>$response = curl_exec($ch);",
				"<s4>curl_close($ch);",
				"<s4>$completion($response);",
				"<s0>}"
			]
		} else {
			return [
				"public function fetchData($url, $completion)",
				"{",
				"    $ch = curl_init();",
				"    curl_setopt($ch, CURLOPT_URL, $url);",
				"    curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);",
				"    $response = curl_exec($ch);",
				"    curl_close($ch);",
				"    $completion($response);",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public function fetchData($url)",
				"<s0>{",
				"<s4>$client = new \\GuzzleHttp\\Client();",
				"<s4>try {",
				"<s8>$response = $client->get($url);",
				"<s8>return $response->getBody()->getContents();",
				"<s4>} catch (\\Exception $e) {",
				"<s8>throw new \\Exception('Failed to fetch data: ' . $e->getMessage());",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"public function fetchData($url)",
				"{",
				"    $client = new \\GuzzleHttp\\Client();",
				"    try {",
				"        $response = $client->get($url);",
				"        return $response->getBody()->getContents();",
				"    } catch (\\Exception $e) {",
				"        throw new \\Exception('Failed to fetch data: ' . $e->getMessage());",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>namespace Services;",
				"<s0>",
				"<s0>class UserService",
				"<s0>{",
				"<s4>private $logger;",
				"<s4>",
				"<s4>public function processUser($user)",
				"<s4>{",
				"<s8>if ($user === null) {",
				"<s12>throw new \\InvalidArgumentException('User cannot be null');",
				"<s8>}",
				"<s8>$this->logger->info(\"Processing user: {$user->name}\");",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"namespace Services;",
				"",
				"class UserService",
				"{",
				"    private $logger;",
				"",
				"    public function processUser($user)",
				"    {",
				"        if ($user === null) {",
				"            throw new \\InvalidArgumentException('User cannot be null');",
				"        }",
				"        $this->logger->info(\"Processing user: {$user->name}\");",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing braces and different indentation
		if includeIndentation {
			return [
				"<s8>if ($user === null)",
				"<s12>throw new \\InvalidArgumentException('User cannot be null');"
			]
		} else {
			return [
				"        if ($user === null)",
				"            throw new \\InvalidArgumentException('User cannot be null');"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s8>if ($user === null || empty($user->name)) {",
				"<s12>throw new \\InvalidArgumentException('User is invalid');",
				"<s8>}"
			]
		} else {
			return [
				"        if ($user === null || empty($user->name)) {",
				"            throw new \\InvalidArgumentException('User is invalid');",
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
				"<s8>$this->logger->info(\"Processing user: {$user->name}\");",
				"<s4>}"
			]
		} else {
			return [
				"        }",
				"        $this->logger->info(\"Processing user: {$user->name}\");",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<s8>}",
				"<s8>$this->logger->info(\"Processing user: {$user->name}\");",
				"<s8>// Additional processing",
				"<s8>$this->validateUser($user);",
				"<s4>}",
				"<s4>}"  // Extra brace
			]
		} else {
			return [
				"        }",
				"        $this->logger->info(\"Processing user: {$user->name}\");",
				"        // Additional processing",
				"        $this->validateUser($user);",
				"    }",
				"    }"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s8>$this->logger->info(\"Processing user: {$user->name}\");"]
		} else {
			return ["        $this->logger->info(\"Processing user: {$user->name}\");"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s8>$this->logger->debug(\"Processing user: {$user->name} with ID: {$user->id}\");"]
		} else {
			return ["        $this->logger->debug(\"Processing user: {$user->name} with ID: {$user->id}\");"]
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
			"public function loadUserData($userId)",
			"{",
			"    // REPOMARK:SCOPE: 1 - Replace legacy networking with Guzzle HTTP client",
			"    $client = new \\GuzzleHttp\\Client();",
			"    $response = $client->get(\"/api/users/{$userId}\");",
			"    if ($response->getStatusCode() === 200) {",
			"        return json_decode($response->getBody()->getContents(), true);",
			"    }",
			"    throw new \\Exception(\"Failed to load user {$userId}\");",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"private function configureUI()",
			"{",
			"    // REPOMARK:SCOPE: 1 - Delete hard-coded color and add dark mode support",
			"    // ... existing code ...",
			"    $this->backgroundColor = ColorScheme::getBackgroundColor($this->isDarkMode);",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"class Player",
			"{",
			"    private $maxHealth = 200;",
			"    // ... existing code ...",
			"    public function heal($amount)",
			"    {",
			"        // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"        $this->currentHealth = min($this->currentHealth + $amount, $this->maxHealth);",
			"        // ... existing code ...",
			"    }",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"class Player",
			"{",
			"    private $maxHealth = 200;",
			"    // ... existing code ...",
			"    public function heal($amount)",
			"    {",
			"        // REPOMARK:SCOPE: 1 - Cap health at maxHealth",
			"        $this->currentHealth = min($this->currentHealth + $amount, $this->maxHealth);",
			"        // ... existing code ...",
			"    }",
			"    // ... existing code ...",
			"    public function collectBonus()",
			"    {",
			"        // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"        $this->score += $this->bonusValue + 10;",
			"        // ... existing code ...",
			"    }",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"public function processOrder($order)",
			"{",
			"    // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"    $subtotal = array_reduce($order->items, function($sum, $item) {",
			"        return $sum + ($item->price * $item->quantity);",
			"    }, 0);",
			"    $tax = $subtotal * $this->getTaxRate($order->shippingAddress);",
			"    // Legacy discount logic removed",
			"    $total = $subtotal + $tax;",
			"    ",
			"    $this->logger->info(\"Order {$order->id}: subtotal={$subtotal}, tax={$tax}, total={$total}\");",
			"    $order->total = $total;",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"class WorldGenerator",
			"{",
			"    // ... existing code ...",
			"    // REPOMARK:SCOPE: 1 - Replace generateStructures with randomized algorithm",
			"    public function generateStructures()",
			"    {",
			"        $structureCount = rand(5, 15);",
			"        ",
			"        for ($i = 0; $i < $structureCount; $i++) {",
			"            $x = rand(0, $this->worldWidth - 1);",
			"            $z = rand(0, $this->worldDepth - 1);",
			"            $structureType = array_rand(['HOUSE', 'TOWER', 'BRIDGE']);",
			"            ",
			"            $this->placeStructure($x, $z, $structureType);",
			"        }",
			"    }",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"class GameManager",
			"{",
			"    // REPOMARK:SCOPE: 1 - Add onGameStateChanged callback property",
			"    public $onGameStateChanged;",
			"    // ... existing code ...",
			"    ",
			"    public function start()",
			"    {",
			"        error_log('GameManager initializing...');",
			"        $this->loadGameData();",
			"    }",
			"    ",
			"    public function update()",
			"    {",
			"        $this->handleInput();",
			"        $this->updateGameState();",
			"    }",
			"    ",
			"    private function loadGameData()",
			"    {",
			"        // Load save data",
			"        $saveData = SaveSystem::loadGame();",
			"        if ($saveData !== null) {",
			"            $this->restoreGameState($saveData);",
			"        }",
			"    }",
			"    ",
			"    private function generateRandomLayout()",
			"    {",
			"        // Generate world",
			"        for ($x = 0; $x < 100; $x++) {",
			"            for ($y = 0; $y < 100; $y++) {",
			"                $this->tiles[$x][$y] = $this->getRandomTile();",
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
			"<?php",
			"",
			"class UserService",
			"{",
			"    private $users = [];",
			"    ",
			"    public function __construct()",
			"    {",
			"        // Initialize service",
			"    }",
			"    ",
			"    public function processUser($userData)",
			"    {",
			"        // Process user data",
			"        $user = [",
			"            'id' => $userData['id'],",
			"            'name' => $userData['name']",
			"        ];",
			"        return $user;",
			"    }",
			"    ",
			"    public function saveUser($user)",
			"    {",
			"        // Save user to database",
			"        $this->users[] = $user;",
			"    }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"    public function processUser($userData)",
			"    {",
			"        // Add validation",
			"        if (empty($userData) || empty($userData['id']) || empty($userData['name'])) {",
			"            throw new InvalidArgumentException('Invalid user data');",
			"        }",
			"        ",
			"        // ... existing code ...",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"    public function saveUser($user)",
			"    {",
			"        try {",
			"            // ... existing code ...",
			"            echo \"User saved successfully\\n\";",
			"        } catch (Exception $e) {",
			"            error_log('Failed to save user: ' . $e->getMessage());",
			"            throw $e;",
			"        }",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"<?php",
			"",
			"class UserService",
			"{",
			"    private $users = [];",
			"    ",
			"    public function __construct()",
			"    {",
			"        // Initialize service",
			"    }",
			"    ",
			"    public function processUser($userData)",
			"    {",
			"        // Add validation",
			"        if (empty($userData) || empty($userData['id']) || empty($userData['name'])) {",
			"            throw new InvalidArgumentException('Invalid user data');",
			"        }",
			"        ",
			"        // Process user data",
			"        $user = [",
			"            'id' => $userData['id'],",
			"            'name' => $userData['name']",
			"        ];",
			"        return $user;",
			"    }",
			"    ",
			"    public function saveUser($user)",
			"    {",
			"        try {",
			"            // Save user to database",
			"            $this->users[] = $user;",
			"            echo \"User saved successfully\\n\";",
			"        } catch (Exception $e) {",
			"            error_log('Failed to save user: ' . $e->getMessage());",
			"            throw $e;",
			"        }",
			"    }",
			"}"
		]
	}
}
