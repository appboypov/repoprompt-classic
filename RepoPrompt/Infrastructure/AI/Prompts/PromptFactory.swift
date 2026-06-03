import Foundation

/**
 * The PromptConfig describes which actions and features are allowed, plus relevant parameters.
 *
 * Roles:
 * - architect: In charge of planning detailed edits comprehensively, can also chat with the user about code or other requests.
 * - codeAssistant: Fulfills edit requests and can chat with the user about code or other requests.
 * - fileEditor: Only edits files (from instructions by another architect).
 *
 * Capabilities:
 * - canCreate: Supports creating new files
 * - canRewrite: Supports rewriting entire files
 * - canSearchReplace: Supports targeted search/replace edits (implies partial modify)
 * - canDelete: Supports deleting files
 * - canDelegateEdit: Can produce instructions (with placeholders) for an external agent, rather than finalize code
 * - supportsRename: Can rename/move files
 *
 * Additional Options:
 * - language: e.g. "Swift", "C#", "Kotlin"
 * - fileExtension: e.g. "swift", "cs", "kt" (used in example file paths)
 * - codeBlockFence: e.g. "```" or "==="
 * - includeIndentationEncoding: if true, uses <s4>, <s0>, etc.
 * - includeEscapingRules: if true, mention how to escape quotes and backslashes
 */
import Foundation

/**
 * The PromptConfig describes which actions and features are allowed, plus relevant parameters.
 */
public struct PromptConfig {
	public enum Role {
		case architect
		case codeAssistant
		case fileEditor
		case apply
	}
	
	// Role
	public var role: Role
	
	// Capabilities
	public var canCreate: Bool
	public var canRewrite: Bool
	public var canSearchReplace: Bool
	public var canDelete: Bool
	public var canDelegateEdit: Bool
	public var supportsRename: Bool
	
	// Language & Format
	public var language: String
	public var fileExtension: String
	public var codeBlockFence: String
	
	// Additional Options
	public var includeIndentationEncoding: Bool
	public var includeEscapingRules: Bool
	///  When true, even non-apply roles should append the two "wrap your output" notes
	public var includeApplyOutputWrappingNotes: Bool
	
	public init(role: Role,
				canCreate: Bool,
				canRewrite: Bool,
				canSearchReplace: Bool,
				canDelete: Bool,
				canDelegateEdit: Bool,
				supportsRename: Bool,
				language: String,
				fileExtension: String,
				codeBlockFence: String,
				includeIndentationEncoding: Bool,
				includeEscapingRules: Bool,
				includeApplyOutputWrappingNotes: Bool = false) {
		self.role = role
		self.canCreate = canCreate
		self.canRewrite = canRewrite
		self.canSearchReplace = canSearchReplace
		self.canDelete = canDelete
		self.canDelegateEdit = canDelegateEdit
		self.supportsRename = supportsRename
		
		self.language = language
		self.fileExtension = fileExtension
		self.codeBlockFence = codeBlockFence
		self.includeIndentationEncoding = includeIndentationEncoding
		self.includeEscapingRules = includeEscapingRules
		self.includeApplyOutputWrappingNotes = includeApplyOutputWrappingNotes
	}
}

/**
 * PromptFactory builds a comprehensive prompt for code modifications, adapted to the given PromptConfig.
 */
public class PromptFactory {
	public static func buildPrompt(with config: PromptConfig) -> String {
		var sections = [String]()
		
		// 1) Role Definition
		sections.append(buildRoleDefinitionSection(config: config))
		
		// 2) Tools & Actions
		sections.append(buildToolsSection(config: config))
		
		// 3) Protocol Descriptor
		sections.append(buildProtocolDescriptorSection(config: config))
		
		// 4) Format Guidelines
		sections.append(buildFormatGuidelinesSection(config: config))
		
		// 5) Examples
		sections.append(buildExamplesSection(config: config))
		
		// 6) Final Notes
		sections.append(buildFinalNotesSection(config: config))
		
		return sections.joined(separator: "\n\n")
	}
	
	// MARK: - Helper Functions
	private static func getCommentStyle(for language: String) -> String {
		switch language.lowercased() {
		case "python", "py", "ruby", "rb", "perl", "bash", "sh":
			return "#"
		case "html", "xml":
			return "<!--"
		case "sql":
			return "--"
		default:
			// Default to C-style comments for most languages
			// (Swift, JavaScript, Java, C, C++, C#, Go, Rust, PHP, Dart, etc.)
			return "//"
		}
	}
	
	// MARK: - (1) Role Definition
	private static func buildRoleDefinitionSection(config: PromptConfig) -> String {
		var lines = [String]()
		
		lines.append("### Role")
		switch config.role {
		case .architect:
			lines.append("- You are an **architect**: In charge of planning detailed and exhaustive multi-file edits, and assisting users with code related inquiries that don't involve file edits.")
		case .codeAssistant, .apply:
			lines.append("- You are a **code editing assistant**: You can fulfill edit requests and chat with the user about code or other questions. Provide complete instructions or code lines when replying with xml formatting.")
		case .fileEditor:
			lines.append("- You are a **file editor**: An architect prepared code edits for you to integrate into existing code files using xml formatting instructions. The preparred code may contain placeholders like // Existing code here. Be sure to replace these with the actual code. You must carry out all the edits requested by the architect and return the completed file.")
		}
		
		lines.append("\n### Capabilities")
		
		if config.canCreate {
			lines.append("- Can create new files.")
		}
		if config.canRewrite {
			lines.append("- Can rewrite entire files.")
		}
		if config.canSearchReplace {
			lines.append("- Can perform partial search/replace modifications.")
		}
		if config.canDelete {
			lines.append("- Can delete existing files.")
		}
		if config.canDelegateEdit {
			lines.append("- Can produce instructions with placeholders for an external agent to finalize.")
		}
		if config.supportsRename {
			lines.append("- Can rename or move files.")
		}
		
		lines.append("")
		if config.role == .architect {
			lines.append("You can use placeholders for delegate edits, like // existing code here, for brevity. For create, show full code.")
		} else {
			lines.append("Avoid placeholders like `...` or `// existing code here`. Provide complete lines or code.")
		}
		
		return lines.joined(separator: "\n")
	}
	
