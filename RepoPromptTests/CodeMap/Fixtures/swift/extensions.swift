// Swift Extension Test Fixture
// Tests that methods and properties in extensions are correctly captured as members

import Foundation

// MARK: - Base Types

class ExtensionTarget {
    var baseProperty: String = ""
    
    func baseMethod() -> String {
        return "base"
    }
}

protocol ExtensionProtocol {
    func requiredMethod() async throws -> Int
    var requiredProperty: String { get }
}

// MARK: - Extensions

extension ExtensionTarget {
    func extensionMethod(param: Int) -> String {
        return "extension \(param)"
    }
    
    var computedProperty: Int {
        return 42
    }
    
    func anotherExtensionMethod() {
        // body
    }
}

// Extension on a protocol providing default implementations
extension ExtensionProtocol {
    func defaultImplementation() async throws -> Int {
        return 0
    }
    
    func anotherDefault() -> String {
        return "default"
    }
}

// Extension with where clause (generic constraint)
extension Array where Element: Equatable {
    func customContains(_ element: Element) -> Bool {
        return contains(element)
    }
}

// Extension on a nested type path (using dot notation)
extension String.UTF8View {
    var customCount: Int {
        return count
    }
}
