// Smoke test fixture for Swift codemap extraction
import Foundation
import Combine

/// A sample protocol for testing interface extraction
protocol DataProvider {
    associatedtype Item
    func fetch() async throws -> [Item]
}

/// A sample class demonstrating full codemap extraction
class UserManager: DataProvider {
    typealias Item = User
    
    // MARK: - Properties
    
    private let apiClient: APIClient
    private(set) var currentUser: User?
    static let shared = UserManager()
    
    // MARK: - Initialization
    
    init(apiClient: APIClient = .default) {
        self.apiClient = apiClient
    }
    
    // MARK: - DataProvider
    
    func fetch() async throws -> [User] {
        return try await apiClient.fetchUsers()
    }
    
    // MARK: - User Management
    
    func login(credentials: LoginCredentials) async throws -> User {
        let user = try await apiClient.authenticate(credentials)
        self.currentUser = user
        return user
    }
    
    func logout() {
        currentUser = nil
    }
}

/// User model struct
struct User: Codable, Identifiable {
    let id: UUID
    var name: String
    var email: String
    let createdAt: Date
}

/// Login credentials
struct LoginCredentials {
    let username: String
    let password: String
}

/// User roles enumeration
enum UserRole: String, CaseIterable {
    case admin
    case editor
    case viewer
    case guest
}

/// API client placeholder
class APIClient {
    static let `default` = APIClient()
    
    func fetchUsers() async throws -> [User] { [] }
    func authenticate(_ credentials: LoginCredentials) async throws -> User {
        fatalError("Not implemented")
    }
}

// Global configuration
let maxRetryCount = 3
var isDebugMode = false

/// Standalone utility function
func formatUserName(_ user: User) -> String {
    return user.name.capitalized
}