	// MARK: - (2) Tools & Actions
	private static func buildToolsSection(config: PromptConfig) -> String {
		var lines = [String]()
		lines.append("## Tools & Actions")
		
		var index = 1
		
		if config.canCreate {
			lines.append("\(index). **create** – Create a new file if it doesn’t exist.")
			index += 1
		}
		if config.canRewrite {
			lines.append("\(index). **rewrite** – Replace the entire content of an existing file.")
			index += 1
		}
		if config.canSearchReplace {
			lines.append("\(index). **modify** (search/replace) – For partial edits with <search> + <content>.")
			index += 1
		}
		if config.canDelete {
			lines.append("\(index). **delete** – Remove a file entirely (empty <content>).")
			index += 1
		}
		if config.supportsRename {
			lines.append("\(index). **rename** – Rename/move a file with `<new path=\"...\"/>`.")
			index += 1
		}
		if config.canDelegateEdit {
			lines.append("\(index). **delegate edit** – Provide targetted code change instructions that will be integrated by another ai model. Indicate <complexity> to help route changes to the right model.")
			index += 1
		}
		
		return lines.joined(separator: "\n")
	}
	
	// MARK: - (3) Protocol Descriptor
	private static func buildProtocolDescriptorSection(config: PromptConfig) -> String {
		var lines = [String]()
		
		lines.append("### **Format to Follow for Repo Prompt's Diff Protocol**")
		lines.append("")
		
		// chatName if not apply or fileEditor
		if config.role != .apply /*&& config.role != .fileEditor*/ {
			lines.append("<chatName=\"Brief descriptive name of the change\"/>")
			lines.append("")
		}
		
		lines.append("<Plan>")
		lines.append("Describe your approach or reasoning here.")
		lines.append("</Plan>")
		lines.append("")
		
		lines.append("<file path=\"path/to/example.\(config.fileExtension)\" action=\"one_of_the_tools\">")
		lines.append("  <change>")
		lines.append("    <description>Brief explanation of this specific change</description>")
		
		// If partial modifies are relevant (canSearchReplace), show <search>
		if config.canSearchReplace {
			lines.append("    <search>")
			lines.append(config.codeBlockFence)
			lines.append("// Exactly matching lines to find")
			lines.append(config.codeBlockFence)
			lines.append("    </search>")
		}
		
		lines.append("    <content>")
		lines.append(config.codeBlockFence)
		
		if config.canDelegateEdit {
			lines.append("// Provide placeholders or partial code. Must also include <complexity> after </content>.")
		} else {
			lines.append("// Provide the new or updated code here. Do not use placeholders")
		}
		
		lines.append(config.codeBlockFence)
		lines.append("    </content>")
		
		// If delegate edit, <complexity> is mandatory
		if config.canDelegateEdit {
			lines.append("    <complexity>3</complexity> <!-- Always required for delegate edits -->")
		}
		
		lines.append("  </change>")
		
		// If partial modifies or delegate edits are possible, mention multiple <change> blocks
		if config.canSearchReplace || config.canDelegateEdit {
			lines.append("  <!-- Add more <change> blocks if you have multiple edits for the same file -->")
		}
		
		lines.append("</file>")
		lines.append("")
		
		lines.append("#### Tools Demonstration")
		
		var idx = 1
		
		if(config.canCreate)
		{
			// create
			lines.append("\(idx). `<file path=\"NewFile.\(config.fileExtension)\" action=\"create\">` – Full file in <content>")
			idx += 1
		}
		
		if(config.canDelete)
		{
			// delete
			lines.append("\(idx). `<file path=\"DeleteMe.\(config.fileExtension)\" action=\"delete\">` – Empty <content>")
			idx += 1
		}
		
		if config.canDelegateEdit {
			lines.append("\(idx). `<file path=\"DelegateMe.\(config.fileExtension)\" action=\"delegate edit\">` – Placeholders in <content>, each <change> must include <complexity>")
			idx += 1
		} else if config.canSearchReplace {
			lines.append("\(idx). `<file path=\"ModifyMe.\(config.fileExtension)\" action=\"modify\">` – Partial edit with `<search>` + `<content>`")
			idx += 1
			if(config.canRewrite)
			{
				lines.append("\(idx). `<file path=\"RewriteMe.\(config.fileExtension)\" action=\"rewrite\">` – Entire file in <content>. No <search> required.")
				idx += 1
			}
			
		} else if config.canRewrite {
			lines.append("\(idx). `<file path=\"RewriteMe.\(config.fileExtension)\" action=\"rewrite\">` – Entire file in <content>")
			idx += 1
		}
		
		if config.supportsRename {
			lines.append("\(idx). `<file path=\"OldName.\(config.fileExtension)\" action=\"rename\">` – `<new path=\"NewName.\(config.fileExtension)\"/>` with no <content>")
			idx += 1
		}
		
		return lines.joined(separator: "\n")
	}
	
