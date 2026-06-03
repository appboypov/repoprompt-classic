//
//  PHPParserTests.swift
//  RepoPromptTests
//
//  Comprehensive tests for PHP support including parsing, codemap generation,
//  highlighting, and type extraction.
//

import XCTest
@testable import RepoPrompt

final class PHPParserTests: XCTestCase {
    
    // MARK: - Basic PHP Support Tests
    
    func testPHPLanguageDetection() {
        XCTAssertEqual(SyntaxManager.shared.extensionToLanguage["php"], .php)
        XCTAssertTrue(SyntaxManager.isSupportedFileExtension("php"))
    }
    
    func testPHPConfiguration() {
        let phpMetadata = SyntaxManager.shared.languageMetadata(forFileExtension: "php")
        XCTAssertNotNil(phpMetadata)
        XCTAssertEqual(phpMetadata?.displayName, "PHP")
        XCTAssertEqual(phpMetadata?.canonicalFileExtension, "php")
    }
    
    func testBasicPHPParsing() throws {
        let phpCode = """
        <?php
        function hello() {
            echo "Hello, World!";
        }
        ?>
        """
        
        let parseSummary = try SyntaxManager.shared.parseSummary(content: phpCode, fileExtension: "php")
        XCTAssertNotNil(parseSummary)
        XCTAssertTrue(parseSummary?.hasRootNode == true)
        #if DEBUG
        let treeDescription = try SyntaxManager.shared.debugTreeDescription(
            content: phpCode,
            fileExtension: "php",
            originName: "PHPParserTests.testBasicPHPParsing"
        )
        XCTAssertNotNil(treeDescription)
        #endif
    }
    
    // MARK: - PHP CodeMap Tests
    
    func testPHPNamespaceAndImports() throws {
        let phpCode = """
        <?php
        namespace App\\Models;
        
        use App\\Traits\\HasTimestamps;
        use Illuminate\\Database\\Eloquent\\Model;
        
        class User extends Model {
            use HasTimestamps;
        }
        """
        
        let map = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        
        let namespaceCaptures = map.filter { $0.name == "module" }
        XCTAssertFalse(namespaceCaptures.isEmpty, "Should capture namespace")
        
        let importCaptures = map.filter { $0.name == "import" }
        XCTAssertFalse(importCaptures.isEmpty, "Should capture use statements")
    }
    
    func testPHPClassStructures() throws {
        let phpCode = """
        <?php
        
        class User {
            private $name;
            
            public function getName() {
                return $this->name;
            }
        }
        
        interface Authenticatable {
            public function authenticate();
        }
        
        trait HasRoles {
            protected $roles = [];
        }
        
        enum Status {
            case Active;
            case Inactive;
        }
        """
        
        let map = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        
        let classCaptures = map.filter { $0.name == "type.class" }
        XCTAssertFalse(classCaptures.isEmpty, "Should capture class declarations")
        
        let interfaceCaptures = map.filter { $0.name == "type.interface" }
        XCTAssertFalse(interfaceCaptures.isEmpty, "Should capture interface declarations")
        
        let traitCaptures = map.filter { $0.name == "type.trait" }
        XCTAssertFalse(traitCaptures.isEmpty, "Should capture trait declarations")
        
        let enumCaptures = map.filter { $0.name == "type.enum" }
        XCTAssertFalse(enumCaptures.isEmpty, "Should capture enum declarations")
    }
    
    func testPHPFunctionsAndMethods() throws {
        let phpCode = """
        <?php
        
        // Global function
        function processData($data) {
            return strtoupper($data);
        }
        
        class UserService {
            // Public method
            public function getUser($id) {
                return User::find($id);
            }
            
            // Private method with type hints
            private function validateUser(User $user): bool {
                return $user->isActive();
            }
            
            // Static method
            public static function createUser(array $data): User {
                return new User($data);
            }
        }
        """
        
        let map = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        
        let functionCaptures = map.filter { $0.name == "function.definition" }
        XCTAssertFalse(functionCaptures.isEmpty, "Should capture function definitions")
    }
    
    func testPHPProperties() throws {
        let phpCode = """
        <?php
        
        class Product {
            // Class properties with various visibility
            public $name;
            private $price;
            protected $stock;
            
            // Typed properties (PHP 7.4+)
            public string $description;
            private ?float $discount = null;
            
            // Static property
            public static $taxRate = 0.08;
            
            // Property with default value
            protected $categories = [];
        }
        """
        
        let map = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        
        let propertyCaptures = map.filter { $0.name == "variable.field" }
        XCTAssertFalse(propertyCaptures.isEmpty, "Should capture class properties")
    }
    
