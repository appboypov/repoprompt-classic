// Edge case: Attributes and modifiers that complicate signature extraction
// These patterns test how @attributes, access modifiers, and Swift 5.5+ features are handled

import Foundation

// MARK: - Edge Case 1: Multiple stacked attributes

@available(macOS 14.0, iOS 17.0, *)
@MainActor
@discardableResult
func performUpdateAttr(
    with configuration: UpdateConfigurationAttr
) async throws -> UpdateResultAttr {
    // Body should not be captured - only the attributes + signature
    try await Task.sleep(nanoseconds: 1_000_000)
    return UpdateResultAttr(success: true)
}

struct UpdateConfigurationAttr {}
struct UpdateResultAttr { let success: Bool }

// MARK: - Edge Case 2: Property with willSet/didSet

class StateManager {
    var currentStateAttr: AppStateAttr = .idle {
        willSet {
            // willSet body should not be captured
            print("State changing from \(currentStateAttr) to \(newValue)")
        }
        didSet {
            // didSet body should not be captured
            handleStateChangeAttr(from: oldValue, to: currentStateAttr)
        }
    }
}

enum AppStateAttr { case idle, loading, loaded, error }
func handleStateChangeAttr(from: AppStateAttr, to: AppStateAttr) {}

// MARK: - Edge Case 3: @resultBuilder struct

@resultBuilder
struct ArrayBuilderAttr<Element> {
    static func buildBlock(_ components: Element...) -> [Element] {
        // Body should not be captured
        components
    }
    
    static func buildOptional(_ component: [Element]?) -> [Element] {
        // Body should not be captured
        component ?? []
    }
    
    static func buildEither(first component: [Element]) -> [Element] {
        // Body should not be captured
        component
    }
    
    static func buildEither(second component: [Element]) -> [Element] {
        // Body should not be captured
        component
    }
    
    static func buildArray(_ components: [[Element]]) -> [Element] {
        // Body should not be captured
        components.flatMap { $0 }
    }
}

// MARK: - Edge Case 4: @inlinable and @usableFromInline

@inlinable
func fastOperationAttr<T: Numeric>(_ value: T, multiplier: T) -> T {
    // Body should not be captured even though it's inlinable
    value * multiplier
}

@usableFromInline
internal func helperOperationAttr<T: Numeric>(_ value: T) -> T {
    // Body should not be captured
    value + value
}

// MARK: - Edge Case 5: @autoclosure and @escaping combinations

func evaluateAttr(
    condition: @autoclosure () -> Bool,
    ifTrue: @escaping @Sendable () async -> Void,
    ifFalse: @escaping @Sendable () async -> Void
) async {
    // Body should not be captured
    if condition() {
        await ifTrue()
    } else {
        await ifFalse()
    }
}

// MARK: - Edge Case 6: @frozen enum with complex cases

@frozen
enum NetworkErrorAttr: Error, Sendable {
    case connectionFailed(underlying: Error, attemptCount: Int)
    case timeout(after: TimeInterval, request: URLRequest)
    case invalidResponse(statusCode: Int, body: Data?)
    case decodingFailed(type: String, error: DecodingError)
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized(reason: AuthFailureReasonAttr)
    case serverError(code: Int, message: String, recoverable: Bool)
    
    enum AuthFailureReasonAttr: Sendable {
        case tokenExpired
        case tokenRevoked
        case insufficientPermissions([String])
    }
}

// MARK: - Edge Case 7: Actor with nonisolated methods

actor DataManagerAttr {
    private var cache: [String: Data] = [:]
    
    nonisolated func cacheKey(for url: URL) -> String {
        // nonisolated body should not be captured
        url.absoluteString.lowercased()
    }
    
    nonisolated var identifier: String {
        // nonisolated computed property body should not be captured
        "DataManager-\(ObjectIdentifier(self))"
    }
    
    func store(_ data: Data, forKey key: String) async {
        // Actor method body should not be captured
        cache[key] = data
    }
    
    func retrieve(forKey key: String) async -> Data? {
        // Actor method body should not be captured
        cache[key]
    }
}

// MARK: - Edge Case 8: @Sendable closures in parameters

func executeInBackgroundAttr(
    priority: TaskPriority = .medium,
    operation: @Sendable @escaping () async throws -> Void,
    onSuccess: @Sendable @escaping () -> Void,
    onFailure: @Sendable @escaping (Error) -> Void
) {
    // Body should not be captured
    Task(priority: priority) {
        do {
            try await operation()
            await MainActor.run { onSuccess() }
        } catch {
            await MainActor.run { onFailure(error) }
        }
    }
}

// MARK: - Edge Case 9: Existential any and some

func processItemsAttr<T>(
    _ items: some Collection<T>,
    using processor: any ItemProcessorAttr
) -> [any ProcessableAttr] where T: ProcessableAttr {
    // Body should not be captured
    items.compactMap { item in
        processor.process(item) ? item : nil
    }
}

protocol ItemProcessorAttr {
    func process(_ item: any ProcessableAttr) -> Bool
}

protocol ProcessableAttr {}

// MARK: - Edge Case 10: Typed throws (Swift 6)

enum ValidationErrorAttr: Error {
    case invalidInput(String)
    case outOfRange(min: Int, max: Int, actual: Int)
}

func validateAttr(
    input: String,
    range: ClosedRange<Int>
) throws(ValidationErrorAttr) -> Int {
    // Body should not be captured
    guard let value = Int(input) else {
        throw .invalidInput(input)
    }
    guard range.contains(value) else {
        throw .outOfRange(min: range.lowerBound, max: range.upperBound, actual: value)
    }
    return value
}

// MARK: - Edge Case 11: Class with multiple inheritance-like patterns

class BaseServiceAttr {
    func setup() {
        // Body should not be captured
        print("Setting up base service")
    }
}

protocol ServiceProtocolAttr {
    func start() async
    func stop() async
}

protocol ConfigurableAttr {
    associatedtype Config
    func configure(with config: Config) throws
}

final class ConcreteServiceAttr: BaseServiceAttr, ServiceProtocolAttr, ConfigurableAttr {
    typealias Config = [String: Any]
    
    override func setup() {
        // Body should not be captured
        super.setup()
        print("Setting up concrete service")
    }
    
    func start() async {
        // Body should not be captured
        setup()
        print("Service started")
    }
    
    func stop() async {
        // Body should not be captured
        print("Service stopped")
    }
    
    func configure(with config: Config) throws {
        // Body should not be captured
        guard !config.isEmpty else {
            throw NSError(domain: "ConfigError", code: 1)
        }
        print("Configured with \(config.count) options")
    }
}

// MARK: - Edge Case 12: Subscript with multiple parameters

struct MatrixAttr<T> {
    private var storage: [[T]]
    
    subscript(row: Int, column: Int) -> T {
        get {
            // Getter body should not be captured
            storage[row][column]
        }
        set {
            // Setter body should not be captured
            storage[row][column] = newValue
        }
    }
    
    subscript(safe row: Int, column: Int) -> T? {
        // Body should not be captured
        guard row >= 0 && row < storage.count else { return nil }
        guard column >= 0 && column < storage[row].count else { return nil }
        return storage[row][column]
    }
    
    init(rows: Int, columns: Int, defaultValue: T) {
        storage = Array(repeating: Array(repeating: defaultValue, count: columns), count: rows)
    }
}
