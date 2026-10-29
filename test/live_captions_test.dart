import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/controllers/translation_controller.dart';

void main() {
  group('mergeLiveSegment', () {
    test('appends to an empty transcript', () {
      expect(
        TranslationController.mergeLiveSegment('', 'hello world'),
        'hello world',
      );
    });

    test('merges overlapping words once', () {
      expect(
        TranslationController.mergeLiveSegment(
          'hello how',
          'how are you',
        ),
        'hello how are you',
      );
    });

    test('multi-word overlap merges at the longest boundary', () {
      expect(
        TranslationController.mergeLiveSegment(
          'good morning everyone',
          'morning everyone thank you',
        ),
        'good morning everyone thank you',
      );
    });

    test('no overlap appends the whole segment', () {
      expect(
        TranslationController.mergeLiveSegment('hello', 'thank you'),
        'hello thank you',
      );
    });

    test('identical segment adds nothing', () {
      expect(
        TranslationController.mergeLiveSegment('hello', 'hello'),
        'hello',
      );
    });

    test('empty segment keeps the transcript unchanged', () {
      expect(
        TranslationController.mergeLiveSegment('hello', '   '),
        'hello',
      );
    });
  });
}
