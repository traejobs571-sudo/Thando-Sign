class GestureItem {
  final int? id;
  final String? uuid;
  final String label;
  final String meaning;
  final String category;
  final String imageUrl;
  final bool isActive;
  final DateTime createdAt;

  const GestureItem({
    this.id,
    this.uuid,
    required this.label,
    required this.meaning,
    this.category = 'General',
    this.imageUrl = '',
    this.isActive = true,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'uuid': uuid,
    'label': label,
    'meaning': meaning,
    'category': category,
    'image_url': imageUrl,
    'is_active': isActive ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory GestureItem.fromMap(Map<String, Object?> map) => GestureItem(
    id: map['id'] as int?,
    uuid: map['uuid'] as String?,
    label: map['label'] as String,
    meaning: map['meaning'] as String,
    category: map['category'] as String? ?? 'General',
    imageUrl: map['image_url'] as String? ?? '',
    isActive: (map['is_active'] as int? ?? 1) == 1,
    createdAt: DateTime.parse(map['created_at'] as String),
  );
}
