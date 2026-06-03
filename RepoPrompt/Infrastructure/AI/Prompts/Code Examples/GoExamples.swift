//
//  GoExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * GoExamples implements CodeExamples for Go-specific snippets.
 */
public struct GoExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" struct
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>type User struct {",
				"<t1>ID   string `json:\"id\"`",
				"<t1>Name string `json:\"name\"`",
				"<s0>}"
			]
		} else {
			return [
				"type User struct {",
				"\tID   string `json:\"id\"`",
				"\tName string `json:\"name\"`",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>type User struct {",
				"<t1>ID    string `json:\"id\"`",
				"<t1>Name  string `json:\"name\"`",
				"<t1>Email string `json:\"email\"`",
				"<s0>}"
			]
		} else {
			return [
				"type User struct {",
				"\tID    string `json:\"id\"`",
				"\tName  string `json:\"name\"`",
				"\tEmail string `json:\"email\"`",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "email" field
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>package models",
				"<s0>",
				"<s0>import (",
				"<t1>\"github.com/google/uuid\"",
				"<s0>)",
				"<s0>",
				"<s0>// User represents a user in the system",
				"<s0>type User struct {",
				"<t1>ID    string `json:\"id\"`",
				"<t1>Name  string `json:\"name\"`",
				"<t1>Email string `json:\"email\"`",
				"<s0>}",
				"<s0>",
				"<s0>// NewUser creates a new user with the given name and email",
				"<s0>func NewUser(name, email string) *User {",
				"<t1>return &User{",
				"<t2>ID:    uuid.New().String(),",
				"<t2>Name:  name,",
				"<t2>Email: email,",
				"<t1>}",
				"<s0>}"
			]
		} else {
			return [
				"package models",
				"",
				"import (",
				"\t\"github.com/google/uuid\"",
				")",
				"",
				"// User represents a user in the system",
				"type User struct {",
				"\tID    string `json:\"id\"`",
				"\tName  string `json:\"name\"`",
				"\tEmail string `json:\"email\"`",
				"}",
				"",
				"// NewUser creates a new user with the given name and email",
				"func NewUser(name, email string) *User {",
				"\treturn &User{",
				"\t\tID:    uuid.New().String(),",
				"\t\tName:  name,",
				"\t\tEmail: email,",
				"\t}",
				"}"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" file
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>package views",
				"<s0>",
				"<s0>import (",
				"<t1>\"fyne.io/fyne/v2\"",
				"<t1>\"fyne.io/fyne/v2/widget\"",
				"<s0>)",
				"<s0>",
				"<s0>// RoundedButton is a button with configurable corner radius",
				"<s0>type RoundedButton struct {",
				"<t1>widget.Button",
				"<t1>cornerRadius float32",
				"<s0>}",
				"<s0>",
				"<s0>// NewRoundedButton creates a new rounded button",
				"<s0>func NewRoundedButton(label string, tapped func()) *RoundedButton {",
				"<t1>btn := &RoundedButton{",
				"<t2>Button:       *widget.NewButton(label, tapped),",
				"<t2>cornerRadius: 0.0,",
				"<t1>}",
				"<t1>return btn",
				"<s0>}",
				"<s0>",
				"<s0>// SetCornerRadius sets the corner radius",
				"<s0>func (b *RoundedButton) SetCornerRadius(radius float32) {",
				"<t1>b.cornerRadius = radius",
				"<t1>b.Refresh()",
				"<s0>}"
			]
		} else {
			return [
				"package views",
				"",
				"import (",
				"\t\"fyne.io/fyne/v2\"",
				"\t\"fyne.io/fyne/v2/widget\"",
				")",
				"",
				"// RoundedButton is a button with configurable corner radius",
				"type RoundedButton struct {",
				"\twidget.Button",
				"\tcornerRadius float32",
				"}",
				"",
				"// NewRoundedButton creates a new rounded button",
				"func NewRoundedButton(label string, tapped func()) *RoundedButton {",
				"\tbtn := &RoundedButton{",
				"\t\tButton:       *widget.NewButton(label, tapped),",
				"\t\tcornerRadius: 0.0,",
				"\t}",
				"\treturn btn",
				"}",
				"",
				"// SetCornerRadius sets the corner radius",
				"func (b *RoundedButton) SetCornerRadius(radius float32) {",
				"\tb.cornerRadius = radius",
				"\tb.Refresh()",
				"}"
			]
		}
	}
	
	// MARK: 4) NetworkManager async/await conversion
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>func fetchData(url string, completion func(string)) {",
				"<t1>resp, err := http.Get(url)",
				"<t1>if err != nil {",
				"<t2>completion(\"\")",
				"<t2>return",
				"<t1>}",
				"<t1>defer resp.Body.Close()",
				"<t1>body, _ := ioutil.ReadAll(resp.Body)",
				"<t1>completion(string(body))",
				"<s0>}"
			]
		} else {
			return [
				"func fetchData(url string, completion func(string)) {",
				"\tresp, err := http.Get(url)",
				"\tif err != nil {",
				"\t\tcompletion(\"\")",
				"\t\treturn",
				"\t}",
				"\tdefer resp.Body.Close()",
				"\tbody, _ := ioutil.ReadAll(resp.Body)",
				"\tcompletion(string(body))",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>func fetchData(ctx context.Context, url string) (string, error) {",
				"<t1>req, err := http.NewRequestWithContext(ctx, \"GET\", url, nil)",
				"<t1>if err != nil {",
				"<t2>return \"\", err",
				"<t1>}",
				"<t1>resp, err := http.DefaultClient.Do(req)",
				"<t1>if err != nil {",
				"<t2>return \"\", err",
				"<t1>}",
				"<t1>defer resp.Body.Close()",
				"<t1>body, err := io.ReadAll(resp.Body)",
				"<t1>return string(body), err",
				"<s0>}"
			]
		} else {
			return [
				"func fetchData(ctx context.Context, url string) (string, error) {",
				"\treq, err := http.NewRequestWithContext(ctx, \"GET\", url, nil)",
				"\tif err != nil {",
				"\t\treturn \"\", err",
				"\t}",
				"\tresp, err := http.DefaultClient.Do(req)",
				"\tif err != nil {",
				"\t\treturn \"\", err",
				"\t}",
				"\tdefer resp.Body.Close()",
				"\tbody, err := io.ReadAll(resp.Body)",
				"\treturn string(body), err",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>package services",
				"<s0>",
				"<s0>import \"log\"",
				"<s0>",
				"<s0>func processUser(user *User) {",
				"<t1>if user == nil {",
				"<t2>log.Println(\"User is nil\")",
				"<t2>return",
				"<t1>}",
				"<t1>log.Printf(\"Processing user: %s\\n\", user.Name)",
				"<s0>}"
			]
		} else {
			return [
				"package services",
				"",
				"import \"log\"",
				"",
				"func processUser(user *User) {",
				"\tif user == nil {",
				"\t\tlog.Println(\"User is nil\")",
				"\t\treturn",
				"\t}",
				"\tlog.Printf(\"Processing user: %s\\n\", user.Name)",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing braces
		if includeIndentation {
			return [
				"<t1>if user == nil",
				"<t2>log.Println(\"User is nil\")"
			]
		} else {
			return [
				"\tif user == nil",
				"\t\tlog.Println(\"User is nil\")"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<t1>if user == nil || user.Name == \"\" {",
				"<t2>log.Println(\"User is invalid\")",
				"<t2>panic(\"invalid user\")",
				"<t1>}"
			]
		} else {
			return [
				"\tif user == nil || user.Name == \"\" {",
				"\t\tlog.Println(\"User is invalid\")",
				"\t\tpanic(\"invalid user\")",
				"\t}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		return userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<t1>}",
				"<t1>log.Printf(\"Processing user: %s\\n\", user.Name)",
				"<s0>}"
			]
		} else {
			return [
				"\t}",
				"\tlog.Printf(\"Processing user: %s\\n\", user.Name)",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<t1>}",
				"<t1>log.Printf(\"Processing user: %s\\n\", user.Name)",
				"<t1>// Additional validation",
				"<t1>validateUser(user)",
				"<s0>}",
				"<s0>}"  // Extra brace
			]
		} else {
			return [
				"\t}",
				"\tlog.Printf(\"Processing user: %s\\n\", user.Name)",
				"\t// Additional validation",
				"\tvalidateUser(user)",
				"}",
				"}"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<t1>log.Printf(\"Processing user: %s\\n\", user.Name)"]
		} else {
			return ["\tlog.Printf(\"Processing user: %s\\n\", user.Name)"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<t1>log.Printf(\"Processing user: %s (ID: %s)\\n\", user.Name, user.ID)"]
		} else {
			return ["\tlog.Printf(\"Processing user: %s (ID: %s)\\n\", user.Name, user.ID)"]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		// Just closing braces - ambiguous
		if includeIndentation {
			return [
				"<t1>}",
				"<s0>}"
			]
		} else {
			return [
				"\t}",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<t1>}",
				"<t1>// TODO: Add more processing",
				"<s0>}"
			]
		} else {
			return [
				"\t}",
				"\t// TODO: Add more processing",
				"}"
			]
		}
	}
	
	// MARK: Delegate Edit Examples
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"func loadUserData(userID int) (*User, error) {",
			"    // REPOMARK:SCOPE: 1 - Replace blocking call with context-aware request",
			"    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)",
			"    defer cancel()",
			"    ",
			"    url := fmt.Sprintf(\"/api/users/%d\", userID)",
			"    resp, err := client.GetWithContext(ctx, url)",
			"    if err != nil {",
			"        return nil, fmt.Errorf(\"failed to load user %d: %w\", userID, err)",
			"    }",
			"    ",
			"    var user User",
			"    if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {",
			"        return nil, err",
			"    }",
			"    return &user, nil",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"func configureUI() {",
			"    // REPOMARK:SCOPE: 1 - Delete hard-coded color and add theme support",
			"    // ... existing code ...",
			"    backgroundColor = theme.GetBackgroundColor(currentTheme)",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"type Player struct {",
			"    currentHealth int",
			"    maxHealth     int",
			"}",
			"",
			"func (p *Player) Heal(amount int) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"    p.currentHealth = min(p.currentHealth+amount, p.maxHealth)",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"func (p *Player) Heal(amount int) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth",
			"    p.currentHealth = min(p.currentHealth+amount, p.maxHealth)",
			"    // ... existing code ...",
			"}",
			"",
			"func (p *Player) CollectBonus(bonus *Bonus) {",
			"    // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"    p.score += bonus.value + 10",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"func processOrder(order *Order) {",
			"    // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"    var subtotal float64",
			"    for _, item := range order.Items {",
			"        subtotal += item.Price * float64(item.Quantity)",
			"    }",
			"    tax := subtotal * getTaxRate(order.ShippingAddress)",
			"    // Legacy discount logic removed",
			"    total := subtotal + tax",
			"    ",
			"    log.Printf(\"Order %d: subtotal=%.2f, tax=%.2f, total=%.2f\",",
			"        order.ID, subtotal, tax, total)",
			"    order.Total = total",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"// ... existing code ...",
			"// REPOMARK:SCOPE: 1 - Replace generateStructures with randomized algorithm",
			"func (w *WorldGenerator) generateStructures() {",
			"    rand.Seed(time.Now().UnixNano())",
			"    structureCount := rand.Intn(10) + 5",
			"    ",
			"    for i := 0; i < structureCount; i++ {",
			"        x := rand.Intn(w.worldWidth)",
			"        z := rand.Intn(w.worldDepth)",
			"        structureType := StructureType(rand.Intn(3))",
			"        ",
			"        w.placeStructure(x, z, structureType)",
			"    }",
			"}",
			"// ... existing code ..."
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"type GameManager struct {",
			"    // REPOMARK:SCOPE: 1 - Add onGameStateChanged callback property",
			"    OnGameStateChanged func(GameState)",
			"    // ... existing code ...",
			"    currentState GameState",
			"    playerCount  int",
			"}",
			"",
			"func (gm *GameManager) Init() {",
			"    fmt.Println(\"GameManager initializing...\")",
			"    gm.loadGameData()",
			"}",
			"",
			"func (gm *GameManager) Update() {",
			"    gm.handleInput()",
			"    gm.updateGameState()",
			"}",
			"",
			"func (gm *GameManager) loadGameData() {",
			"    // Load save data",
			"    saveData := SaveSystem.LoadGame()",
			"    if saveData != nil {",
			"        gm.restoreGameState(saveData)",
			"    }",
			"}",
			"",
			"func (gm *GameManager) generateRandomLayout() {",
			"    // Generate world",
			"    for x := 0; x < 100; x++ {",
			"        for y := 0; y < 100; y++ {",
			"            gm.tiles[x][y] = getRandomTile()",
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
			"package services",
			"",
			"import (",
			"    \"errors\"",
			"    \"fmt\"",
			")",
			"",
			"type UserService struct {",
			"    users []User",
			"}",
			"",
			"func NewUserService() *UserService {",
			"    return &UserService{",
			"        users: make([]User, 0),",
			"    }",
			"}",
			"",
			"func (s *UserService) ProcessUser(userData UserData) (User, error) {",
			"    // Process user data",
			"    user := User{",
			"        ID:   userData.ID,",
			"        Name: userData.Name,",
			"    }",
			"    return user, nil",
			"}",
			"",
			"func (s *UserService) SaveUser(user User) error {",
			"    // Save user to database",
			"    s.users = append(s.users, user)",
			"    return nil",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"func (s *UserService) ProcessUser(userData UserData) (User, error) {",
			"    // Add validation",
			"    if userData.ID == \"\" || userData.Name == \"\" {",
			"        return User{}, errors.New(\"invalid user data\")",
			"    }",
			"    ",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"func (s *UserService) SaveUser(user User) error {",
			"    // ... existing code ...",
			"    fmt.Println(\"User saved successfully\")",
			"    return nil",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"package services",
			"",
			"import (",
			"    \"errors\"",
			"    \"fmt\"",
			")",
			"",
			"type UserService struct {",
			"    users []User",
			"}",
			"",
			"func NewUserService() *UserService {",
			"    return &UserService{",
			"        users: make([]User, 0),",
			"    }",
			"}",
			"",
			"func (s *UserService) ProcessUser(userData UserData) (User, error) {",
			"    // Add validation",
			"    if userData.ID == \"\" || userData.Name == \"\" {",
			"        return User{}, errors.New(\"invalid user data\")",
			"    }",
			"    ",
			"    // Process user data",
			"    user := User{",
			"        ID:   userData.ID,",
			"        Name: userData.Name,",
			"    }",
			"    return user, nil",
			"}",
			"",
			"func (s *UserService) SaveUser(user User) error {",
			"    // Save user to database",
			"    s.users = append(s.users, user)",
			"    fmt.Println(\"User saved successfully\")",
			"    return nil",
			"}"
		]
	}
}