class User {
  final int id;
  String name;

  User(this.id, this.name);

  User.anonymous() : id = 0, name = "anon";

  factory User.fromMap(Map<String, dynamic> data) {
    return User(data["id"] as int, data["name"] as String);
  }

  String get displayName => "$name#$id";

  set displayName(String value) {
    name = value;
  }
}

String formatUser(User user) => "${user.name}:${user.id}";

int maxUsers = 10;
