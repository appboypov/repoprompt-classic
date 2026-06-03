// Smoke test fixture for Dart codemap extraction
import 'dart:async';
import 'dart:collection';

/// Maximum number of users allowed
const int maxUsers = 1000;

/// Default timeout duration
const Duration defaultTimeout = Duration(seconds: 30);

/// User role enumeration
enum UserRole {
  admin,
  editor,
  viewer,
  guest;

  String get displayName {
    switch (this) {
      case UserRole.admin:
        return 'Admin';
      case UserRole.editor:
        return 'Editor';
      case UserRole.viewer:
        return 'Viewer';
      case UserRole.guest:
        return 'Guest';
    }
  }
}

/// User data model
class User {
  final String id;
  String name;
  String email;
  UserRole role;
  final DateTime createdAt;

  User({
    required this.id,
    required this.name,
    required this.email,
    this.role = UserRole.guest,
  }) : createdAt = DateTime.now();

  String get displayName => '$name (${role.displayName})';

  bool validate() {
    return id.isNotEmpty && name.isNotEmpty;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'role': role.name,
    };
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      name: json['name'] as String,
      email: json['email'] as String,
      role: UserRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => UserRole.guest,
      ),
    );
  }
}

/// Abstract data provider interface
abstract class DataProvider<T> {
  Future<List<T>> fetch();
  Future<void> save(T item);
  Future<bool> delete(String id);
}

/// Service configuration
class Config {
  final int maxUsers;
  final Duration timeout;

  const Config({
    this.maxUsers = 1000,
    this.timeout = defaultTimeout,
  });
}

/// User service for managing users
class UserService implements DataProvider<User> {
  final Map<String, User> _users = {};
  final Config config;

  static UserService? _instance;

  UserService({Config? config}) : config = config ?? const Config();

  static UserService get instance {
    return _instance ??= UserService();
  }

  int get count => _users.length;

  @override
  Future<List<User>> fetch() async {
    return _users.values.toList();
  }

  @override
  Future<void> save(User user) async {
    if (!user.validate()) {
      throw ArgumentError('Invalid user data');
    }
    if (_users.length >= config.maxUsers) {
      throw StateError('Max users reached');
    }
    _users[user.id] = user;
  }

  @override
  Future<bool> delete(String id) async {
    return _users.remove(id) != null;
  }

  User? find(String id) {
    return _users[id];
  }

  List<User> getByRole(UserRole role) {
    return _users.values.where((u) => u.role == role).toList();
  }

  void clear() {
    _users.clear();
  }
}

/// Mixin for logging capability
mixin Loggable {
  void log(String message) {
    print('[${DateTime.now()}] $message');
  }
}

/// Extension methods for User
extension UserExtensions on User {
  bool get isAdmin => role == UserRole.admin;

  String toDisplayString() {
    return '$name <$email>';
  }
}

/// Factory function to create users
User createUser(String name, String email, {UserRole role = UserRole.guest}) {
  return User(
    id: 'user_${DateTime.now().millisecondsSinceEpoch}',
    name: name,
    email: email,
    role: role,
  );
}

/// Validates email format
bool validateEmail(String email) {
  return email.contains('@') && email.contains('.');
}

/// Typedef for user callback
typedef UserCallback = void Function(User user);

/// Typedef for async user loader
typedef UserLoader = Future<User> Function(String id);
