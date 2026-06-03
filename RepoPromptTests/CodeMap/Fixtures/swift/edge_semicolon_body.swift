// Test case: Swift functions with semicolons inside their bodies
// This tests that signature extraction stops at `{` and doesn't leak
// into the body when the body contains semicolons.

import Foundation

/// Function with SQL string containing semicolons
func executeSQLQuery(database: String, table: String) -> [String] {
    let query = "SELECT * FROM \(table); DELETE FROM temp_table;"
    return [query]
}

/// Function with multiple statements using semicolons (unusual but valid Swift)
func legacyCodeWithSemicolons(value: Int) -> Int {
    var result = value; result += 10; result *= 2;
    return result
}

/// Function with JSON-like string containing semicolons
func buildConfigString() -> String {
    return """
    {
        "rules": "a=1; b=2; c=3;",
        "delimiter": ";",
        "separator": "; "
    }
    """
}

/// Async function with semicolons in body (common in real code)
func processDataAsync(items: [String]) async throws -> Int {
    var count = 0; for item in items { count += 1; }
    return count
}

/// Generic function with complex body containing semicolons
func transform<T: Hashable>(
    input: [T],
    using closure: (T) -> String
) -> [String] {
    var results: [String] = []; for item in input { results.append(closure(item)); }
    return results
}

/// Method in a class with semicolons in body
class DataProcessor {
    private var cache: [String: Any] = [:]
    
    func process(key: String, value: String) -> Bool {
        cache[key] = value; print("Cached: \(key);"); return true;
    }
    
    func clear() {
        cache.removeAll(); print("Cache cleared;");
    }
}

/// Protocol with requirements (no bodies, but tests protocol handling)
protocol SQLExecutor {
    func execute(query: String) async throws -> [String]
    var connectionString: String { get }
}
