// Smoke test fixture for C++ codemap extraction
#include <string>
#include <vector>
#include <map>
#include <memory>
#include <optional>
#include <functional>

namespace user {

// Constants
constexpr int MAX_USERS = 1000;
constexpr int DEFAULT_TIMEOUT = 30;

// User role enumeration
enum class UserRole {
    Admin,
    Editor,
    Viewer,
    Guest
};

// Forward declarations
class User;
class UserService;

// Type aliases
using UserPtr = std::shared_ptr<User>;
using UserMap = std::map<std::string, UserPtr>;
using UserCallback = std::function<void(const User&)>;

// Configuration structure
struct Config {
    int maxUsers = MAX_USERS;
    int timeoutSecs = DEFAULT_TIMEOUT;
};

// User class
class User {
public:
    User(std::string id, std::string name, std::string email)
        : id_(std::move(id))
        , name_(std::move(name))
        , email_(std::move(email))
        , role_(UserRole::Guest) {}
    
    // Getters
    const std::string& id() const { return id_; }
    const std::string& name() const { return name_; }
    const std::string& email() const { return email_; }
    UserRole role() const { return role_; }
    
    // Setters
    void setRole(UserRole role) { role_ = role; }
    void setName(const std::string& name) { name_ = name; }
    
    // Methods
    std::string displayName() const {
        return name_ + " (" + roleToString(role_) + ")";
    }
    
    bool validate() const {
        return !id_.empty() && !name_.empty();
    }
    
    static std::string roleToString(UserRole role) {
        switch (role) {
            case UserRole::Admin: return "Admin";
            case UserRole::Editor: return "Editor";
            case UserRole::Viewer: return "Viewer";
            case UserRole::Guest: return "Guest";
        }
        return "Unknown";
    }

private:
    std::string id_;
    std::string name_;
    std::string email_;
    UserRole role_;
};

// Data provider interface
template<typename T>
class DataProvider {
public:
    virtual ~DataProvider() = default;
    virtual std::vector<T> fetch() = 0;
    virtual bool save(const T& item) = 0;
    virtual bool remove(const std::string& id) = 0;
};

// User service class
class UserService : public DataProvider<UserPtr> {
public:
    explicit UserService(Config config = {})
        : config_(std::move(config)) {}
    
    // DataProvider implementation
    std::vector<UserPtr> fetch() override {
        std::vector<UserPtr> result;
        result.reserve(users_.size());
        for (const auto& [id, user] : users_) {
            result.push_back(user);
        }
        return result;
    }
    
    bool save(const UserPtr& user) override {
        if (!user || !user->validate()) {
            return false;
        }
        if (static_cast<int>(users_.size()) >= config_.maxUsers) {
            return false;
        }
        users_[user->id()] = user;
        return true;
    }
    
    bool remove(const std::string& id) override {
        return users_.erase(id) > 0;
    }
    
    // Additional methods
    std::optional<UserPtr> find(const std::string& id) const {
        auto it = users_.find(id);
        if (it != users_.end()) {
            return it->second;
        }
        return std::nullopt;
    }
    
    std::vector<UserPtr> getByRole(UserRole role) const {
        std::vector<UserPtr> result;
        for (const auto& [id, user] : users_) {
            if (user->role() == role) {
                result.push_back(user);
            }
        }
        return result;
    }
    
    size_t count() const { return users_.size(); }
    
    void forEach(UserCallback callback) const {
        for (const auto& [id, user] : users_) {
            callback(*user);
        }
    }

private:
    UserMap users_;
    Config config_;
};

// Factory function
inline UserPtr createUser(const std::string& name, const std::string& email, UserRole role = UserRole::Guest) {
    static int counter = 0;
    auto user = std::make_shared<User>(
        "user_" + std::to_string(++counter),
        name,
        email
    );
    user->setRole(role);
    return user;
}

// Utility function
inline bool validateEmail(const std::string& email) {
    return email.find('@') != std::string::npos;
}

} // namespace user
