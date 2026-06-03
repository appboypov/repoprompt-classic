// Edge case: Multi-line function signatures with closures and generics
// These patterns cause the codemap to capture entire method bodies instead of just signatures
// EXPECT_REFERENCED_TYPES: TreeNodeEdge, TreeEntryEdge, FolderNodeEdge, TreeResultEdge, EventCodeEdge, SeverityEdge, ServerIssueEdge, ServiceSnapshotEdge, UUID, ItemEdge
// FORBID_REFERENCED_TYPES: Sendable, Error, Swift.Error, Codable, AnyObject
// EXPECT_FUNCTION_TYPES_FOR: buildTreeEdge => FolderNodeEdge, UUID, TreeResultEdge
// EXPECT_FUNCTION_TYPES_FOR: renderTreeEdge => TreeNodeEdge, TreeEntryEdge
// EXPECT_PROPERTY_TYPES_FOR: recentEvent => EventCodeEdge, SeverityEdge

import Foundation

// MARK: - Edge Case 1: Multi-line generic function with closure parameter

func runToolEdge<T>(
    _ name: String,
    flushFS flush: Bool = true,
    timeoutSeconds: Int = 10000,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    // This entire body should NOT be in definitionLine
    let startTime = Date()
    defer {
        let elapsed = Date().timeIntervalSince(startTime)
        print("Tool \(name) took \(elapsed)s")
    }
    
    if flush {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    return try await body()
}

// MARK: - Edge Case 2: Function with where clause spanning multiple lines

func processEdge<T, U>(
    items: [T],
    transform: (T) -> U,
    filter: (U) -> Bool
) -> [U] where T: Hashable,
               U: Equatable,
               T: Sendable {
    // Body should not be captured
    return items.map(transform).filter(filter)
}

// MARK: - Edge Case 3: Class with @MainActor function

class BackgroundUpdater {
    private var updateTask: Task<Void, Never>?
    private var updateStream: AsyncStream<String> { AsyncStream { _ in } }
    private var latestUpdate: String = ""

    @MainActor
    func startBackgroundUpdates() {
        // None of this should be in definitionLine
        stopUpdates()
        
        updateTask = Task { [weak self] in
            guard let self else { return }
            
            for await update in self.updateStream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.latestUpdate = update
                }
            }
        }
    }

    func stopUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }
}

// MARK: - Edge Case 4: Computed property with complex getter

class ContextProvider {
    private var recentEvent: (name: String, code: EventCodeEdge, severity: SeverityEdge, description: String)?
    private var isConnected = false

    var contextualDescription: String? {
        // This entire getter body should NOT be captured
        guard let event = recentEvent else { return nil }
        
        let name = event.name
        
        switch (event.code, event.severity) {
        case (.networkError, .critical):
            return "\(name) experienced a critical network error."
        case (.timeout, _) where !isConnected:
            return "\(name) timed out while disconnected."
        case (.authFailed, .warning):
            return "\(name) authentication warning."
        default:
            return event.description
        }
    }
}

enum EventCodeEdge { case networkError, timeout, authFailed, other }
enum SeverityEdge { case critical, warning, info }

// MARK: - Edge Case 5: Function with multiple trailing closures

func renderTreeEdge(
    nodes: [TreeNodeEdge],
    basePath: String,
    folderSuffix: (String) -> String?,
    fileLine: (TreeEntryEdge, String) -> String,
    fileChildren: (TreeEntryEdge, String) -> [String]
) -> [String] {
    // None of this body should be captured
    var lines: [String] = []
    
    for node in nodes {
        let prefix = basePath.isEmpty ? "" : basePath + "/"
        if let suffix = folderSuffix(node.path) {
            lines.append("\(prefix)\(node.name)\(suffix)")
        }
        
        for entry in node.entries {
            let line = fileLine(entry, entry.name)
            lines.append(line)
            lines.append(contentsOf: fileChildren(entry, "  "))
        }
    }
    
    return lines
}

struct TreeNodeEdge {
    let name: String
    let path: String
    let entries: [TreeEntryEdge]
}

struct TreeEntryEdge {
    let name: String
    let count: Int
}

// MARK: - Edge Case 6: Nested function definitions