    func testPHPConstants() throws {
        let phpCode = """
        <?php
        
        // Global constant using define
        define('APP_VERSION', '1.0.0');
        define('MAX_UPLOAD_SIZE', 1024 * 1024 * 10);
        
        class Config {
            // Class constant
            const DATABASE_HOST = 'localhost';
            public const API_KEY = 'secret';
            private const CACHE_TTL = 3600;
        }
        """
        
        let map = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        
        let constantCaptures = map.filter { $0.name.hasPrefix("constant") }
        XCTAssertFalse(constantCaptures.isEmpty, "Should capture constants")
    }
    
    // MARK: - PHP CodeMapGenerator Integration
    
    func testPHPCompleteCodeMapGeneration() throws {
        let phpCode = """
        <?php
        namespace App\\Services;
        
        use App\\Models\\User;
        use App\\Repositories\\UserRepository;
        
        class UserService {
            private UserRepository $repository;
            
            public function __construct(UserRepository $repository) {
                $this->repository = $repository;
            }
            
            public function findUser(int $id): ?User {
                return $this->repository->find($id);
            }
            
            public function createUser(array $data): User {
                return $this->repository->create($data);
            }
            
            private function validateUserData(array $data): bool {
                return isset($data['email']) && filter_var($data['email'], FILTER_VALIDATE_EMAIL);
            }
        }
        """
        
        let captures = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        let fileAPI = CodeMapGenerator.generateCodeMap(
            from: captures,
            content: phpCode,
            fullPath: "/test/UserService.php"
        )
        
        XCTAssertNotNil(fileAPI)
        XCTAssertFalse(fileAPI!.imports.isEmpty, "Should have imports")
        XCTAssertFalse(fileAPI!.classes.isEmpty, "Should have classes")
        
        if let userServiceClass = fileAPI!.classes.first(where: { $0.name == "UserService" }) {
            XCTAssertTrue(userServiceClass.methods.contains(where: { $0.name == "__construct" }))
            XCTAssertTrue(userServiceClass.methods.contains(where: { $0.name == "findUser" }))
            XCTAssertTrue(userServiceClass.methods.contains(where: { $0.name == "createUser" }))
            XCTAssertTrue(userServiceClass.methods.contains(where: { $0.name == "validateUserData" }))
            XCTAssertTrue(userServiceClass.properties.contains(where: { $0.name.contains("repository") }))
        }
    }
    
    // MARK: - PHP Highlighting Tests
    
    func testPHPHighlighting() throws {
        let phpCode = """
        <?php
        
        // This is a comment
        
        /**
         * This is a doc comment
         */
        class User {
            private string $name = "John";
            private int $age = 30;
            
            public function getName(): string {
                return $this->name;
            }
        }
        
        function processUser(User $user): void {
            echo $user->getName();
        }
        
        $user = new User();
        processUser($user);
        """
        
        let highlights = try SyntaxManager.shared.highlight(content: phpCode, fileExtension: "php")
        
        let highlightNames = Set(highlights.map { $0.name })
        
        XCTAssertTrue(highlightNames.contains("comment"), "Should highlight comments")
        XCTAssertTrue(highlightNames.contains("string"), "Should highlight strings")
        XCTAssertTrue(highlightNames.contains("keyword"), "Should highlight keywords")
    }
    
    // MARK: - PHP Type Extraction Tests
    
    func testPHPTypeExtraction() {
        // PHP type extraction is handled purely by AST captures, not regex
        let phpVar = "$user = new User();"
        let varResult = LanguageTypeExtractor.matchAnyVariableLine(phpVar, language: .php)
        XCTAssertNil(varResult, "PHP should not use regex-based variable extraction")
        
        let phpFunc = "function getUser($id) { return User::find($id); }"
        let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(phpFunc, language: .php)
        XCTAssertNil(funcResult, "PHP should not use regex-based function extraction")
    }
    
    func testPHPTypeCleaner() {
        let phpTypes = ["array", "string", "int", "bool", "float", "object", "mixed", "User", "ProductRepository"]
        
        let filtered = TypeCleaner.filterOutPrimitiveAndSpecialTypes(phpTypes, language: .php)
        
        XCTAssertTrue(filtered.contains("User"))
        XCTAssertTrue(filtered.contains("ProductRepository"))
        XCTAssertFalse(filtered.contains("array"))
        XCTAssertFalse(filtered.contains("string"))
        XCTAssertFalse(filtered.contains("int"))
    }
    