	// MARK: - (4) Format Guidelines
	private static func buildFormatGuidelinesSection(config: PromptConfig) -> String {
		var lines = [String]()
		lines.append("## Format Guidelines")
		
		var step = 1
		
		func addGroup(title: String, _ sub: [String]) {
			lines.append("\(step). \(title)")
			step += 1
			sub.forEach { lines.append("   - \($0)") }
		}
		
		// ──────────── General Guidelines ────────────
		var generalGuidelines = [String]()
		if config.role != .apply {
			generalGuidelines.append("Always Include `<chatName=\"Descriptive Name\"/>` at the top, briefly summarizing the change/request.")
		}
		generalGuidelines += [
			"Begin with a `<Plan>` block explaining your approach.",
			"Use `<file path=\"Models/User.\(config.fileExtension)\" action=\"...\">`. Action must match an available tool.",
			"Provide `<description>` within each `<change>` to clarify the specific change. Then `<content>` for the new or modified code. Additional rules depend on your capabilities."
		]
		addGroup(title: "**General Guidelines**", generalGuidelines)
		
		// ──────────── Modify (Search/Replace) Guidelines ────────────
		if config.canSearchReplace {
			addGroup(title: "**modify (search/replace)**", [
				"Provide `<search>` & `<content>` blocks enclosed by \(config.codeBlockFence). Respect indentation exactly, ensuring the `<search>` block matches the original source down to braces, spacing, and any comments. The new `<content>` will replace the `<search>` block and should fit perfectly in the space left by its removal.",
				"For multiple changes to the same file, ensure you use multiple `<change>` blocks rather than separate file blocks."
			])
		}
		
		// ──────────── Rewrite Guidelines ────────────
		if config.canRewrite {
			var rewriteGuidelines = [
				"When rewriting a file, you can only have one `<change>` per file. The entirety of the edited file's content must be present in `<content>`."
			]
			
			if config.canSearchReplace {
				rewriteGuidelines.append("For large overhauls, omit `<search>` and put the entire file in `<content>`.")
			} else {
				rewriteGuidelines.append("Replace the entire file. This is the only way to modify existing files.")
			}
			
			addGroup(title: "**rewrite**", rewriteGuidelines)
		}
		
		// ──────────── Delegate Edit Guidelines ────────────
		if config.canDelegateEdit {
			let commentStyle = getCommentStyle(for: config.language)
			addGroup(title: "**delegate edit**", [
				// Single change block with scope markers
				"Use ONE `<change>` block per file containing ALL edits.",
				"Mark each edit region with `\(commentStyle) REPOMARK:SCOPE: N - Clear description of what this edit does`",
				"The description after the dash is REQUIRED - it tells the editor exactly what task to perform.",
				"Use the appropriate comment style for the language (e.g., `//` for C-style, `#` for Python).",
				// Placement guidelines
				"**CRITICAL PLACEMENT**: Place scope markers BEFORE function/method/class definitions for easy localization.",
				"Include location context in descriptions (e.g., 'in processOrder function', 'at the bottom of GameManager class').",
				"This helps the file editor quickly locate where changes should be applied.",
				// Context markers
				"Insert `\(commentStyle) ... existing code ...` between scopes to indicate unchanged sections.",
				"Keep ≥ 1 unchanged line before *and* after each edit (≥ 2 if the neighbour is just `}` or blank).",
				// Scope structure
				"Each scope represents one logical edit with a clear task description.",
				"The scope comment must explain what the edit accomplishes (e.g., 'Add validation for empty input in validateUser method').",
				"Scopes must appear in the order they occur in the file (top to bottom).",
				"Deleting lines = leave them out between two anchors; no extra marker needed.",
				// Full‑scope swap rule
				"Full‑scope swap: paste the entire new function / struct / class within a scope.",
				"The **first two lines** (signature + first body line) must match the old version so the editor can anchor.",
				// Complexity
				"<complexity> (1‑10) must appear once after </content>, representing overall edit complexity."
			])
		}
		
		// ──────────── Create & Delete Guidelines ────────────
		var createDeleteGuidelines = [String]()
		if config.canCreate {
			createDeleteGuidelines.append("**create**: For new files, put the full file in `<content>`.")
		}
		if config.canDelete {
			createDeleteGuidelines.append("**delete**: Provide an empty `<content>`. The file is removed.")
		}
		if !createDeleteGuidelines.isEmpty {
			addGroup(title: "**create & delete**", createDeleteGuidelines)
		}
		
		// ──────────── Rename Guidelines ────────────
		if config.supportsRename {
			addGroup(title: "**rename**", [
				"Provide `<new path=\"...\"/>` inside the `<file>`, no `<content>` needed."
			])
		}
		
		// ──────────── File Editor Role Guidelines ────────────
		if config.role == .fileEditor {
			addGroup(title: "**file editor role**", [
				"Treat `// ... existing code ...` as skipped context; patch only the visible lines.",
				"Lines present in source but absent between two anchors are **deleted**.",
				"Strip placeholder comments ONLY from the architect's instructions (REPOMARK sections) - NOT from the original file.",
				"If the original file contains comments like `// existing code here`, preserve them exactly as they are.",
				"**IMPORTANT**: The <search> block MUST contain ONLY the actual file contents from the <file_contents> block - do NOT include placeholder comments like `// ... existing code ...` from the architect's instructions in your search block.",
				"Full‑scope swap content contains no placeholders; replace that whole balanced scope.",
				"Apply all changes specified in <changes-to-apply> - numbered list format with descriptions and code snippets.",
				"Fix at most one obvious syntax error introduced by the edit; otherwise apply verbatim.",
				"**NEVER** modify code outside REPOMARK:SCOPE boundaries - not even to fix obvious bugs.",
				"**NEVER** reformat, reorganize, or 'improve' code that isn't explicitly marked for change.",
				"Your ONLY job is to apply the requested edits - nothing more, nothing less."
			])
		}
		
		// ──────────── Encoding and Escaping ────────────
		var encodingEscapingGuidelines = [String]()
		if config.includeIndentationEncoding {
			encodingEscapingGuidelines.append("Use `<s#>` or `<t#>` in code to preserve spacing if needed.")
		}
		if config.includeEscapingRules {
			encodingEscapingGuidelines.append("Escape quotes as `\\\"` and backslashes as `\\\\` where needed.")
		}
		if !encodingEscapingGuidelines.isEmpty {
			addGroup(title: "**encoding and escaping**", encodingEscapingGuidelines)
		}
		
		return lines.joined(separator: "\n")
	}

	
	// MARK: - (5) Examples
	private static func buildExamplesSection(config: PromptConfig) -> String {
		var lines = [String]()
		lines.append("## Code Examples")
		
		// If language is recognized, build from the relevant example set. Otherwise fallback to JavaScript.
		let chosenExamples: CodeExamples
		switch config.language.lowercased() {
		case "swift":
			chosenExamples = SwiftExamples()
		case "javascript", "js":
			chosenExamples = JavaScriptExamples()
		case "typescript", "ts":
			chosenExamples = TypeScriptExamples()
		case "tsx":
			chosenExamples = TSXExamples()
		case "python", "py":
			chosenExamples = PythonExamples()
		case "c#", "csharp", "cs":
			chosenExamples = CSharpExamples()
		case "c":
			chosenExamples = CExamples()
		case "c++", "cpp", "cxx":
			chosenExamples = CppExamples()
		case "rust", "rs":
			chosenExamples = RustExamples()
		case "go", "golang":
			chosenExamples = GoExamples()
		case "java":
			chosenExamples = JavaExamples()
		case "dart":
			chosenExamples = DartExamples()
		case "php":
			chosenExamples = PHPExamples()
		default:
			// Default to JavaScript as it's the most common language
			chosenExamples = JavaScriptExamples()
		}
		
		lines.append(buildLanguageExamples(config: config, examples: chosenExamples))
		
		return lines.joined(separator: "\n\n")
	}
	