func buildTreeEdge(
    roots: [FolderNodeEdge],
    selectedIDs: Set<UUID>,
    tokenBudget: Int?
) -> TreeResultEdge {
    // This body AND the nested function should not be captured
    var output = StringBuilderEdge()
    var usedMarker = false
    
    func emitNode(node: FolderNodeEdge, prefix: String, isLast: Bool) -> Bool {
        // Nested function body
        if Task.isCancelled { return true }
        if let budget = tokenBudget, output.count >= budget { return true }
        
        let marker = isLast ? "└── " : "├── "
        let selected = selectedIDs.contains(node.id) ? " *" : ""
        output.append("\(prefix)\(marker)\(node.name)\(selected)\n")
        
        return false
    }
    
    for (index, root) in roots.enumerated() {
        let isLast = index == roots.count - 1
        if emitNode(node: root, prefix: "", isLast: isLast) {
            return .exceededBudget
        }
    }
    
    return .success(output.result, usedMarker)
}

struct FolderNodeEdge {
    let id: UUID
    let name: String
}

enum TreeResultEdge {
    case success(String, Bool)
    case exceededBudget
}

class StringBuilderEdge {
    private var buffer = ""
    var count: Int { buffer.count }
    var result: String { buffer }
    func append(_ s: String) { buffer += s }
}

// MARK: - Edge Case 7: Switch with associated values as return

func humanReadableErrorEdge(from issue: ServerIssueEdge) -> String? {
    // Switch body should not be captured
    switch issue {
    case .none:
        return nil
    case .permissionDenied:
        return "Permission denied. Check your settings."
    case .registrationFailed(let message):
        return "Registration failed: \(message)"
    case .restarting:
        return "Service is restarting."
    case .portConflict:
        return "Port is in use by another process."
    case .degraded(let reason):
        return "Service degraded: \(reason)"
    case .clientDenied(let clientID):
        return "Client \(clientID) was denied access."
    case .timeout(let clientID):
        return "Client \(clientID ?? "unknown") timed out."
    case .unexpectedDisconnect(let clientID):
        return "Client \(clientID ?? "unknown") disconnected unexpectedly."
    }
}

enum ServerIssueEdge {
    case none
    case permissionDenied
    case registrationFailed(String)
    case restarting
    case portConflict
    case degraded(String)
    case clientDenied(String)
    case timeout(String?)
    case unexpectedDisconnect(String?)
}

// MARK: - Edge Case 8: Class with async method and guard chain

class ServiceApplier {
    private var pendingID: String?
    private var isRunning = false
    private var lastError: String?
    private var showOverlay = false
    private var isActive = false
    private var dashboard: Any?

    private func apply(_ snapshot: ServiceSnapshotEdge) async {
        // None of this should be in definitionLine
        let hadPending = self.pendingID != nil
        
        self.isRunning = snapshot.isRunning
        self.pendingID = snapshot.pendingID
        self.lastError = humanReadableErrorEdge(from: snapshot.issue)
        
        self.showOverlay = snapshot.pendingID != nil
        
        if snapshot.pendingID != nil && !hadPending {
            bringToFrontEdge()
        }
        
        if snapshot.pendingID != nil && !isActive {
            requestAttentionEdge()
        }
        
        let dashboard = await fetchDashboardEdge()
        self.dashboard = dashboard
    }
}

struct ServiceSnapshotEdge {
    let isRunning: Bool
    let pendingID: String?
    let issue: ServerIssueEdge
}

func bringToFrontEdge() {}
func requestAttentionEdge() {}
func fetchDashboardEdge() async -> Any { [:] }

// MARK: - Edge Case 9: Protocol with associated type and default implementation

protocol DataProviderEdge {
    associatedtype ItemEdge: Codable & Sendable
    associatedtype ErrorEdge: Swift.Error
    
    func fetch() async throws -> [ItemEdge]
    func save(_ item: ItemEdge) async throws
    func delete(id: String) async throws -> Bool
}

extension DataProviderEdge {
    // Default implementations - these should have clean signatures too
    func fetchAll() async throws -> [ItemEdge] {
        // Body should not be captured
        return try await fetch()
    }
    
    func saveAll(_ items: [ItemEdge]) async throws {
        // Body should not be captured
        for item in items {
            try await save(item)
        }
    }
}

// MARK: - Edge Case 10: Property wrapper with projectedValue

@propertyWrapper
struct ValidatedEdge<Value> {
    private var value: Value
    private let validator: (Value) -> Bool
    
    var wrappedValue: Value {
        get { value }
        set {
            // Setter body should not be captured
            if validator(newValue) {
                value = newValue
            } else {
                print("Validation failed for \(newValue)")
            }
        }
    }
    
    var projectedValue: Bool {
        // Computed property body should not be captured
        validator(value)
    }
    
    init(wrappedValue: Value, validator: @escaping (Value) -> Bool) {
        // Init body should not be captured
        self.value = wrappedValue
        self.validator = validator
    }
}