    // MARK: - PHP Modern Features Tests
    
    func testPHP8Features() throws {
        let phpCode = """
        <?php
        
        // PHP 8 attributes
        #[Route('/api/users')]
        class UserController {
            // Union types
            public function process(int|string $id): User|null {
                return User::find($id);
            }
            
            // Named arguments and match expression
            public function getStatus(User $user): string {
                return match($user->status) {
                    'active' => 'Active User',
                    'inactive' => 'Inactive User',
                    default => 'Unknown'
                };
            }
            
            // Nullsafe operator
            public function getUserEmail(?User $user): ?string {
                return $user?->email;
            }
        }
        
        // Enum with methods
        enum UserRole: string {
            case Admin = 'admin';
            case User = 'user';
            case Guest = 'guest';
            
            public function hasPermission(string $permission): bool {
                return match($this) {
                    self::Admin => true,
                    self::User => in_array($permission, ['read', 'write']),
                    self::Guest => $permission === 'read',
                };
            }
        }
        """
        
        let captures = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        XCTAssertFalse(captures.isEmpty, "Should parse PHP 8 features")
        
        let classCaptures = captures.filter { $0.name == "type.class" }
        let enumCaptures = captures.filter { $0.name == "type.enum" }
        
        XCTAssertFalse(classCaptures.isEmpty, "Should capture PHP 8 classes")
        XCTAssertFalse(enumCaptures.isEmpty, "Should capture PHP 8 enums")
    }
    
    func testPHPAnonymousStructures() throws {
        let phpCode = """
        <?php
        
        // Anonymous class
        $logger = new class implements LoggerInterface {
            public function log($message) {
                echo $message;
            }
        };
        
        // Closure with type hints
        $processor = function(array $data): array {
            return array_map('strtoupper', $data);
        };
        
        // Arrow function (PHP 7.4+)
        $multiply = fn($x, $y) => $x * $y;
        
        // Closure with use statement
        $value = 10;
        $calculator = function($x) use ($value) {
            return $x + $value;
        };
        """
        
        let captures = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        XCTAssertFalse(captures.isEmpty, "Should parse anonymous structures")
    }
    
    // MARK: - Edge Cases
    
    func testPHPEdgeCases() throws {
        let phpCode = """
        <?php
        
        // Heredoc syntax
        $sql = <<<SQL
        SELECT * FROM users
        WHERE active = 1
        SQL;
        
        // Nowdoc syntax
        $template = <<<'HTML'
        <div class="user">
            <h1>$name</h1>
        </div>
        HTML;
        
        // Variable variables
        $$dynamicVar = 'value';
        
        // Complex array syntax
        $config = [
            'database' => [
                'host' => 'localhost',
                'port' => 3306,
            ],
            'cache' => new CacheConfig(),
        ];
        
        // Goto statement (yes, PHP has goto!)
        start:
        echo "Hello";
        if ($condition) {
            goto start;
        }
        """
        
        let captures = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        XCTAssertNotNil(captures, "Should handle PHP edge cases")
    }
    
    func testPHPMixedHTMLAndPHP() throws {
        let mixedCode = """
        <!DOCTYPE html>
        <html>
        <head>
            <title><?php echo $title; ?></title>
        </head>
        <body>
            <?php
            class ViewController {
                public function render($data) {
                    return view('template', $data);
                }
            }
            ?>
            
            <h1><?= $heading ?></h1>
            
            <?php foreach ($items as $item): ?>
                <li><?= $item->name ?></li>
            <?php endforeach; ?>
        </body>
        </html>
        """
        
        let captures = try SyntaxManager.shared.codeMap(content: mixedCode, fileExtension: "php")
        
        let classCaptures = captures.filter { $0.name == "type.class" }
        XCTAssertFalse(classCaptures.isEmpty, "Should capture classes in mixed HTML/PHP")
    }
}



// MARK: - Merged from PHPDebugTests.swift

#if DEBUG
extension PHPParserTests {
    
    // MARK: - Basic PHP Initialization Tests
    
