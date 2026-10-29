class TranslationRecord {
  final int? id;
  final int userId;
  final String inputType;
  final String inputLabel;
  final String translatedText;
  final double confidence;
  final String source;
  final DateTime createdAt;

  const TranslationRecord({
    this.id,
    required this.userId,
    required this.inputType,
    required this.inputLabel,
    required this.translatedText,
    this.confidence = 0.0,
    this.source = 'cloud',
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'user_id': userId,
    'input_type': inputType,
    'input_label': inputLabel,
    'translated_text': translatedText,
    'confidence': confidence,
    'source': source,
    'created_at': createdAt.toIso8601String(),
  };

  factory TranslationRecord.fromMap(Map<String, Object?> map) =>
      TranslationRecord(
        id: map['id'] as int?,
        userId: map['user_id'] as int,
        inputType: map['input_type'] as String,
        inputLabel: map['input_label'] as String,
        translatedText: map['translated_text'] as String,
        confidence: (map['confidence'] as num).toDouble(),
        source: map['source'] as String? ?? 'cloud',
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}
