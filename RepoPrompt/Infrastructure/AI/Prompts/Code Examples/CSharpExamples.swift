//
//  CSharpExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * CSharpExamples implements CodeExamples for C#-specific snippets.
 */
public struct CSharpExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public class User",
				"<s0>{",
				"<s4>public Guid Id { get; set; }",
				"<s4>public string Name { get; set; }",
				"<s0>}"
			]
		} else {
			return [
				"public class User",
				"{",
				"    public Guid Id { get; set; }",
				"    public string Name { get; set; }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public class User",
				"<s0>{",
				"<s4>public Guid Id { get; set; }",
				"<s4>public string Name { get; set; }",
				"<s4>public string Email { get; set; }",
				"<s0>}"
			]
		} else {
			return [
				"public class User",
				"{",
				"    public Guid Id { get; set; }",
				"    public string Name { get; set; }",
				"    public string Email { get; set; }",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "Email" property
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>using System;",
				"<s0>",
				"<s0>namespace Models",
				"<s0>{",
				"<s4>public class User",
				"<s4>{",
				"<s8>public Guid Id { get; set; }",
				"<s8>public string Name { get; set; }",
				"<s8>public string Email { get; set; }",
				"<s8>",
				"<s8>public User(string name, string email)",
				"<s8>{",
				"<s12>Id = Guid.NewGuid();",
				"<s12>Name = name;",
				"<s12>Email = email;",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"using System;",
				"",
				"namespace Models",
				"{",
				"    public class User",
				"    {",
				"        public Guid Id { get; set; }",
				"        public string Name { get; set; }",
				"        public string Email { get; set; }",
				"",
				"        public User(string name, string email)",
				"        {",
				"            Id = Guid.NewGuid();",
				"            Name = name;",
				"            Email = email;",
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
				"<s0>using System.Windows;",
				"<s0>using System.Windows.Controls;",
				"<s0>",
				"<s0>namespace Views",
				"<s0>{",
				"<s4>public class RoundedButton : Button",
				"<s4>{",
				"<s8>public static readonly DependencyProperty CornerRadiusProperty =",
				"<s12>DependencyProperty.Register(\"CornerRadius\", typeof(double), typeof(RoundedButton));",
				"<s8>",
				"<s8>public double CornerRadius",
				"<s8>{",
				"<s12>get { return (double)GetValue(CornerRadiusProperty); }",
				"<s12>set { SetValue(CornerRadiusProperty, value); }",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"using System.Windows;",
				"using System.Windows.Controls;",
				"",
				"namespace Views",
				"{",
				"    public class RoundedButton : Button",
				"    {",
				"        public static readonly DependencyProperty CornerRadiusProperty =",
				"            DependencyProperty.Register(\"CornerRadius\", typeof(double), typeof(RoundedButton));",
				"",
				"        public double CornerRadius",
				"        {",
				"            get { return (double)GetValue(CornerRadiusProperty); }",
				"            set { SetValue(CornerRadiusProperty, value); }",
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 4) NetworkManager async/await conversion
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public void FetchData(string url, Action<string> completion)",
				"<s0>{",
				"<s4>using (var client = new WebClient())",
				"<s4>{",
				"<s8>client.DownloadStringCompleted += (sender, e) =>",
				"<s8>{",
				"<s12>completion(e.Result);",
				"<s8>};",
				"<s8>client.DownloadStringAsync(new Uri(url));",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"public void FetchData(string url, Action<string> completion)",
				"{",
				"    using (var client = new WebClient())",
				"    {",
				"        client.DownloadStringCompleted += (sender, e) =>",
				"        {",
				"            completion(e.Result);",
				"        };",
				"        client.DownloadStringAsync(new Uri(url));",
				"    }",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public async Task<string> FetchData(string url)",
				"<s0>{",
				"<s4>using (var client = new HttpClient())",
				"<s4>{",
				"<s8>return await client.GetStringAsync(url);",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"public async Task<string> FetchData(string url)",
				"{",
				"    using (var client = new HttpClient())",
				"    {",
				"        return await client.GetStringAsync(url);",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>namespace Services",
				"<s0>{",
				"<s4>public class UserService",
				"<s4>{",
				"<s8>private readonly ILogger _logger;",
				"<s8>",
				"<s8>public void ProcessUser(User user)",
				"<s8>{",
				"<s12>if (user == null)",
				"<s12>{",
				"<s16>throw new ArgumentNullException(nameof(user));",
				"<s12>}",
				"<s12>_logger.LogInfo($\"Processing user: {user.Name}\");",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"namespace Services",
				"{",
				"    public class UserService",
				"    {",
				"        private readonly ILogger _logger;",
				"",
				"        public void ProcessUser(User user)",
				"        {",
				"            if (user == null)",
				"            {",
				"                throw new ArgumentNullException(nameof(user));",
				"            }",
				"            _logger.LogInfo($\"Processing user: {user.Name}\");",
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing braces and different indentation
		if includeIndentation {
			return [
				"<s8>if (user == null)",
				"<s12>throw new ArgumentNullException(nameof(user));"
			]
		} else {
			return [
				"        if (user == null)",
				"            throw new ArgumentNullException(nameof(user));"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s8>if (user == null || string.IsNullOrEmpty(user.Name))",
				"<s8>{",
				"<s12>throw new ArgumentException(\"User is invalid\");",
				"<s8>}"
			]
		} else {
			return [
				"        if (user == null || string.IsNullOrEmpty(user.Name))",
				"        {",
				"            throw new ArgumentException(\"User is invalid\");",
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
				"<s12>}",
				"<s12>_logger.LogInfo($\"Processing user: {user.Name}\");",
				"<s8>}"
			]
		} else {
			return [
				"            }",
				"            _logger.LogInfo($\"Processing user: {user.Name}\");",
				"        }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<s12>}",
				"<s12>_logger.LogInfo($\"Processing user: {user.Name}\");",
				"<s12>// Additional processing",
				"<s12>ValidateUser(user);",
				"<s8>}",
				"<s8>}"  // Extra brace
			]
		} else {
			return [
				"            }",
				"            _logger.LogInfo($\"Processing user: {user.Name}\");",
				"            // Additional processing",
				"            ValidateUser(user);",
				"        }",
				"        }"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s12>_logger.LogInfo($\"Processing user: {user.Name}\");"]
		} else {
			return ["            _logger.LogInfo($\"Processing user: {user.Name}\");"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s12>_logger.LogDebug($\"Processing user: {user.Name} with ID: {user.Id}\");"]
		} else {
			return ["            _logger.LogDebug($\"Processing user: {user.Name} with ID: {user.Id}\");"]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		// Just closing braces - ambiguous
		if includeIndentation {
			return [
				"<s8>}",
				"<s4>}"
			]
		} else {
			return [
				"        }",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s8>}",
				"<s8>// TODO: Add more processing",
				"<s4>}"
			]
		} else {
			return [
				"        }",
				"        // TODO: Add more processing",
				"    }"
			]
		}
	}
	
	// MARK: Delegate Edit Examples
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"public async Task LoadUserData(int userId)",
			"{",
			"    // REPOMARK:SCOPE: 1 - Replace legacy networking with async/await",
			"    var response = await _httpClient.GetAsync($\"/api/users/{userId}\");",
			"    if (response.IsSuccessStatusCode)",
			"    {",
			"        var json = await response.Content.ReadAsStringAsync();",
			"        return JsonSerializer.Deserialize<User>(json);",
			"    }",
			"    throw new HttpRequestException($\"Failed to load user {userId}\");",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"private void ConfigureUI()",
			"{",
			"    // REPOMARK:SCOPE: 1 - Delete hard-coded color and add dark mode support",
			"    // ... existing code ...",
			"    BackgroundColor = ColorScheme.GetBackgroundColor(isDarkMode);",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"public class Player",
			"{",
			"    private int maxHealth = 200;",
			"    // ... existing code ...",
			"    public void Heal(int amount)",
			"    {",
			"        // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"        currentHealth = Math.Min(currentHealth + amount, maxHealth);",
			"        // ... existing code ...",
			"    }",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"public class Player",
			"{",
			"    private int maxHealth = 200;",
			"    // ... existing code ...",
			"    public void Heal(int amount)",
			"    {",
			"        // REPOMARK:SCOPE: 1 - Cap health at maxHealth",
			"        currentHealth = Math.Min(currentHealth + amount, maxHealth);",
			"        // ... existing code ...",
			"    }",
			"    // ... existing code ...",
			"    public void CollectBonus()",
			"    {",
			"        // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"        score += bonusValue + 10;",
			"        // ... existing code ...",
			"    }",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"public void ProcessOrder(Order order)",
			"{",
			"    // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"    var subtotal = order.Items.Sum(i => i.Price * i.Quantity);",
			"    var tax = subtotal * GetTaxRate(order.ShippingAddress);",
			"    // Legacy discount logic removed",
			"    var total = subtotal + tax;",
			"    ",
			"    _logger.LogInfo($\"Order {order.Id}: subtotal={subtotal}, tax={tax}, total={total}\");",
			"    order.Total = total;",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"public class WorldGenerator",
			"{",
			"    // ... existing code ...",
			"    // REPOMARK:SCOPE: 1 - Replace generateStructures with randomized algorithm",
			"    public void GenerateStructures()",
			"    {",
			"        var random = new Random();",
			"        var structureCount = random.Next(5, 15);",
			"        ",
			"        for (int i = 0; i < structureCount; i++)",
			"        {",
			"            var x = random.Next(0, worldWidth);",
			"            var z = random.Next(0, worldDepth);",
			"            var structureType = (StructureType)random.Next(0, 3);",
			"            ",
			"            PlaceStructure(x, z, structureType);",
			"        }",
			"    }",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"public class GameManager : MonoBehaviour",
			"{",
			"    // REPOMARK:SCOPE: 1 - Add onGameStateChanged callback property",
			"    public Action<GameState> OnGameStateChanged { get; set; }",
			"    // ... existing code ...",
			"    ",
			"    void Start()",
			"    {",
			"        Debug.Log(\"GameManager initializing...\");",
			"        LoadGameData();",
			"    }",
			"    ",
			"    void Update()",
			"    {",
			"        HandleInput();",
			"        UpdateGameState();",
			"    }",
			"    ",
			"    private void LoadGameData()",
			"    {",
			"        // Load save data",
			"        var saveData = SaveSystem.LoadGame();",
			"        if (saveData != null)",
			"        {",
			"            RestoreGameState(saveData);",
			"        }",
			"    }",
			"    ",
			"    private void GenerateRandomLayout()",
			"    {",
			"        // Generate world",
			"        for (int x = 0; x < 100; x++)",
			"        {",
			"            for (int y = 0; y < 100; y++)",
			"            {",
			"                tiles[x, y] = GetRandomTile();",
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
			"using System;",
			"using System.Collections.Generic;",
			"",
			"namespace Services",
			"{",
			"    public class UserService",
			"    {",
			"        private List<User> users;",
			"        ",
			"        public UserService()",
			"        {",
			"            users = new List<User>();",
			"        }",
			"        ",
			"        public User ProcessUser(UserData userData)",
			"        {",
			"            // Process user data",
			"            var user = new User",
			"            {",
			"                Id = userData.Id,",
			"                Name = userData.Name",
			"            };",
			"            return user;",
			"        }",
			"        ",
			"        public void SaveUser(User user)",
			"        {",
			"            // Save user to database",
			"            users.Add(user);",
			"        }",
			"    }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"        public User ProcessUser(UserData userData)",
			"        {",
			"            // Add validation",
			"            if (userData == null || string.IsNullOrEmpty(userData.Id) || string.IsNullOrEmpty(userData.Name))",
			"            {",
			"                throw new ArgumentException(\"Invalid user data\");",
			"            }",
			"            ",
			"            // ... existing code ...",
			"        }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"        public void SaveUser(User user)",
			"        {",
			"            try",
			"            {",
			"                // ... existing code ...",
			"                Console.WriteLine(\"User saved successfully\");",
			"            }",
			"            catch (Exception ex)",
			"            {",
			"                Console.Error.WriteLine($\"Failed to save user: {ex.Message}\");",
			"                throw;",
			"            }",
			"        }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"using System;",
			"using System.Collections.Generic;",
			"",
			"namespace Services",
			"{",
			"    public class UserService",
			"    {",
			"        private List<User> users;",
			"        ",
			"        public UserService()",
			"        {",
			"            users = new List<User>();",
			"        }",
			"        ",
			"        public User ProcessUser(UserData userData)",
			"        {",
			"            // Add validation",
			"            if (userData == null || string.IsNullOrEmpty(userData.Id) || string.IsNullOrEmpty(userData.Name))",
			"            {",
			"                throw new ArgumentException(\"Invalid user data\");",
			"            }",
			"            ",
			"            // Process user data",
			"            var user = new User",
			"            {",
			"                Id = userData.Id,",
			"                Name = userData.Name",
			"            };",
			"            return user;",
			"        }",
			"        ",
			"        public void SaveUser(User user)",
			"        {",
			"            try",
			"            {",
			"                // Save user to database",
			"                users.Add(user);",
			"                Console.WriteLine(\"User saved successfully\");",
			"            }",
			"            catch (Exception ex)",
			"            {",
			"                Console.Error.WriteLine($\"Failed to save user: {ex.Message}\");",
			"                throw;",
			"            }",
			"        }",
			"    }",
			"}"
		]
	}
}