    func testPHPInitialization() throws {
        print("\n=== PHP Initialization Test ===\n")
        
        print("1. Extension mapping check:")
        print("   php -> \(String(describing: SyntaxManager.shared.extensionToLanguage["php"]))")
        
        print("\n2. Query definitions check:")
        print("   Highlight query exists: \(!phpHighlightQuery.isEmpty)")
        print("   CodeMap query exists: \(!phpCodeMapQuery.isEmpty)")
        
        print("\n3. Language metadata and safe query creation:")
        let metadata = SyntaxManager.shared.languageMetadata(forFileExtension: "php")
        XCTAssertNotNil(metadata, "PHP metadata should exist")
        XCTAssertEqual(metadata?.displayName, "PHP")
        
        try SyntaxManager.shared.debugCompileQuery(
            queryText: "(program) @root",
            fileExtension: "php",
            originName: "PHPParserTests.testPHPInitialization"
        )
        print("   ✅ Test query compiled successfully")
    }
    
    func testPHPTreeSitterBasics() throws {
        let code = "<?php echo 'hello'; ?>"
        let description = try SyntaxManager.shared.debugTreeDescription(
            content: code,
            fileExtension: "php",
            originName: "PHPParserTests.testPHPTreeSitterBasics"
        )
        XCTAssertNotNil(description)
        print("Parse successful through SyntaxManager debug gateway")
        print("Tree: \(description ?? "<none>")")
    }
    
    // MARK: - PHP Query Compilation Tests
    
    func testPHPQueryCompilation() {
        print("\n=== Testing PHP Query Compilation ===\n")
        SyntaxManager.shared.debugGranularPHPQueries()
    }
    
    func testPHPQueriesGranularly() throws {
        XCTAssertTrue(SyntaxManager.isSupportedFileExtension("php"))
        
        let phpCode = """
        <?php
        namespace App\\Models;
        
        use App\\User;
        
        class Person {
            public $name;
            
            public function getName() {
                return $this->name;
            }
        }
        
        function globalHelper() {
            return true;
        }
        """
        
        let queryTests = [
            ("Simple program query", "(program) @root"),
            ("Namespace query", "(namespace_definition name: (namespace_name) @module)"),
            ("Import query", "(namespace_use_clause (name) @import)"),
            ("Class query", "(class_declaration name: (name) @type.class)"),
            ("Function query", "(function_definition name: (name) @function.definition)"),
            ("Method query", "(method_declaration name: (name) @function.definition)"),
            ("Property query", "(property_declaration (property_element (variable_name (name) @variable.field)))"),
            ("Parameter query", "(formal_parameters (simple_parameter name: (variable_name (name) @function.param)))"),
            ("Comment query", "(comment) @comment"),
            ("Variable query", "(variable_name) @variable"),
        ]
        
        for (testName, queryString) in queryTests {
            print("\n=== Testing: \(testName) ===")
            print("Query:\n\(queryString)")
            let result = try SyntaxManager.shared.debugRunQuery(
                queryText: queryString,
                fileExtension: "php",
                content: phpCode,
                originName: "PHPParserTests.testPHPQueriesGranularly.\(testName)"
            )
            print("✅ Query compiled and ran successfully")
            print("Root node type: \(result.rootNodeType ?? "unknown")")
            print("Total matches: \(result.matchCount)")
            for capture in result.captures {
                print("  Found \(capture.name): \(capture.textPreview)")
            }
        }
    }
    
    // MARK: - PHP Tree Structure Analysis
    
    func testPHPTreeDebug() {
        print("\n=== PHP Tree Debug ===\n")
        
        let phpCode = """
        <?php
        namespace App\\Models;
        
        use App\\User;
        
        class Person {
            public $name;
            
            public function getName() {
                return $this->name;
            }
        }
        """
        
        SyntaxManager.shared.debugPrintTree(for: phpCode, fileExtension: "php")
    }
    
    func testActualPHPTreeStructure() throws {
        let phpCode = """
        <?php
        namespace App\\Models;
        use App\\User;
        class Person {
            public $name;
            public function getName() {
                return $this->name;
            }
        }
        """
        
        print("\n=== PHP Tree Structure ===")
        let outline = try SyntaxManager.shared.debugNodeOutline(
            content: phpCode,
            fileExtension: "php",
            originName: "PHPParserTests.testActualPHPTreeStructure"
        )
        XCTAssertFalse(outline.isEmpty)
        print(outline)
    }
    
    // MARK: - PHP Node Type Validation
    
    func testPHPNodeTypes() throws {
        let phpCode = "<?php echo 'hello'; ?>"
        let outline = try SyntaxManager.shared.debugNodeOutline(
            content: phpCode,
            fileExtension: "php",
            maxDepth: 3,
            maxNodes: 40,
            originName: "PHPParserTests.testPHPNodeTypes"
        )
        XCTAssertFalse(outline.isEmpty)
        print("Parse successful through SyntaxManager debug gateway!")
        print(outline)
    }
    