	private static func buildLanguageExamples(config: PromptConfig, examples: CodeExamples) -> String {
		var segments = [String]()
		
		// MARK: - Search and Replace Examples
		if config.canSearchReplace {
			segments.append("-----\n### Example: Search and Replace (Add email property)\n" + buildSearchReplaceExample(config: config, examples: examples))
			// Negative examples:
			segments.append("-----\n### Example: Negative Example - Mismatched Search Block\n" + buildSearchReplaceNegativeExample(config: config, examples: examples))
			segments.append("-----\n### Example: Negative Example - Mismatched Brace Balance\n" + buildSearchReplaceBraceMismatchExample(config: config, examples: examples))
			segments.append("-----\n### Example: Negative Example - One-Line Search Block\n" + buildSearchReplaceNegativeOneLineSearchExample(config: config, examples: examples))
			segments.append("-----\n### Example: Negative Example - Ambiguous Search Block\n" + buildSearchReplaceNegativeAmbiguousSearchExample(config: config, examples: examples))
			
			// Add file editor example if this is a file editor with search/replace capabilities
			if config.role == .fileEditor {
				segments.append("-----\n### Example: File Editor Instructions (What You'll Receive)\n" + buildFileEditorExample(config: config, examples: examples))
			}
		}
		
		// MARK: - Rewrite Examples
		if config.canRewrite {
			segments.append("-----\n### Example: Full File Rewrite\n" + buildRewriteExample(config: config, examples: examples))
			
			// Add rewrite-only file editor example if this is a file editor that can only rewrite
			if config.role == .fileEditor && !config.canSearchReplace {
				segments.append("-----\n### Example: File Editor Rewrite-Only Instructions (What You'll Receive)\n" + buildFileEditorRewriteOnlyExample(config: config, examples: examples))
			}
		}
		
		// MARK: - Basic File Operations
		if config.canCreate {
			segments.append("-----\n### Example: Create New File\n" + buildCreateExample(config: config, examples: examples))
		}
		
		if config.canDelete {
			segments.append("-----\n### Example: Delete a File\n" + buildDeleteExample(config: config))
		}
		
		if config.supportsRename {
			segments.append("-----\n### Example: Rename a File\n" + buildRenameExample(config: config))
		}
		
		// MARK: - Delegate Edit Examples
		if config.canDelegateEdit {
			segments.append("-----\n### Example: Delegate Edit - Inline tweak single scope\n" + buildDelegateEditInlineTweakSingleScope(config: config, examples: examples))
			segments.append("-----\n### Example: Delegate Edit - Inline tweaks two scopes\n" + buildDelegateEditInlineTweaksTwoScopes(config: config, examples: examples))
			segments.append("-----\n### Example: Delegate Edit - Complex single-scope edit\n" + buildDelegateEditComplexSingleScope(config: config, examples: examples))
			segments.append("-----\n### Example: Delegate Edit - Full-scope swap\n" + buildDelegateEditFullScopeSwap(config: config, examples: examples))
			segments.append("-----\n### ❌ BAD EXAMPLE - What NOT to do\n" + buildDelegateEditNegativeVerbose(config: config, examples: examples))
			segments.append("-----\n### Example: Delegate Edit – Complex Add/Delete (legacy format)\n" + buildDelegateEditComplexExample(config: config, examples: examples))
		}
		
		return segments.joined(separator: "\n\n")
	}
	
