//
//  DartExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * DartExamples implements CodeExamples for Dart-specific snippets.
 */
public struct DartExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s2>final String id;",
				"<s2>final String name;",
				"<s0>}"
			]
		} else {
			return [
				"class User {",
				"  final String id;",
				"  final String name;",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s2>final String id;",
				"<s2>final String name;",
				"<s2>final String email;",
				"<s0>}"
			]
		} else {
			return [
				"class User {",
				"  final String id;",
				"  final String name;",
				"  final String email;",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "Email" property
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User {",
				"<s2>final String id;",
				"<s2>final String name;",
				"<s2>final String email;",
				"<s2>",
				"<s2>User({required this.id, required this.name, required this.email});",
				"<s2>",
				"<s2>factory User.fromJson(Map<String, dynamic> json) {",
				"<s4>return User(",
				"<s6>id: json['id'],",
				"<s6>name: json['name'],",
				"<s6>email: json['email'],",
				"<s4>);",
				"<s2>}",
				"<s2>",
				"<s2>Map<String, dynamic> toJson() {",
				"<s4>return {",
				"<s6>'id': id,",
				"<s6>'name': name,",
				"<s6>'email': email,",
				"<s4>};",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class User {",
				"  final String id;",
				"  final String name;",
				"  final String email;",
				"",
				"  User({required this.id, required this.name, required this.email});",
				"",
				"  factory User.fromJson(Map<String, dynamic> json) {",
				"    return User(",
				"      id: json['id'],",
				"      name: json['name'],",
				"      email: json['email'],",
				"    );",
				"  }",
				"",
				"  Map<String, dynamic> toJson() {",
				"    return {",
				"      'id': id,",
				"      'name': name,",
				"      'email': email,",
				"    };",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" widget
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import 'package:flutter/material.dart';",
				"<s0>",
				"<s0>class RoundedButton extends StatelessWidget {",
				"<s2>final String text;",
				"<s2>final VoidCallback? onPressed;",
				"<s2>final double borderRadius;",
				"<s2>final Color backgroundColor;",
				"<s2>",
				"<s2>const RoundedButton({",
				"<s4>Key? key,",
				"<s4>required this.text,",
				"<s4>this.onPressed,",
				"<s4>this.borderRadius = 8.0,",
				"<s4>this.backgroundColor = Colors.blue,",
				"<s2>}) : super(key: key);",
				"<s2>",
				"<s2>@override",
				"<s2>Widget build(BuildContext context) {",
				"<s4>return ElevatedButton(",
				"<s6>onPressed: onPressed,",
				"<s6>style: ElevatedButton.styleFrom(",
				"<s8>backgroundColor: backgroundColor,",
				"<s8>shape: RoundedRectangleBorder(",
				"<s10>borderRadius: BorderRadius.circular(borderRadius),",
				"<s8>),",
				"<s6>),",
				"<s6>child: Text(text),",
				"<s4>);",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"import 'package:flutter/material.dart';",
				"",
				"class RoundedButton extends StatelessWidget {",
				"  final String text;",
				"  final VoidCallback? onPressed;",
				"  final double borderRadius;",
				"  final Color backgroundColor;",
				"",
				"  const RoundedButton({",
				"    Key? key,",
				"    required this.text,",
				"    this.onPressed,",
				"    this.borderRadius = 8.0,",
				"    this.backgroundColor = Colors.blue,",
				"  }) : super(key: key);",
				"",
				"  @override",
				"  Widget build(BuildContext context) {",
				"    return ElevatedButton(",
				"      onPressed: onPressed,",
				"      style: ElevatedButton.styleFrom(",
				"        backgroundColor: backgroundColor,",
				"        shape: RoundedRectangleBorder(",
				"          borderRadius: BorderRadius.circular(borderRadius),",
				"        ),",
				"      ),",
				"      child: Text(text),",
				"    );",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: 4) NetworkManager async/await conversion
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>void fetchData(String url, Function(String) completion) {",
				"<s2>http.get(Uri.parse(url)).then((response) {",
				"<s4>if (response.statusCode == 200) {",
				"<s6>completion(response.body);",
				"<s4>} else {",
				"<s6>completion('Error: ${response.statusCode}');",
				"<s4>}",
				"<s2>}).catchError((error) {",
				"<s4>completion('Error: $error');",
				"<s2>});",
				"<s0>}"
			]
		} else {
			return [
				"void fetchData(String url, Function(String) completion) {",
				"  http.get(Uri.parse(url)).then((response) {",
				"    if (response.statusCode == 200) {",
				"      completion(response.body);",
				"    } else {",
				"      completion('Error: ${response.statusCode}');",
				"    }",
				"  }).catchError((error) {",
				"    completion('Error: $error');",
				"  });",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>Future<String> fetchData(String url) async {",
				"<s2>try {",
				"<s4>final response = await http.get(Uri.parse(url));",
				"<s4>if (response.statusCode == 200) {",
				"<s6>return response.body;",
				"<s4>} else {",
				"<s6>throw Exception('HTTP Error: ${response.statusCode}');",
				"<s4>}",
				"<s2>} catch (error) {",
				"<s4>throw Exception('Network Error: $error');",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"Future<String> fetchData(String url) async {",
				"  try {",
				"    final response = await http.get(Uri.parse(url));",
				"    if (response.statusCode == 200) {",
				"      return response.body;",
				"    } else {",
				"      throw Exception('HTTP Error: ${response.statusCode}');",
				"    }",
				"  } catch (error) {",
				"    throw Exception('Network Error: $error');",
				"  }",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class UserService {",
				"<s2>final ApiClient _apiClient;",
				"<s2>",
				"<s2>UserService(this._apiClient);",
				"<s2>",
				"<s2>Future<void> processUser(User user) async {",
				"<s4>if (user == null) {",
				"<s6>throw ArgumentError('User cannot be null');",
				"<s4>}",
				"<s4>print('Processing user: ${user.name}');",
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"class UserService {",
				"  final ApiClient _apiClient;",
				"",
				"  UserService(this._apiClient);",
				"",
				"  Future<void> processUser(User user) async {",
				"    if (user == null) {",
				"      throw ArgumentError('User cannot be null');",
				"    }",
				"    print('Processing user: ${user.name}');",
				"  }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing braces and different indentation
		if includeIndentation {
			return [
				"<s4>if (user == null)",
				"<s6>throw ArgumentError('User cannot be null');"
			]
		} else {
			return [
				"    if (user == null)",
				"      throw ArgumentError('User cannot be null');"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>if (user == null || user.name.isEmpty) {",
				"<s6>throw ArgumentError('User is invalid');",
				"<s4>}"
			]
		} else {
			return [
				"    if (user == null || user.name.isEmpty) {",
				"      throw ArgumentError('User is invalid');",
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
				"<s4>print('Processing user: ${user.name}');",
				"<s2>}"
			]
		} else {
			return [
				"    }",
				"    print('Processing user: ${user.name}');",
				"  }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>print('Processing user: ${user.name}');",
				"<s4>// Additional processing",
				"<s4>validateUser(user);",
				"<s2>}",
				"<s2>}"  // Extra brace
			]
		} else {
			return [
				"    }",
				"    print('Processing user: ${user.name}');",
				"    // Additional processing",
				"    validateUser(user);",
				"  }",
				"  }"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s4>print('Processing user: ${user.name}');"]
		} else {
			return ["    print('Processing user: ${user.name}');"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s4>print('Processing user: ${user.name} with ID: ${user.id}');"]
		} else {
			return ["    print('Processing user: ${user.name} with ID: ${user.id}');"]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		// Just closing braces - ambiguous
		if includeIndentation {
			return [
				"<s2>}",
				"<s0>}"
			]
		} else {
			return [
				"  }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s2>}",
				"<s2>// TODO: Add more processing",
				"<s0>}"
			]
		} else {
			return [
				"  }",
				"  // TODO: Add more processing",
				"}"
			]
		}
	}
	
	// MARK: Delegate Edit Examples
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"Future<User> loadUserData(int userId) async {",
			"  // REPOMARK:SCOPE: 1 - Replace legacy networking with async/await",
			"  final response = await _httpClient.get('/api/users/$userId');",
			"  if (response.statusCode == 200) {",
			"    return User.fromJson(jsonDecode(response.body));",
			"  }",
			"  throw Exception('Failed to load user $userId');",
			"  // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"void configureUI() {",
			"  // REPOMARK:SCOPE: 1 - Delete hard-coded color and add dark mode support",
			"  // ... existing code ...",
			"  backgroundColor = ColorScheme.getBackgroundColor(isDarkMode);",
			"  // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"class Player {",
			"  int maxHealth = 200;",
			"  // ... existing code ...",
			"  void heal(int amount) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"    currentHealth = math.min(currentHealth + amount, maxHealth);",
			"    // ... existing code ...",
			"  }",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"class Player {",
			"  int maxHealth = 200;",
			"  // ... existing code ...",
			"  void heal(int amount) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth",
			"    currentHealth = math.min(currentHealth + amount, maxHealth);",
			"    // ... existing code ...",
			"  }",
			"  // ... existing code ...",
			"  void collectBonus() {",
			"    // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"    score += bonusValue + 10;",
			"    // ... existing code ...",
			"  }",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"void processOrder(Order order) {",
			"  // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"  final subtotal = order.items.fold(0.0, (sum, item) => sum + item.price * item.quantity);",
			"  final tax = subtotal * getTaxRate(order.shippingAddress);",
			"  // Legacy discount logic removed",
			"  final total = subtotal + tax;",
			"  ",
			"  print('Order ${order.id}: subtotal=$subtotal, tax=$tax, total=$total');",
			"  order.total = total;",
			"  // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"class WorldGenerator {",
			"  // ... existing code ...",
			"  // REPOMARK:SCOPE: 1 - Replace generateStructures with randomized algorithm",
			"  void generateStructures() {",
			"    final random = Random();",
			"    final structureCount = random.nextInt(10) + 5;",
			"    ",
			"    for (int i = 0; i < structureCount; i++) {",
			"      final x = random.nextInt(worldWidth);",
			"      final z = random.nextInt(worldDepth);",
			"      final structureType = StructureType.values[random.nextInt(3)];",
			"      ",
			"      placeStructure(x, z, structureType);",
			"    }",
			"  }",
			"  // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"class GameManager {",
			"  // REPOMARK:SCOPE: 1 - Add onGameStateChanged callback property",
			"  Function(GameState)? onGameStateChanged;",
			"  // ... existing code ...",
			"  ",
			"  void start() {",
			"    print('GameManager initializing...');",
			"    loadGameData();",
			"  }",
			"  ",
			"  void update() {",
			"    handleInput();",
			"    updateGameState();",
			"  }",
			"  ",
			"  void loadGameData() {",
			"    // Load save data",
			"    final saveData = SaveSystem.loadGame();",
			"    if (saveData != null) {",
			"      restoreGameState(saveData);",
			"    }",
			"  }",
			"  ",
			"  void generateRandomLayout() {",
			"    // Generate world",
			"    for (int x = 0; x < 100; x++) {",
			"      for (int y = 0; y < 100; y++) {",
			"        tiles[x][y] = getRandomTile();",
			"      }",
			"    }",
			"  }",
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
			"class User {",
			"  final String id;",
			"  final String name;",
			"  ",
			"  User({required this.id, required this.name});",
			"}",
			"",
			"class UserService {",
			"  final List<User> _users = [];",
			"  ",
			"  UserService() {",
			"    // Initialize service",
			"  }",
			"  ",
			"  User processUser(Map<String, dynamic> userData) {",
			"    // Process user data",
			"    final user = User(",
			"      id: userData['id'],",
			"      name: userData['name'],",
			"    );",
			"    return user;",
			"  }",
			"  ",
			"  void saveUser(User user) {",
			"    // Save user to database",
			"    _users.add(user);",
			"  }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"  User processUser(Map<String, dynamic> userData) {",
			"    // Add validation",
			"    if (userData['id'] == null || userData['name'] == null ||",
			"        userData['id'].isEmpty || userData['name'].isEmpty) {",
			"      throw ArgumentError('Invalid user data');",
			"    }",
			"    ",
			"    // ... existing code ...",
			"  }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"  void saveUser(User user) {",
			"    try {",
			"      // ... existing code ...",
			"      print('User saved successfully');",
			"    } catch (e) {",
			"      print('Failed to save user: $e');",
			"      rethrow;",
			"    }",
			"  }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"class User {",
			"  final String id;",
			"  final String name;",
			"  ",
			"  User({required this.id, required this.name});",
			"}",
			"",
			"class UserService {",
			"  final List<User> _users = [];",
			"  ",
			"  UserService() {",
			"    // Initialize service",
			"  }",
			"  ",
			"  User processUser(Map<String, dynamic> userData) {",
			"    // Add validation",
			"    if (userData['id'] == null || userData['name'] == null ||",
			"        userData['id'].isEmpty || userData['name'].isEmpty) {",
			"      throw ArgumentError('Invalid user data');",
			"    }",
			"    ",
			"    // Process user data",
			"    final user = User(",
			"      id: userData['id'],",
			"      name: userData['name'],",
			"    );",
			"    return user;",
			"  }",
			"  ",
			"  void saveUser(User user) {",
			"    try {",
			"      // Save user to database",
			"      _users.add(user);",
			"      print('User saved successfully');",
			"    } catch (e) {",
			"      print('Failed to save user: $e');",
			"      rethrow;",
			"    }",
			"  }",
			"}"
		]
	}
}