    func testFindProblematicNodes() throws {
        let problematicNodes = [
            "namespace_use_clause",
            "namespace_name",
            "qualified_name",
            "property_element",
            "variable_name",
            "const_element",
            "formal_parameters",
            "simple_parameter",
            "property_promotion_parameter",
            "variadic_parameter",
            "function_call_expression",
            "arguments",
            "argument"
        ]
        
        print("\n=== Testing Individual Node Types ===")
        
        for nodeName in problematicNodes {
            let query = "(\(nodeName)) @test"
            do {
                try SyntaxManager.shared.debugCompileQuery(
                    queryText: query,
                    fileExtension: "php",
                    originName: "PHPParserTests.testFindProblematicNodes.\(nodeName)"
                )
                print("✅ \(nodeName) - valid node type")
            } catch {
                print("❌ \(nodeName) - INVALID node type")
            }
        }
    }
    
    // MARK: - PHP Query Validation
    
    func testValidatePHPQueries() {
        print("\n=== Validating PHP Queries ===\n")
        
        print("PHP Highlight Query:")
        print("-------------------")
        let lines = phpHighlightQuery.split(separator: "\n")
        var lineNum = 0
        for line in lines {
            lineNum += 1
            print("\(lineNum): \(line)")
        }
        
        print("\n\nPHP CodeMap Query:")
        print("------------------")
        let codeMapLines = phpCodeMapQuery.split(separator: "\n")
        lineNum = 0
        for line in codeMapLines {
            lineNum += 1
            print("\(lineNum): \(line)")
        }
        
        XCTAssertTrue(phpHighlightQuery.contains("@keyword"))
        XCTAssertTrue(phpHighlightQuery.contains("@string"))
        XCTAssertTrue(phpHighlightQuery.contains("@variable"))
        
        XCTAssertTrue(phpCodeMapQuery.contains("@module"))
        XCTAssertTrue(phpCodeMapQuery.contains("@type.class"))
        XCTAssertTrue(phpCodeMapQuery.contains("@function.definition"))
    }
    
    func testExpectedPHPNodes() {
        let expectedNodes = [
            "namespace_definition",
            "namespace_name",
            "namespace_use_clause",
            "class_declaration",
            "interface_declaration",
            "trait_declaration",
            "enum_declaration",
            "function_definition",
            "method_declaration",
            "property_declaration",
            "property_element",
            "variable_name",
            "const_declaration",
            "const_element",
            "formal_parameters",
            "simple_parameter"
        ]
        
        print("\n=== Expected PHP Node Types ===")
        for node in expectedNodes {
            print("- \(node)")
            let inHighlight = phpHighlightQuery.contains(node)
            let inCodeMap = phpCodeMapQuery.contains(node)
            if inHighlight || inCodeMap {
                print("  ✓ Used in: \(inHighlight ? "highlight" : "") \(inCodeMap ? "codemap" : "")")
            } else {
                print("  ⚠️  Not used in queries")
            }
        }
    }
    
    // MARK: - Grammar Tests
    
    func testPHPGrammarAvailability() {
        SyntaxManager.shared.testGrammars()
    }
}



#endif

// MARK: - Merged from PHPPerformanceTests.swift

extension PHPParserTests {
    
    // MARK: - Performance Tests
    
    func testPHPLargeFileParsing() throws {
        // Skip in CI for performance
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            return
        }
        
        // Generate a large PHP file
        var phpCode = "<?php\n"
        phpCode += "namespace App\\Generated;\n\n"
        
        // Add many classes with methods
        for i in 1...50 {
            phpCode += """
            class GeneratedClass\(i) {
                private $property\(i);
                
                public function method\(i)($param) {
                    return $this->property\(i);
                }
                
                public static function staticMethod\(i)() {
                    return 'static';
                }
            }
            
            """
        }
        
        // Measure parsing time
        let startTime = Date()
        let captures = try SyntaxManager.shared.codeMap(content: phpCode, fileExtension: "php")
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertFalse(captures.isEmpty, "Should parse large file")
        XCTAssertLessThan(elapsed, 5.0, "Should parse large file in reasonable time")
        
