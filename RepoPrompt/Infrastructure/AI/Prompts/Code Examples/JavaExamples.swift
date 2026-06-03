//
//  JavaExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * JavaExamples implements CodeExamples for Java-specific snippets.
 */
public struct JavaExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public class User {",
				"<s4>private UUID id;",
				"<s4>private String name;",
				"<s0>}"
			]
		} else {
			return [
				"public class User {",
				"    private UUID id;",
				"    private String name;",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public class User {",
				"<s4>private UUID id;",
				"<s4>private String name;",
				"<s4>private String email;",
				"<s0>}"
			]
		} else {
			return [
				"public class User {",
				"    private UUID id;",
				"    private String name;",
				"    private String email;",
				"}"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "email" field
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import java.util.UUID;",
				"<s0>",
				"<s0>public class User {",
				"<s4>private final UUID id;",
				"<s4>private String name;",
				"<s4>private String email;",
				"<s4>",
				"<s4>public User(String name, String email) {",
				"<s8>this.id = UUID.randomUUID();",
				"<s8>this.name = name;",
				"<s8>this.email = email;",
				"<s4>}",
				"<s4>",
				"<s4>public UUID getId() {",
				"<s8>return id;",
				"<s4>}",
				"<s4>",
				"<s4>public String getName() {",
				"<s8>return name;",
				"<s4>}",
				"<s4>",
				"<s4>public void setName(String name) {",
				"<s8>this.name = name;",
				"<s4>}",
				"<s4>",
				"<s4>public String getEmail() {",
				"<s8>return email;",
				"<s4>}",
				"<s4>",
				"<s4>public void setEmail(String email) {",
				"<s8>this.email = email;",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"import java.util.UUID;",
				"",
				"public class User {",
				"    private final UUID id;",
				"    private String name;",
				"    private String email;",
				"    ",
				"    public User(String name, String email) {",
				"        this.id = UUID.randomUUID();",
				"        this.name = name;",
				"        this.email = email;",
				"    }",
				"    ",
				"    public UUID getId() {",
				"        return id;",
				"    }",
				"    ",
				"    public String getName() {",
				"        return name;",
				"    }",
				"    ",
				"    public void setName(String name) {",
				"        this.name = name;",
				"    }",
				"    ",
				"    public String getEmail() {",
				"        return email;",
				"    }",
				"    ",
				"    public void setEmail(String email) {",
				"        this.email = email;",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 3) Create a new "RoundedButton" file
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import javax.swing.JButton;",
				"<s0>import java.awt.Graphics;",
				"<s0>import java.awt.Graphics2D;",
				"<s0>import java.awt.RenderingHints;",
				"<s0>",
				"<s0>public class RoundedButton extends JButton {",
				"<s4>private int cornerRadius = 0;",
				"<s4>",
				"<s4>public RoundedButton(String text) {",
				"<s8>super(text);",
				"<s8>setOpaque(false);",
				"<s4>}",
				"<s4>",
				"<s4>public void setCornerRadius(int cornerRadius) {",
				"<s8>this.cornerRadius = cornerRadius;",
				"<s8>repaint();",
				"<s4>}",
				"<s4>",
				"<s4>@Override",
				"<s4>protected void paintComponent(Graphics g) {",
				"<s8>Graphics2D g2 = (Graphics2D) g.create();",
				"<s8>g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);",
				"<s8>g2.fillRoundRect(0, 0, getWidth()-1, getHeight()-1, cornerRadius, cornerRadius);",
				"<s8>super.paintComponent(g2);",
				"<s8>g2.dispose();",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"import javax.swing.JButton;",
				"import java.awt.Graphics;",
				"import java.awt.Graphics2D;",
				"import java.awt.RenderingHints;",
				"",
				"public class RoundedButton extends JButton {",
				"    private int cornerRadius = 0;",
				"    ",
				"    public RoundedButton(String text) {",
				"        super(text);",
				"        setOpaque(false);",
				"    }",
				"    ",
				"    public void setCornerRadius(int cornerRadius) {",
				"        this.cornerRadius = cornerRadius;",
				"        repaint();",
				"    }",
				"    ",
				"    @Override",
				"    protected void paintComponent(Graphics g) {",
				"        Graphics2D g2 = (Graphics2D) g.create();",
				"        g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);",
				"        g2.fillRoundRect(0, 0, getWidth()-1, getHeight()-1, cornerRadius, cornerRadius);",
				"        super.paintComponent(g2);",
				"        g2.dispose();",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 4) Indentation-Preserving Example (async/await equivalent using CompletableFuture)
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public class NetworkManager {",
				"<s4>public void fetchData(URL url, Consumer<byte[]> callback) {",
				"<s8>// old synchronous code",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"public class NetworkManager {",
				"    public void fetchData(URL url, Consumer<byte[]> callback) {",
				"        // old synchronous code",
				"    }",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public class NetworkManager {",
				"<s4>public CompletableFuture<byte[]> fetchData(URL url) {",
				"<s8>return CompletableFuture.supplyAsync(() -> {",
				"<s12>try {",
				"<s16>HttpURLConnection conn = (HttpURLConnection) url.openConnection();",
				"<s16>return conn.getInputStream().readAllBytes();",
				"<s12>} catch (IOException e) {",
				"<s16>throw new CompletionException(e);",
				"<s12>}",
				"<s8>});",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"public class NetworkManager {",
				"    public CompletableFuture<byte[]> fetchData(URL url) {",
				"        return CompletableFuture.supplyAsync(() -> {",
				"            try {",
				"                HttpURLConnection conn = (HttpURLConnection) url.openConnection();",
				"                return conn.getInputStream().readAllBytes();",
				"            } catch (IOException e) {",
				"                throw new CompletionException(e);",
				"            }",
				"        });",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: - Negative Examples for Search/Replace
	
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import java.util.*;",
				"<s0>public class Example {",
				"<s0>    void foo() {",
				"<s0>        bar();",
				"<s0>    }",
				"<s0>}"
			]
		} else {
			return [
				"import java.util.*;",
				"public class Example {",
				"    void foo() {",
				"        bar();",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>void foo() {",
				"<s8>bar();",
				"<s4>}"
			]
		} else {
			return [
				"    void foo() {",
				"        bar();",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>void foo() {",
				"<s8>bar();",
				"<s8>bar2();",
				"<s4>}"
			]
		} else {
			return [
				"    void foo() {",
				"        bar();",
				"        bar2();",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>public void someMethod() {",
				"<s4>foo() {",
				"<s8>bar();",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"public void someMethod() {",
				"    foo() {",
				"        bar();",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>foo() {",
				"<s8>bar();",
				"<s4>}"
			]
		} else {
			return [
				"    foo() {",
				"        bar();",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>foo() {",
				"<s8>bar();",
				"<s4>}",
				"",
				"<s4>baz() {",
				"<s8>foo2();",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"    foo() {",
				"        bar();",
				"    }",
				"",
				"    baz() {",
				"        foo2();",
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>private String email;"
			]
		} else {
			return [
				"private String email;"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>private String emailAddress;"
			]
		} else {
			return [
				"private String emailAddress;"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
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
				"<s8>foo() {",
				"<s8>}",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"        foo() {",
				"        }",
				"    }",
				"}"
			]
		}
	}
	
	// MARK: 5) Delegate Edit – Complex Replacement
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"public void loadUserData() throws Exception {",
			"    // <rm legacy networking>",
			"    NetworkService.requestOld(Endpoint.USER, new Callback() {",
			"        public void onResponse(byte[] data) {",
			"            // old callback logic",
			"        }",
			"    });",
			"    // </rm>",
			"",
			"    // <add async networking>",
			"    byte[] data = api.fetchUser().get();",
			"    handle(data);",
			"    // </add>",
			"}"
		]
	}

	// MARK: 6) Delegate Edit – Addition + Deletion
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"private void configureUI() {",
			"    // existing setup code",
			"",
			"    // <rm old color assignment>",
			"    panel.setBackground(Color.WHITE);",
			"    // </rm>",
			"",
			"    // ... other mid-section code ...",
			"",
			"    // <add theme-aware color>",
			"    panel.setBackground(ThemeManager.getBackgroundColor());",
			"    // </add>",
			"}"
		]
	}
	
	// MARK: 7) New Delegate Edit Examples
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"public void heal(int amount) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"    currentHealth = Math.min(currentHealth + amount, maxHealth);",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"public void heal(int amount) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at maxHealth instead of 999",
			"    currentHealth = Math.min(currentHealth + amount, maxHealth);",
			"}",
			"// ... existing code ...",
			"public void collectItem() {",
			"    // REPOMARK:SCOPE: 2 - Add bonus score when collecting items",
			"    score += itemValue + 10;",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"public void processOrder(Order order) {",
			"    validateOrder(order);",
			"    // REPOMARK:SCOPE: 1 - Update tax calculation, remove legacy discount, add logging",
			"    double subtotal = order.getItems().stream()",
			"        .mapToDouble(Item::getPrice)",
			"        .sum();",
			"    double tax = subtotal * 0.0875;  // Updated from 0.08",
			"    // Removed: double discount = subtotal * 0.05;",
			"    double total = subtotal + tax;",
			"    System.out.println(\"Order total: \" + total);",
			"    order.setTotal(total);",
			"    saveOrder(order);",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"public class WorldGenerator {",
			"    private List<Structure> structures = new ArrayList<>();",
			"    ",
			"    // REPOMARK:SCOPE: 1 - Replace entire generateStructures method with randomized algorithm",
			"    public void generateStructures() {",
			"        StructureType[] types = {StructureType.HOUSE, StructureType.TREE, StructureType.ROCK};",
			"        Random random = new Random();",
			"        for (int i = 0; i < 10; i++) {",
			"            StructureType randomType = types[random.nextInt(types.length)];",
			"            int x = random.nextInt(worldSize);",
			"            int y = random.nextInt(worldSize);",
			"            structures.add(new Structure(randomType, x, y));",
			"        }",
			"    }",
			"    ",
			"    public void clearStructures() {",
			"        structures.clear();",
			"    }",
			"}"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"public class GameManager extends Activity {",
			"    // REPOMARK:SCOPE: 1 - Add callback property and initialization/data loading logging",
			"    private Consumer<GameState> onGameStateChanged;",
			"    ",
			"    private GameState currentState = GameState.MENU;",
			"    private int score = 0;",
			"    ",
			"    @Override",
			"    protected void onCreate(Bundle savedInstanceState) {",
			"        super.onCreate(savedInstanceState);",
			"        System.out.println(\"GameManager initialized\");",
			"        setupUI();",
			"        loadGameData();",
			"    }",
			"    ",
			"    private void loadGameData() {",
			"        System.out.println(\"Loading game data...\");",
			"        // Load saved state",
			"        SharedPreferences prefs = getSharedPreferences(\"gameData\", MODE_PRIVATE);",
			"        if (prefs.contains(\"savedData\")) {",
			"            // Decode and apply",
			"        }",
			"        System.out.println(\"Game data loaded\");",
			"    }",
			"    ",
			"    private void generateRandomLayout() {",
			"        // This method is unchanged",
			"        Random random = new Random();",
			"        for (int i = 0; i < 10; i++) {",
			"            int x = random.nextInt(100);",
			"            int y = random.nextInt(100);",
			"            placeObject(x, y);",
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
			"import java.util.ArrayList;",
			"import java.util.List;",
			"",
			"public class UserService {",
			"    private List<User> users;",
			"    ",
			"    public UserService() {",
			"        this.users = new ArrayList<>();",
			"    }",
			"    ",
			"    public User processUser(UserData userData) {",
			"        // Process user data",
			"        User user = new User(",
			"            userData.getId(),",
			"            userData.getName()",
			"        );",
			"        return user;",
			"    }",
			"    ",
			"    public void saveUser(User user) {",
			"        // Save user to database",
			"        users.add(user);",
			"    }",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"    public User processUser(UserData userData) {",
			"        // Add validation",
			"        if (userData == null || userData.getId() == null || userData.getName() == null) {",
			"            throw new IllegalArgumentException(\"Invalid user data\");",
			"        }",
			"        ",
			"        // ... existing code ...",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"    public void saveUser(User user) {",
			"        try {",
			"            // ... existing code ...",
			"            System.out.println(\"User saved successfully\");",
			"        } catch (Exception e) {",
			"            System.err.println(\"Failed to save user: \" + e.getMessage());",
			"            throw e;",
			"        }",
			"    }"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"import java.util.ArrayList;",
			"import java.util.List;",
			"",
			"public class UserService {",
			"    private List<User> users;",
			"    ",
			"    public UserService() {",
			"        this.users = new ArrayList<>();",
			"    }",
			"    ",
			"    public User processUser(UserData userData) {",
			"        // Add validation",
			"        if (userData == null || userData.getId() == null || userData.getName() == null) {",
			"            throw new IllegalArgumentException(\"Invalid user data\");",
			"        }",
			"        ",
			"        // Process user data",
			"        User user = new User(",
			"            userData.getId(),",
			"            userData.getName()",
			"        );",
			"        return user;",
			"    }",
			"    ",
			"    public void saveUser(User user) {",
			"        try {",
			"            // Save user to database",
			"            users.add(user);",
			"            System.out.println(\"User saved successfully\");",
			"        } catch (Exception e) {",
			"            System.err.println(\"Failed to save user: \" + e.getMessage());",
			"            throw e;",
			"        }",
			"    }",
			"}"
		]
	}
}