//
//  PythonExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * PythonExamples implements CodeExamples for Python-specific snippets.
 */
public struct PythonExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" class
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User:",
				"<s4>def __init__(self, id, name):",
				"<s8>self.id = id",
				"<s8>self.name = name"
			]
		} else {
			return [
				"class User:",
				"    def __init__(self, id, name):",
				"        self.id = id",
				"        self.name = name"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>class User:",
				"<s4>def __init__(self, id, name, email):",
				"<s8>self.id = id",
				"<s8>self.name = name",
				"<s8>self.email = email"
			]
		} else {
			return [
				"class User:",
				"    def __init__(self, id, name, email):",
				"        self.id = id",
				"        self.name = name",
				"        self.email = email"
			]
		}
	}
	
	// MARK: 2) Rewrite All Lines
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>from datetime import datetime",
				"<s0>",
				"<s0>class User:",
				"<s4>def __init__(self, id, name, email, role='user'):",
				"<s8>self.id = id",
				"<s8>self.name = name",
				"<s8>self.email = email",
				"<s8>self.role = role",
				"<s8>self.created_at = datetime.now()",
				"<s4>",
				"<s4>def get_display_name(self):",
				"<s8>return f\"{self.name} ({self.email})\""
			]
		} else {
			return [
				"from datetime import datetime",
				"",
				"class User:",
				"    def __init__(self, id, name, email, role='user'):",
				"        self.id = id",
				"        self.name = name",
				"        self.email = email",
				"        self.role = role",
				"        self.created_at = datetime.now()",
				"    ",
				"    def get_display_name(self):",
				"        return f\"{self.name} ({self.email})\""
			]
		}
	}
	
	// MARK: 3) Create All Lines
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0># models/user.py",
				"<s0>from dataclasses import dataclass",
				"<s0>from typing import Dict, Any",
				"<s0>",
				"<s0>@dataclass",
				"<s0>class User:",
				"<s4>id: str",
				"<s4>name: str",
				"<s4>email: str",
				"<s4>",
				"<s4>def to_dict(self) -> Dict[str, Any]:",
				"<s8>return {",
				"<s12>'id': self.id,",
				"<s12>'name': self.name,",
				"<s12>'email': self.email",
				"<s8>}"
			]
		} else {
			return [
				"# models/user.py",
				"from dataclasses import dataclass",
				"from typing import Dict, Any",
				"",
				"@dataclass",
				"class User:",
				"    id: str",
				"    name: str",
				"    email: str",
				"    ",
				"    def to_dict(self) -> Dict[str, Any]:",
				"        return {",
				"            'id': self.id,",
				"            'name': self.name,",
				"            'email': self.email",
				"        }"
			]
		}
	}
	
	// MARK: 4) NetworkManager Example
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import requests",
				"<s0>",
				"<s0>class APIClient:",
				"<s4>def fetch_data(self, endpoint):",
				"<s8>response = requests.get(endpoint)",
				"<s8>return response.json()"
			]
		} else {
			return [
				"import requests",
				"",
				"class APIClient:",
				"    def fetch_data(self, endpoint):",
				"        response = requests.get(endpoint)",
				"        return response.json()"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>import requests",
				"<s0>import logging",
				"<s0>",
				"<s0>class APIClient:",
				"<s4>def fetch_data(self, endpoint, **kwargs):",
				"<s8>try:",
				"<s12>headers = kwargs.get('headers', {})",
				"<s12>headers['Content-Type'] = 'application/json'",
				"<s12>",
				"<s12>response = requests.get(endpoint, headers=headers, **kwargs)",
				"<s12>response.raise_for_status()",
				"<s12>",
				"<s12>return response.json()",
				"<s8>except requests.RequestException as e:",
				"<s12>logging.error(f'API request failed: {e}')",
				"<s12>raise"
			]
		} else {
			return [
				"import requests",
				"import logging",
				"",
				"class APIClient:",
				"    def fetch_data(self, endpoint, **kwargs):",
				"        try:",
				"            headers = kwargs.get('headers', {})",
				"            headers['Content-Type'] = 'application/json'",
				"            ",
				"            response = requests.get(endpoint, headers=headers, **kwargs)",
				"            response.raise_for_status()",
				"            ",
				"            return response.json()",
				"        except requests.RequestException as e:",
				"            logging.error(f'API request failed: {e}')",
				"            raise"
			]
		}
	}
	
	// MARK: 5) Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		return [
			"class User:",
			"    def __init__(self, id, name):",
			"        self.id = id",
			"        self.name = name",
			"        self.is_active = True",
			"    ",
			"    def get_info(self):",
			"        return f\"User: {self.name}\""
		]
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		return [
			"    def __init__(self, id, name):",
			"        self.id = id",
			"        self.name = name"
		]
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		return [
			"    def __init__(self, id, name, email):",
			"        self.id = id",
			"        self.name = name",
			"        self.email = email"
		]
	}
	
	// Brace mismatch example (Python uses indentation)
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		return [
			"def process_data(items):",
			"    if len(items) > 0:",
			"        for item in items:",
			"            print(item)",
			"    return len(items)"
		]
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		return [
			"    if len(items) > 0:",
			"        for item in items:",
			"            print(item)"
		]
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		return [
			"    if len(items) > 0:",
			"        print(f'Processing {len(items)} items')",
			"        for item in items:",
			"            print(item)"
		]
	}
	
	// One-line search block
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		return ["print(item)"]
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		return ["print('Item:', item)"]
	}
	
	// Ambiguous search block
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		return ["return"]
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		return [
			"    logging.debug('Processing complete')",
			"    return"
		]
	}
	
	// MARK: 6) Delegate Edit Examples
	
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"class GameEngine:",
			"    def __init__(self):",
			"        self.score = 0",
			"        self.level = 1",
			"    ",
			"    # DELETE THIS METHOD",
			"    def old_update(self):",
			"        # Legacy update logic",
			"        pass",
			"    ",
			"    # ADD NEW METHOD BELOW",
			"    def update(self, delta_time):",
			"        # Modern update with delta time",
			"        self.update_physics(delta_time)",
			"        self.update_graphics(delta_time)"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"class Player:",
			"    def __init__(self, name):",
			"        self.name = name",
			"        # DELETE the next line",
			"        self.x = 0; self.y = 0  # old position tracking",
			"        # ADD position dict instead",
			"        self.position = {'x': 0, 'y': 0}",
			"        self.health = 100",
			"    ",
			"    def move(self, dx, dy):",
			"        # DELETE old movement",
			"        # self.x += dx",
			"        # self.y += dy",
			"        # ADD new movement",
			"        self.position['x'] += dx",
			"        self.position['y'] += dy"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"# REPOMARK:SCOPE: 1 - Add validation check at start of heal() and print statement after health update",
			"def heal(self, amount):",
			"    if amount <= 0: return  # Added validation",
			"    # ... existing code ...",
			"    self.current_health = min(self.current_health + amount, self.max_health)",
			"    print(f'Healed for {amount}')  # Added logging",
			"    # ... existing code ..."
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"# REPOMARK:SCOPE: 1 - Add validation check at start of heal() and print statement after health update",
			"def heal(self, amount):",
			"    if amount <= 0: return  # Added validation",
			"    # ... existing code ...",
			"    self.current_health = min(self.current_health + amount, self.max_health)",
			"    # ... existing code ...",
			"",
			"# ... existing code ...",
			"",
			"# REPOMARK:SCOPE: 2 - Add print statement after score calculation in update_score()",
			"def update_score(self, points):",
			"    # ... existing code ...",
			"    self.score += points",
			"    print(f'Score updated: {self.score}')  # Added",
			"    # ... existing code ..."
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"# REPOMARK:SCOPE: 1 - Add validation at start, print before processing, and email sending after receipt generation",
			"async def process_order(self, order):",
			"    # Validate order first (added)",
			"    if not order or not order.items:",
			"        raise ValueError('Invalid order: must contain items')",
			"    ",
			"    print(f'Processing order {order.id}...')  # Added logging",
			"    # ... existing code ...",
			"    receipt = await self.generate_receipt(order)",
			"    ",
			"    # Send confirmation email (added)",
			"    if hasattr(order, 'customer_email'):",
			"        await self.email_service.send_confirmation(order.customer_email, receipt)",
			"    ",
			"    # ... existing code ...",
			"    return receipt"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"# REPOMARK:SCOPE: 1 - Replace entire generate_structures() method body with new randomized algorithm",
			"def generate_structures(self):",
			"    import random",
			"    y = 0",
			"    for level in range(random.randint(2, 6)):",
			"        height = random.uniform(0.3, 1.0)",
			"        offset = random.uniform(-0.05, 0.05)",
			"        # assemble level with new algorithm",
			"        y += height + offset"
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"# ❌ NEVER DO THIS - Including entire unchanged methods/classes",
			"# REPOMARK:SCOPE: 1 - Add health property to __init__ and logging to init() and load_data() (BAD - includes entire class)",
			"class GameManager:",
			"    def __init__(self):",
			"        self.score = 0",
			"        self.health = 100  # Added",
			"        self.level = 1",
			"        self.is_paused = False",
			"    ",
			"    def init(self):",
			"        self.setup_ui()",
			"        self.load_assets()",
			"        self.start_game_loop()",
			"    ",
			"    def update(self):",
			"        if not self.is_paused:",
			"            self.update_entities()",
			"            self.check_collisions()",
			"            self.render()",
			"    ",
			"    def load_data(self):",
			"        print('Loading...')  # Added",
			"        # ... 50 more unchanged lines ...",
			"        pass"
		]
	}
	
	public func commentSyntax() -> String {
		return "#"
	}
	
	// MARK: - File Editor Example Methods
	
	public func fileEditorExampleFileContents() -> [String] {
		return [
			"class GameManager:",
			"    def __init__(self):",
			"        self.score = 0",
			"        self.level = 1",
			"        self.is_running = False",
			"    ",
			"    def reset(self):",
			"        self.score = 0",
			"        self.level = 1",
			"        self.is_running = False",
			"    ",
			"    def check_proximity(self, position):",
			"        # Calculate distance logic here",
			"        return 0.0"
		]
	}
	
	public func fileEditorExampleChange1() -> [String] {
		return [
			"        # ... existing code ...",
			"        self.is_running = False",
			"        print('GameManager initialized')",
			"    ",
			"    def reset(self):",
			"        # ... existing code ..."
		]
	}
	
	public func fileEditorExampleChange2() -> [String] {
		return [
			"        # ... existing code ...",
			"        return 0.0",
			"    ",
			"    def __del__(self):",
			"        print('GameManager cleaned up')"
		]
	}
	
	public func fileEditorExampleSearchBlock() -> [String] {
		return [
			"        self.is_running = False",
			"    ",
			"    def reset(self):"
		]
	}
	
	public func fileEditorExampleContentBlock() -> [String] {
		return [
			"        self.is_running = False",
			"        print('GameManager initialized')",
			"    ",
			"    def reset(self):"
		]
	}
	
	public func fileEditorExampleSearchBlock2() -> [String] {
		return [
			"    def check_proximity(self, position):",
			"        # Calculate distance logic here",
			"        return 0.0"
		]
	}
	
	public func fileEditorExampleContentBlock2() -> [String] {
		return [
			"    def check_proximity(self, position):",
			"        # Calculate distance logic here",
			"        return 0.0",
			"    ",
			"    def __del__(self):",
			"        print('GameManager cleaned up')"
		]
	}
	
	// MARK: - Rewrite-Only File Editor Example Methods
	
	public func fileEditorRewriteExampleFileContents() -> [String] {
		return [
			"from typing import Dict, List",
			"",
			"class UserService:",
			"    def __init__(self):",
			"        self.users: List[Dict] = []",
			"    ",
			"    def process_user(self, user_data: Dict) -> Dict:",
			"        # Process user data",
			"        user = {",
			"            'id': user_data['id'],",
			"            'name': user_data['name']",
			"        }",
			"        return user",
			"    ",
			"    def save_user(self, user: Dict) -> None:",
			"        # Save user to database",
			"        self.users.append(user)"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"    def process_user(self, user_data: Dict) -> Dict:",
			"        # Add validation",
			"        if not user_data or 'id' not in user_data or 'name' not in user_data:",
			"            raise ValueError('Invalid user data')",
			"        ",
			"        # ... existing code ...",
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"    def save_user(self, user: Dict) -> None:",
			"        try:",
			"            # ... existing code ...",
			"            print('User saved successfully')",
			"        except Exception as e:",
			"            print(f'Failed to save user: {e}')",
			"            raise"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"from typing import Dict, List",
			"",
			"class UserService:",
			"    def __init__(self):",
			"        self.users: List[Dict] = []",
			"    ",
			"    def process_user(self, user_data: Dict) -> Dict:",
			"        # Add validation",
			"        if not user_data or 'id' not in user_data or 'name' not in user_data:",
			"            raise ValueError('Invalid user data')",
			"        ",
			"        # Process user data",
			"        user = {",
			"            'id': user_data['id'],",
			"            'name': user_data['name']",
			"        }",
			"        return user",
			"    ",
			"    def save_user(self, user: Dict) -> None:",
			"        try:",
			"            # Save user to database",
			"            self.users.append(user)",
			"            print('User saved successfully')",
			"        except Exception as e:",
			"            print(f'Failed to save user: {e}')",
			"            raise"
		]
	}
}