	// Example: search/replace
	private static func buildSearchReplaceExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let oldLines = examples.userSearchReplaceOldLines(includeIndentation: config.includeIndentationEncoding)
		let newLines = examples.userSearchReplaceNewLines(includeIndentation: config.includeIndentationEncoding)
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Add an email property to `User` via search/replace.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Models/User.\(config.fileExtension)\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>Add email property to User struct</description>")
		snippet.append("    <search>")
		snippet.append(fence)
		snippet.append(contentsOf: oldLines)
		snippet.append(fence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: newLines)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	private static func buildSearchReplaceNegativeExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		
		var snippet = [String]()
		snippet.append("// Example Input (not part of final output, just demonstration)")
		snippet.append("<file_contents>")
		snippet.append("File: path/service.swift")
		snippet.append("```")
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleFileContents(includeIndentation: config.includeIndentationEncoding))
		snippet.append("```")
		snippet.append("</file_contents>")
		snippet.append("")
		
		snippet.append("<Plan>")
		snippet.append("Demonstrate how a mismatched search block leads to failed merges.")
		snippet.append("</Plan>")
		snippet.append("")
		
		snippet.append("<file path=\"path/service.swift\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>This search block is missing or has mismatched indentation, braces, etc.</description>")
		snippet.append("    <search>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleSearchBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleNewBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("<!-- This example fails because the <search> block doesn't exactly match the original file contents. -->")
		
		return snippet.joined(separator: "\n")
	}
	
	private static func buildSearchReplaceBraceMismatchExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		
		var snippet = [String]()
		snippet.append("// This negative example shows how adding extra braces in the <content> can break brace matching.")
		snippet.append("<Plan>")
		snippet.append("Demonstrate that the new content block has one extra closing brace, causing mismatched braces.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Functions/MismatchedBracesExample.\(config.fileExtension)\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>Mismatched brace balance in the replacement content</description>")
		snippet.append("    <search>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("<!-- Because the <search> block was only a small brace segment, adding extra braces in <content> breaks the balance. -->")
		
		return snippet.joined(separator: "\n")
	}
	
	// New negative example: one-line search block (should be avoided)
	private static func buildSearchReplaceNegativeOneLineSearchExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Demonstrate a one-line search block, which is too short to be reliable.")
		snippet.append("</Plan>")
		snippet.append("")
		
		snippet.append("<file path=\"path/service.swift\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>One-line search block is ambiguous</description>")
		snippet.append("    <search>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("<!-- This example fails because the <search> block is only one line and ambiguous. -->")
		return snippet.joined(separator: "\n")
	}
	
	// New negative example: ambiguous search block (should be avoided)
	private static func buildSearchReplaceNegativeAmbiguousSearchExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Demonstrate an ambiguous search block that can match multiple blocks (e.g., multiple closing braces).")
		snippet.append("</Plan>")
		snippet.append("")
		
		snippet.append("<file path=\"path/service.swift\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>Ambiguous search block with multiple closing braces</description>")
		snippet.append("    <search>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: examples.userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: config.includeIndentationEncoding))
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("<!-- This example fails because the <search> block is ambiguous due to multiple matching closing braces. -->")
		return snippet.joined(separator: "\n")
	}
	
	// Example: rewrite
	private static func buildRewriteExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let linesForRewrite = examples.userRewriteAllLines(includeIndentation: config.includeIndentationEncoding)
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Rewrite the entire User file to include an email property.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Models/User.\(config.fileExtension)\" action=\"rewrite\">")
		snippet.append("  <change>")
		snippet.append("    <description>Full file rewrite with new email field</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: linesForRewrite)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: create
	private static func buildCreateExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let linesForCreate = examples.userCreateAllLines(includeIndentation: config.includeIndentationEncoding)
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Create a new RoundedButton for a custom Swift UIButton subclass.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Views/RoundedButton.\(config.fileExtension)\" action=\"create\">")
		snippet.append("  <change>")
		snippet.append("    <description>Create custom RoundedButton class</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: linesForCreate)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: Delegate Edit – Complex Add/Delete
	private static func buildDelegateEditComplexExample(
		config: PromptConfig,
		examples: CodeExamples
	) -> String {
		let fence       = config.codeBlockFence
		let replaceDemo = examples.delegateEditComplexReplaceLines()
		let addDelDemo  = examples.delegateEditComplexAddDeleteLines()

		var snippet = [String]()
		snippet.append("<chatName=\"Delegate Edit – Complex Add/Delete\"/>")
		snippet.append("<Plan>")
		snippet.append("Replace a legacy networking block with async/await **and** switch the")
		snippet.append("UI colour assignment to a dark‑mode‑aware variant—all without rewriting")
		snippet.append("entire methods.")
		snippet.append("</Plan>")
		snippet.append("")

		// First method: replacement inside loadUserData()
		snippet.append("<file path=\"Networking/UserService.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Replace legacy networking with async/await</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: replaceDemo)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>4</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")

		// Second method: separate add & delete inside configureUI()
		snippet.append("<file path=\"UI/HomeViewController.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Delete hard‑coded colour; add dark‑mode colour</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: addDelDemo)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>3</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")

		return snippet.joined(separator: "\n")
	}
	
	// Example: Delegate Edit - Inline tweak single scope
	private static func buildDelegateEditInlineTweakSingleScope(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let lines = examples.delegateEditInlineTweakSingleScope()
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Cap `currentHealth` at 200.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Gameplay/Player.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Replace 999 with maxHealth</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: lines)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>2</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: Delegate Edit - Inline tweaks two scopes
	private static func buildDelegateEditInlineTweaksTwoScopes(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let lines = examples.delegateEditInlineTweaksTwoScopes()
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Tweak healing and add bonus score.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Gameplay/Player.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Cap health at maxHealth and add +10 bonus to score</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: lines)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>2</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: Delegate Edit - Complex single-scope edit
	private static func buildDelegateEditComplexSingleScope(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let lines = examples.delegateEditComplexSingleScope()
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Adjust tax calc, remove legacy discount, add logging – all in processOrder(_:).")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Commerce/Checkout.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Tax tweak, discount removal, logging</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: lines)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>4</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: Delegate Edit - Full-scope swap
	private static func buildDelegateEditFullScopeSwap(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let lines = examples.delegateEditFullScopeSwap()
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Replace generateStructures() with randomised algorithm.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Gameplay/Player.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Full replacement of generateStructures()</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: lines)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>7</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: Delegate Edit - Negative (overly verbose)
	private static func buildDelegateEditNegativeVerbose(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let lines = examples.delegateEditNegativeVerbose()
		
		var snippet = [String]()
		snippet.append("### ❌ NEVER DO THIS - OVERLY VERBOSE DELEGATE EDIT ❌")
		snippet.append("")
		snippet.append("**THIS IS WRONG:** Including entire unchanged methods, combining multiple logical changes in one block")
		snippet.append("")
		snippet.append("<Plan>")
		snippet.append("Add onGameStateChanged callback to GameManager")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Game/GameManager.\(config.fileExtension)\" action=\"delegate edit\">")
		snippet.append("  <change>")
		snippet.append("    <description>Add callback property and too much context</description>")
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: lines)
		snippet.append(fence)
		snippet.append("    </content>")
		snippet.append("    <complexity>2</complexity>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("### ⚠️ WHAT'S WRONG HERE:")
		snippet.append("1. **Shows unchanged methods** (viewDidLoad, generateRandomLayout) - NEVER include these")
		snippet.append("2. **Too much context** - Should only show the specific field addition with minimal anchors")
		snippet.append("3. **Single giant scope** - Should be split into multiple smaller scopes")
		snippet.append("4. **Wastes tokens** - This approach uses 10x more tokens than necessary")
		snippet.append("")
		snippet.append("### ✅ CORRECT APPROACH:")
		snippet.append("Split into multiple scopes with proper placement:")
		let commentStyle = examples.commentSyntax()
		snippet.append("- Place scope marker BEFORE the function/method definition")
		snippet.append("- `\(commentStyle) REPOMARK:SCOPE: 1 - Add onGameStateChanged callback property to GameManager class`")
		snippet.append("- `\(commentStyle) ... existing code ...`")
		snippet.append("- `\(commentStyle) REPOMARK:SCOPE: 2 - Add initialization logging in init method`")
		snippet.append("- `\(commentStyle) ... existing code ...`")
		snippet.append("- `\(commentStyle) REPOMARK:SCOPE: 3 - Add data loading logging in loadData method`")
		snippet.append("- etc... (minimal context per scope with location descriptions)")
		
		return snippet.joined(separator: "\n")
	}
	
	// Example: indentation-preserving
	private static func buildIndentationPreservingExample(config: PromptConfig, examples: CodeExamples) -> String {
		let fence = config.codeBlockFence
		let oldBlock = examples.networkManagerOldLines(includeIndentation: config.includeIndentationEncoding)
		let newBlock = examples.networkManagerNewLines(includeIndentation: config.includeIndentationEncoding)
		
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Modify `fetchData` to use async/await, keeping indentation identical.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Networking/NetworkManager.\(config.fileExtension)\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>Switch from completion handler to async/await</description>")
		
		if config.canSearchReplace {
			snippet.append("    <search>")
			snippet.append(fence)
			snippet.append(contentsOf: oldBlock)
			snippet.append(fence)
			snippet.append("    </search>")
		}
		
		snippet.append("    <content>")
		snippet.append(fence)
		snippet.append(contentsOf: newBlock)
		snippet.append(fence)
		snippet.append("    </content>")
		
		snippet.append("  </change>")
		snippet.append("</file>")
		
		return snippet.joined(separator: "\n")
	}
	
	// MARK: - Delete example
	private static func buildDeleteExample(config: PromptConfig) -> String {
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Remove an obsolete file.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Obsolete/File.\(config.fileExtension)\" action=\"delete\">")
		snippet.append("  <change>")
		snippet.append("    <description>Completely remove the file from the project</description>")
		snippet.append("    <content>")
		snippet.append(config.codeBlockFence)
		// empty block
		snippet.append(config.codeBlockFence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		return snippet.joined(separator: "\n")
	}
	
	// MARK: - Rename example
	private static func buildRenameExample(config: PromptConfig) -> String {
		var snippet = [String]()
		snippet.append("<Plan>")
		snippet.append("Rename OldName to NewName.")
		snippet.append("</Plan>")
		snippet.append("")
		snippet.append("<file path=\"Models/OldName.\(config.fileExtension)\" action=\"rename\">")
		snippet.append("  <new path=\"Models/NewName.\(config.fileExtension)\"/>")
		snippet.append("</file>")
		return snippet.joined(separator: "\n")
	}
	
	// MARK: - File Editor Example
	private static func buildFileEditorExample(config: PromptConfig, examples: CodeExamples) -> String {
		var snippet = [String]()
		snippet.append("**This example shows what you'll receive as a file editor.**")
		snippet.append("")
		snippet.append("The architect will provide changes with placeholders like `// ... existing code ...` to indicate context.")
		snippet.append("Your job is to:")
		snippet.append("1. Use the actual file contents from `<file_contents>` to locate where changes should be applied")
		snippet.append("2. Interpret the architect's instructions to determine the exact insertion points")
		snippet.append("3. Apply ALL changes exactly as specified in `<changes-to-apply>`")
		snippet.append("4. NEVER modify code that isn't explicitly part of the changes")
		snippet.append("")
		snippet.append("Here's what you'll see:")
		snippet.append("")
		snippet.append("<file_contents>")
		snippet.append("File: /path/to/GameManager.\(config.fileExtension)")
		snippet.append("```\(config.language.lowercased())")
		snippet.append(contentsOf: examples.fileEditorExampleFileContents())
		snippet.append("```")
		snippet.append("</file_contents>")
		snippet.append("")
		snippet.append("<instructions>")
		snippet.append("Edit the file specified in <file_contents> with the following changes.")
		snippet.append("Ensure that every single change specified in <changes_to_apply> is applied exactly as specified.")
		snippet.append("<changes-to-apply>")
		snippet.append("")
		snippet.append("Change 1:")
		snippet.append("Add initialization method with logging")
		snippet.append("```")
		snippet.append(contentsOf: examples.fileEditorExampleChange1())
		snippet.append("```")
		snippet.append("")
		snippet.append("Change 2:")
		snippet.append("Add cleanup in destructor")
		snippet.append("```")
		snippet.append(contentsOf: examples.fileEditorExampleChange2())
		snippet.append("```")
		snippet.append("</changes-to-apply>")
		snippet.append("</instructions>")
		snippet.append("")
		snippet.append("**Your response should be:**")
		snippet.append("")
		snippet.append("<file path=\"/path/to/GameManager.\(config.fileExtension)\" action=\"modify\">")
		snippet.append("  <change>")
		snippet.append("    <description>Add initialization method with logging</description>")
		snippet.append("    <search>")
		snippet.append(config.codeBlockFence)
		snippet.append(contentsOf: examples.fileEditorExampleSearchBlock())
		snippet.append(config.codeBlockFence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(config.codeBlockFence)
		snippet.append(contentsOf: examples.fileEditorExampleContentBlock())
		snippet.append(config.codeBlockFence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("  <change>")
		snippet.append("    <description>Add cleanup in destructor</description>")
		snippet.append("    <search>")
		snippet.append(config.codeBlockFence)
		snippet.append(contentsOf: examples.fileEditorExampleSearchBlock2())
		snippet.append(config.codeBlockFence)
		snippet.append("    </search>")
		snippet.append("    <content>")
		snippet.append(config.codeBlockFence)
		snippet.append(contentsOf: examples.fileEditorExampleContentBlock2())
		snippet.append(config.codeBlockFence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("**Key points:**")
		snippet.append("- The architect uses `// ... existing code ...` as context markers")
		snippet.append("- You must find the actual code from `<file_contents>` that matches the context")
		snippet.append("- Your `<search>` block must contain the EXACT code from the file, not the architect's placeholders")
		snippet.append("- Apply all changes while preserving the rest of the file exactly as-is")
		
		return snippet.joined(separator: "\n")
	}
	
	// MARK: - File Editor Rewrite-Only Example
	private static func buildFileEditorRewriteOnlyExample(config: PromptConfig, examples: CodeExamples) -> String {
		var snippet = [String]()
		snippet.append("**This example shows what you'll receive as a file editor that can only rewrite (no search/replace).**")
		snippet.append("")
		snippet.append("Since you cannot do partial search/replace, you must:")
		snippet.append("1. Read the entire file content from `<file_contents>`")
		snippet.append("2. Apply ALL changes specified in `<changes-to-apply>` to create the complete updated file")
		snippet.append("3. Return the ENTIRE file with all changes integrated using action=\"rewrite\"")
		snippet.append("")
		snippet.append("Here's what you'll see:")
		snippet.append("")
		snippet.append("<file_contents>")
		snippet.append("File: /path/to/UserService.\(config.fileExtension)")
		snippet.append("```\(config.language.lowercased())")
		snippet.append(contentsOf: examples.fileEditorRewriteExampleFileContents())
		snippet.append("```")
		snippet.append("</file_contents>")
		snippet.append("")
		snippet.append("<instructions>")
		snippet.append("Edit the file specified in <file_contents> with the following changes.")
		snippet.append("Since you can only rewrite files, you must output the COMPLETE updated file.")
		snippet.append("<changes-to-apply>")
		snippet.append("")
		snippet.append("Change 1:")
		snippet.append("Add input validation to the processUser function")
		snippet.append("```")
		snippet.append(contentsOf: examples.fileEditorRewriteExampleChange1())
		snippet.append("```")
		snippet.append("")
		snippet.append("Change 2:")
		snippet.append("Add error handling to the saveUser function")
		snippet.append("```")
		snippet.append(contentsOf: examples.fileEditorRewriteExampleChange2())
		snippet.append("```")
		snippet.append("</changes-to-apply>")
		snippet.append("</instructions>")
		snippet.append("")
		snippet.append("**Your response should be:**")
		snippet.append("")
		snippet.append("<file path=\"/path/to/UserService.\(config.fileExtension)\" action=\"rewrite\">")
		snippet.append("  <change>")
		snippet.append("    <description>Complete file with validation in processUser and error handling in saveUser</description>")
		snippet.append("    <content>")
		snippet.append(config.codeBlockFence)
		snippet.append(contentsOf: examples.fileEditorRewriteExampleCompleteFile())
		snippet.append(config.codeBlockFence)
		snippet.append("    </content>")
		snippet.append("  </change>")
		snippet.append("</file>")
		snippet.append("")
		snippet.append("**Key differences from search/replace:**")
		snippet.append("- You must include the ENTIRE file content, not just the changed parts")
		snippet.append("- Use action=\"rewrite\" instead of action=\"modify\"")
		snippet.append("- No `<search>` blocks - just the complete updated file in `<content>`")
		snippet.append("- Integrate all changes while preserving the rest of the file exactly as-is")
		snippet.append("- The architect's placeholders (`// ... existing code ...`) indicate unchanged sections you must preserve from the original")
		
		return snippet.joined(separator: "\n")
	}
	
	
	// MARK: - (4) Format Guidelines
	private static func buildFinalNotesSection(config: PromptConfig) -> String {
		var lines = [String]()
		lines.append("## Final Notes")
		
		var idx = 1
		
		// Convenience function for grouped bullets
		func addGroup(title: String, _ sub: [String]) {
			lines.append("\(idx). \(title)")
			idx += 1
			sub.forEach { lines.append("   - \($0)") }
		}
		
		// ───────────────────────────── delegate edit ───────────────────────────────────
		if config.canDelegateEdit {
			let commentStyle = getCommentStyle(for: config.language)
			addGroup(title: "**delegate edit – recap**", [
				"**EXAMINE FIRST**: Study the actual file content in file_contents to understand the existing code structure before planning edits.",
				"**PATH ACCURACY**: Use the EXACT file path from file_contents in your `<file path=\"...\">` - the path shown after 'File: ' is what you must use.",
				"ONE `<change>` block per file with ALL edits inside.",
				"Use `\(commentStyle) REPOMARK:SCOPE: N - Task description` markers (description REQUIRED).",
				"Place scope markers BEFORE function/method/class definitions for easy localization.",
				"Include location context in descriptions (e.g., 'in handleRequest method', 'at end of Utils class').",
				"Include `\(commentStyle) ... existing code ...` between scopes.",
				"Scopes in file order (top to bottom), minimal context.",
				"Each scope has a clear task description for the editor.",
				"<complexity> once per file."
			])
		}
		
		// ───────────────────────────── modify / rewrite ──────────────────────────
		if config.canRewrite {
			var rewriteBullets = [
				"For rewriting an entire file, place all new content in `<content>`. No partial modifications are possible here. Avoid all use of placeholders.",
				"You must include **exactly one** `<change>` block when performing a rewrite, and the `<content>` inside that block must contain the full, updated content of the file."
			]
			
			if config.canDelegateEdit {
				rewriteBullets.append("Reserve rewrite for truly comprehensive overhauls where the majority of the file structure changes. Delegate edit handles most refactoring scenarios more efficiently.")
			}
			
			addGroup(title: "**rewrite**", rewriteBullets)
		}
		
		if config.canSearchReplace {
			var modifyBullets = [
				"Always wrap the exact original lines in <search> and your updated lines in <content>, each enclosed by \(config.codeBlockFence).",
				"The <search> block must match the source code exactly—down to indentation, braces, spacing, and any comments. Even a minor mismatch causes failed merges.",
				"Ensure that all <search> blocks have unique lines in them that unambiguosly match the precise part of the file we're trying to edit.",
				"If editing two very similar parts of the file, ensure that each <search> is uniquely specific to the part each is supposed to edit.",
				"Only replace exactly what you need. Avoid including entire functions or files if only a small snippet changes, and ensure the <search> content is unique and easy to identify."
			]
			
			if config.canRewrite {
				modifyBullets.append("Use `rewrite` for major overhauls, and `modify` for smaller, localized edits. Rewrite requires the entire code to be replaced, so use it sparingly.")
			}
			
			addGroup(title: "**modify**", modifyBullets)
		}
		
		// ───────────────────────────── create & delete ───────────────────────────
		if config.role != .fileEditor {
			addGroup(title: "**create & delete**", [
				"**BEFORE CREATING**: Always check file_contents first - if a similar file already exists, consider editing it instead of creating a duplicate.",
				"You can always **create** new files and **delete** existing files. Provide full code for create, and empty content for delete.",
				"When user instructions imply modifying existing functionality, prioritize editing files from file_contents over creating new ones.",
				"If a file tree is provided, place your files logically within that structure. Respect the user's relative or absolute paths."
			])
		} else {
			addGroup(title: "**file editor – recap**", [
				"Skip regions marked `// ... existing code ...` in the architect's instructions; apply edits in between.",
				"Lines omitted between anchors are deleted.",
				"Remove placeholder comments from architect's instructions ONLY - preserve ALL original file comments and placheolders (located in the <file_contents> block).",
				"Replace full scopes exactly when given without placeholders.",
				//"Process `<change>` blocks sequentially; reject overlaps.",
				"Fix ≤ 1 obvious syntax error; otherwise apply verbatim.",
				"**ABSOLUTE RULE**: Never modify ANY code outside REPOMARK:SCOPE markers.",
				"**NO EXCEPTIONS**: Even if code looks wrong, preserve it exactly if not in scope.",
				"**TRUST THE ARCHITECT**: They chose what to change - respect their boundaries.",
				"**ORIGINAL FILE INTEGRITY**: If the original file has placeholder-like comments, they are real code - keep them!"
			])
		}
		
		// ───────────────────────────── rename rules ──────────────────────────────
		if config.supportsRename {
			var renameBullets = [
				"Use **rename** to move a file by adding `<new path=\"…\"/>` and leaving `<content>` empty. This deletes the old file and materialises the new one with the original content."
			]
			
			if config.canSearchReplace {
				if config.canRewrite {
					renameBullets.append("After a rename, **do not** pair it with **modify** or **rewrite** on either the old **or** the new path in the same response.")
				} else {
					renameBullets.append("After a rename, **do not** pair it with **modify** on either the old **or** the new path in the same response.")
				}
			} else {
				if config.role == .architect {
					renameBullets.append("After a rename, **do not** pair it with **delegate edit** on either the old **or** the new path in the same response.")
				} else {
					renameBullets.append("After a rename, **do not** pair it with **rewrite** on either the old **or** the new path in the same response.")
				}
			}
			
			renameBullets += [
				"Never reference the *old* path again, and never add a `<file action=\"create\">` that duplicates the **new** path in the same run.",
				"Ensure the destination path does **not** already exist and rename a given file **at most once per response**.",
				"If the new file requires changes, first delete it, then create a fresh file with the desired content."
			]
			
			addGroup(title: "**rename**", renameBullets)
		}
		
		// ───────────────────────────── output-format rules ───────────────────────
		if config.role == .apply || config.includeApplyOutputWrappingNotes {
			addGroup(title: "**additional formatting rules**", [
				"Wrap your final output in ```XML … ``` for clarity.",
				"**Important:** do **not** wrap XML in CDATA tags (`<![CDATA[ … ]]>`). Repo Prompt expects raw XML exactly as shown in the examples."
			])
		}
		
		if config.role != .apply {
			addGroup(title: "**capabilities**", [
				"If you see mentions of capabilities not listed above in the user’s chat history, **do not** try to use them."
			])
		}
		
		if config.role == .architect || config.role == .codeAssistant {
			addGroup(title: "**chatName**", [
				"Always include `<chatName=\"Descriptive Name\"/>` near the top when you produce multi-file or complex changes."
			])
			addGroup(title: "**Editing rules**", [
				"**CRITICAL**: Before deciding whether to create or edit files, carefully examine ALL files in the file_contents section.",
				"When user instructions reference a file or functionality, first check if a related file exists in file_contents - if it does, edit that file instead of creating a new one.",
				"Files in file_contents are your primary working context - they represent the actual codebase structure and existing implementations.",
				"**PATH PRECISION**: Use the EXACT file path shown in file_contents when writing `<file path=\"...\">` - do not modify or approximate the path.",
				"The path after 'File: ' in each file_contents block is the precise path you must use in your file edits.",
				"Never attempt to edit a file not listed in the user prompt's file_contents section.",
				"If you must edit a file not in the file_contents block, ask the user to include it in their next message.",
				"If the file is in the file_contents block, you have everything you need to successfully complete the edit.",
			])
		}
		
		if config.includeIndentationEncoding {
			addGroup(title: "**indentation encoding**", [
				"Maintain `<s#>` or `<t#>` tags consistently."
			])
		}
		
		if config.includeEscapingRules {
			addGroup(title: "**escaping**", [
				"Escape quotes as `\\\"` and backslashes as `\\\\` if necessary."
			])
		}
		
		// ───────────────────────────── mandatory reminders ───────────────────────
		let mandatoryBullets = [
			"WHEN MAKING FILE CHANGES, YOU **MUST** USE THE XML FORMATTING CAPABILITIES SHOWN ABOVE—IT IS THE *ONLY* WAY FOR CHANGES TO BE APPLIED.",
			"The final output must apply cleanly with **no leftover syntax errors**."
		]
		
		/*
		// Add file editor specific mandatory rules
		if config.role == .fileEditor {
			mandatoryBullets += [
				"**CRITICAL**: You MUST NOT modify ANY code that is not explicitly marked within REPOMARK:SCOPE markers.",
				"**PRESERVE EXACTLY**: All code outside scope markers must be returned VERBATIM - do not 'improve', reformat, or change it in ANY way.",
				"**NO UNAUTHORIZED CHANGES**: Even if you see obvious bugs, style issues, or improvements outside the marked scopes - DO NOT TOUCH THEM.",
				"**SCOPE BOUNDARIES ARE SACRED**: If code appears between `// ... existing code ...` markers IN THE INSTRUCTIONS, it is OFF LIMITS - preserve it exactly as shown.",
				"**VERBATIM MEANS VERBATIM**: Copy all unmarked code character-for-character, including 'wrong' indentation, trailing spaces, or any quirks.",
				"**PLACEHOLDER CLARIFICATION**: Only remove placeholders from the ARCHITECT'S INSTRUCTIONS - if the original file contains similar comments, they are REAL CODE and must be preserved.",
				"**REJECTION CRITERIA**: Your edit will be REJECTED if you modify even a single character outside the designated scope markers."
			]
		}
		*/
		
		addGroup(title: "**MANDATORY**", mandatoryBullets)
		
		return lines.joined(separator: "\n")
	}

}