        print("Parsed large PHP file with \(captures.count) captures in \(elapsed) seconds")
    }
    
    func testPHPHighlightPerformance() throws {
        // Skip in CI
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            return
        }
        
        // Create a moderately sized PHP file
        var phpCode = "<?php\n"
        for i in 1...100 {
            phpCode += """
            
            // Comment for function \(i)
            function testFunction\(i)($param\(i)) {
                $result = "string value \(i)";
                return $result;
            }
            
            """
        }
        
        let startTime = Date()
        let highlights = try SyntaxManager.shared.highlight(content: phpCode, fileExtension: "php")
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertFalse(highlights.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "Highlighting should be fast")
        
        print("Highlighted PHP file with \(highlights.count) captures in \(elapsed) seconds")
    }
    
    // MARK: - Stress Tests
    
    func testPHPComplexCodeParsing() throws {
        let complexPhpCode = """
        <?php
        namespace App\\Complex\\Example;
        
        use App\\Base\\{Controller, Model, View};
        use function App\\Helpers\\{format_date, sanitize_input};
        use const App\\Config\\{MAX_UPLOAD_SIZE, CACHE_DURATION};
        
        /**
         * Complex PHP class demonstrating various features
         */
        #[Route('/api/v2')]
        #[Middleware(['auth', 'throttle:60,1'])]
        class ComplexController extends Controller implements JsonSerializable, Countable {
            use LoggableTrait, CacheableTrait {
                LoggableTrait::log insteadof CacheableTrait;
                CacheableTrait::log as cacheLog;
            }
            
            private const VERSION = '2.0.0';
            protected static ?array $instances = null;
            
            public function __construct(
                private readonly DatabaseInterface $db,
                protected ?LoggerInterface $logger = null,
                public array $config = []
            ) {
                parent::__construct();
                $this->logger ??= new NullLogger();
            }
            
            #[Route('/users/{id}', methods: ['GET', 'POST'])]
            public function getUser(int|string $id): JsonResponse|RedirectResponse {
                try {
                    $user = $this->db->transaction(function () use ($id) {
                        return User::query()
                            ->with(['roles', 'permissions'])
                            ->where('id', $id)
                            ->orWhere('uuid', $id)
                            ->firstOrFail();
                    });
                    
                    return match($this->request->method()) {
                        'GET' => new JsonResponse($user),
                        'POST' => $this->updateUser($user),
                        default => throw new MethodNotAllowedException()
                    };
                } catch (ModelNotFoundException $e) {
                    $this->logger?->warning('User not found', ['id' => $id]);
                    throw new NotFoundHttpException('User not found');
                } finally {
                    $this->cacheLog('user_access', $id);
                }
            }
            
            public function __invoke(Request $request): Response {
                return $this->handle($request);
            }
            
            public function jsonSerialize(): mixed {
                return [
                    'version' => self::VERSION,
                    'instance_count' => count(self::$instances ?? [])
                ];
            }
            
            public function count(): int {
                return count($this->config);
            }
        }
        
        // Global scope code
        if (!function_exists('dd')) {
            function dd(...$args): never {
                var_dump(...$args);
                exit(1);
            }
        }
        
        $result = (function () {
            return fn($x) => $x * 2;
        })();
        
        $value = $result(21);
        """
        
        let startTime = Date()
        let captures = try SyntaxManager.shared.codeMap(content: complexPhpCode, fileExtension: "php")
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertFalse(captures.isEmpty, "Should parse complex PHP code")
        print("Parsed complex PHP code with \(captures.count) captures in \(elapsed) seconds")
        
        // Test highlighting too
        let highlightStart = Date()
        let highlights = try SyntaxManager.shared.highlight(content: complexPhpCode, fileExtension: "php")
        let highlightElapsed = Date().timeIntervalSince(highlightStart)
        
        XCTAssertFalse(highlights.isEmpty, "Should highlight complex PHP code")
        print("Highlighted complex PHP code with \(highlights.count) captures in \(highlightElapsed) seconds")
    }
    
    func testPHPMemoryUsage() throws {
        // Skip in CI
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            return
        }
        
        // Test memory usage with multiple parse operations
        let phpCode = """
        <?php
        class TestClass {
            public function testMethod() {
                return "test";
            }
        }
        """
        
        // Perform multiple parse operations through the safe value-returning API
        for i in 1...100 {
            XCTAssertTrue(try SyntaxManager.shared.parseSucceeds(content: phpCode, fileExtension: "php"))
            if i % 10 == 0 {
                print("Completed \(i) parse operations")
            }
        }
        
        print("Memory test completed successfully")
    }
}
