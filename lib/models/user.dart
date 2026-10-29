class User {
  final int? id;
  final String name;
  final String email;
  final String passwordHash;
  final String role;
  final bool isActive;
  final bool mustChangePassword;
  final DateTime createdAt;

  const User({
    this.id,
    required this.name,
    required this.email,
    required this.passwordHash,
    this.role = 'user',
    this.isActive = true,
    this.mustChangePassword = false,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'email': email,
    'password_hash': passwordHash,
    'role': role,
    'is_active': isActive ? 1 : 0,
    'must_change_password': mustChangePassword ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory User.fromMap(Map<String, Object?> map) => User(
    id: map['id'] as int?,
    name: map['name'] as String,
    email: map['email'] as String,
    passwordHash: map['password_hash'] as String,
    role: map['role'] as String? ?? 'user',
    isActive: (map['is_active'] as int? ?? 1) == 1,
    mustChangePassword: (map['must_change_password'] as int? ?? 0) == 1,
    createdAt: DateTime.parse(map['created_at'] as String),
  );
}
