// Smoke test fixture for Java codemap extraction
package com.example.user;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

/**
 * User role enumeration
 */
public enum UserRole {
    ADMIN("admin"),
    EDITOR("editor"),
    VIEWER("viewer"),
    GUEST("guest");

    private final String value;

    UserRole(String value) {
        this.value = value;
    }

    public String getValue() {
        return value;
    }
}

/**
 * Data provider interface
 */
interface DataProvider<T> {
    List<T> fetch();
    void save(T item);
    boolean delete(String id);
}

/**
 * User data model
 */
class User {
    private final String id;
    private String name;
    private String email;
    private UserRole role;
    private final Date createdAt;

    public User(String id, String name, String email) {
        this.id = id;
        this.name = name;
        this.email = email;
        this.role = UserRole.GUEST;
        this.createdAt = new Date();
    }

    // Getters
    public String getId() { return id; }
    public String getName() { return name; }
    public String getEmail() { return email; }
    public UserRole getRole() { return role; }
    public Date getCreatedAt() { return createdAt; }

    // Setters
    public void setName(String name) { this.name = name; }
    public void setEmail(String email) { this.email = email; }
    public void setRole(UserRole role) { this.role = role; }

    public String getDisplayName() {
        return String.format("%s (%s)", name, role.getValue());
    }

    public boolean validate() {
        return id != null && !id.isEmpty() && name != null && !name.isEmpty();
    }

    @Override
    public String toString() {
        return "User{id='" + id + "', name='" + name + "'}";
    }
}

/**
 * Service configuration
 */
class Config {
    private int maxUsers;
    private int timeoutSeconds;

    public static final int DEFAULT_MAX_USERS = 1000;
    public static final int DEFAULT_TIMEOUT = 30;

    public Config() {
        this(DEFAULT_MAX_USERS, DEFAULT_TIMEOUT);
    }

    public Config(int maxUsers, int timeoutSeconds) {
        this.maxUsers = maxUsers;
        this.timeoutSeconds = timeoutSeconds;
    }

    public int getMaxUsers() { return maxUsers; }
    public int getTimeoutSeconds() { return timeoutSeconds; }
}

/**
 * User service for managing users
 */
class UserService implements DataProvider<User> {
    private final Map<String, User> users;
    private final Config config;
    
    private static UserService instance;

    public UserService(Config config) {
        this.users = new ConcurrentHashMap<>();
        this.config = config;
    }

    public static synchronized UserService getInstance(Config config) {
        if (instance == null) {
            instance = new UserService(config);
        }
        return instance;
    }

    @Override
    public List<User> fetch() {
        return new ArrayList<>(users.values());
    }

    @Override
    public void save(User user) {
        if (user == null) {
            throw new IllegalArgumentException("User cannot be null");
        }
        if (!user.validate()) {
            throw new IllegalArgumentException("Invalid user data");
        }
        if (users.size() >= config.getMaxUsers()) {
            throw new IllegalStateException("Max users reached");
        }
        users.put(user.getId(), user);
    }

    @Override
    public boolean delete(String id) {
        return users.remove(id) != null;
    }

    public Optional<User> find(String id) {
        return Optional.ofNullable(users.get(id));
    }

    public List<User> getByRole(UserRole role) {
        return users.values().stream()
            .filter(u -> u.getRole() == role)
            .collect(Collectors.toList());
    }

    public int count() {
        return users.size();
    }
}

/**
 * User factory class
 */
class UserFactory {
    private static int counter = 0;

    public static User create(String name, String email) {
        return create(name, email, UserRole.GUEST);
    }

    public static User create(String name, String email, UserRole role) {
        User user = new User("user_" + (++counter), name, email);
        user.setRole(role);
        return user;
    }

    public static boolean validateEmail(String email) {
        return email != null && email.contains("@");
    }
}
