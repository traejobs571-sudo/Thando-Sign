import 'package:flutter_test/flutter_test.dart';
import 'package:thando_sign_app/models/gesture_item.dart';
import 'package:thando_sign_app/models/translation_record.dart';
import 'package:thando_sign_app/models/user.dart';

void main() {
  group('User.fromMap', () {
    test('maps db row to model', () {
      final user = User.fromMap({
        'id': 7,
        'name': 'Tino',
        'email': 'tino@example.com',
        'password_hash': r'$2a$10$hash',
        'role': 'admin',
        'is_active': 1,
        'must_change_password': 1,
        'created_at': '2026-10-12T08:30:00.000',
      });
      expect(user.id, 7);
      expect(user.name, 'Tino');
      expect(user.role, 'admin');
      expect(user.isActive, isTrue);
      expect(user.mustChangePassword, isTrue);
      expect(user.createdAt.year, 2026);
    });

    test('flags decode from 0', () {
      final user = User.fromMap({
        'id': 1,
        'name': 'A',
        'email': 'a@b.co',
        'password_hash': 'h',
        'role': 'user',
        'is_active': 0,
        'must_change_password': 0,
        'created_at': '2026-01-01T00:00:00.000',
      });
      expect(user.isActive, isFalse);
      expect(user.mustChangePassword, isFalse);
    });
  });

  group('TranslationRecord.fromMap', () {
    test('round-trips through toMap', () {
      final record = TranslationRecord(
        userId: 3,
        inputType: 'gesture',
        inputLabel: 'Hello',
        translatedText: 'Hello',
        confidence: 0.85,
        source: 'gemini',
        createdAt: DateTime(2026, 10, 12, 10, 0),
      );
      final decoded = TranslationRecord.fromMap(record.toMap());
      expect(decoded.userId, 3);
      expect(decoded.source, 'gemini');
      expect(decoded.confidence, closeTo(0.85, 1e-9));
      expect(decoded.createdAt, record.createdAt);
    });
  });

  group('GestureItem.fromMap', () {
    test('applies defaults for missing columns', () {
      final g = GestureItem.fromMap({
        'id': 2,
        'label': 'Sadza',
        'meaning': 'Maize-meal staple',
        'is_active': 1,
        'created_at': '2026-10-12T00:00:00.000',
      });
      expect(g.category, 'General');
      expect(g.imageUrl, '');
      expect(g.isActive, isTrue);
    });
  });
}
