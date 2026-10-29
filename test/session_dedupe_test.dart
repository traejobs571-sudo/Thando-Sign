import 'package:flutter_test/flutter_test.dart';
import 'package:thando_sign_app/controllers/translation_controller.dart';

void main() {
  group('TranslationController.dedupeLabels', () {
    test('collapses consecutive duplicates', () {
      expect(
        TranslationController.dedupeLabels(['A', 'A', 'A', 'B', 'B', 'C']),
        ['A', 'B', 'C'],
      );
    });

    test('keeps repeats separated by an empty-frame gap', () {
      expect(
        TranslationController.dedupeLabels(['A', 'A', null, 'A', 'B']),
        ['A', 'A', 'B'],
      );
    });

    test('drops nulls and preserves order', () {
      expect(
        TranslationController.dedupeLabels([null, 'A', null, 'B', null]),
        ['A', 'B'],
      );
    });

    test('returns empty for all-empty input', () {
      expect(TranslationController.dedupeLabels([null, null]), isEmpty);
      expect(TranslationController.dedupeLabels(const []), isEmpty);
    });
  });
}
