import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/services/gemini_service.dart';

void main() {
  const vocab = ['Hello', 'Letter A', 'Father', 'I Love You', 'Thank You'];

  GestureResult r(String gesture, {String note = '', double conf = 0.9}) =>
      GestureResult(gesture: gesture, english: gesture, confidence: conf, note: note);

  group('snapToVocabulary', () {
    test('normalises casing on an exact (case-insensitive) match', () {
      final out = GeminiService.snapToVocabulary(r('hello'), vocab);
      expect(out.gesture, 'Hello');
    });

    test('snaps a contained/fuzzy answer to the longest matching label', () {
      expect(
        GeminiService.snapToVocabulary(r('letter a'), vocab).gesture,
        'Letter A',
      );
      // 'thank you for the help' contains 'Thank You' — longest label wins.
      expect(
        GeminiService.snapToVocabulary(
          r('thank you for the help'),
          vocab,
        ).gesture,
        'Thank You',
      );
      // 'i love' is contained inside the longer label 'I Love You'.
      expect(
        GeminiService.snapToVocabulary(r('i love'), vocab).gesture,
        'I Love You',
      );
    });

    test('no match keeps freeform and flags Outside dataset', () {
      final out = GeminiService.snapToVocabulary(
        r('waving both hands', note: 'dynamic sign'),
        vocab,
      );
      expect(out.gesture, 'waving both hands');
      expect(out.note, startsWith('Outside dataset:'));
      expect(out.note, contains('dynamic sign'));
    });

    test('substring hits no longer snap — palm/understand regression', () {
      // 'flat palm facing chest' contains 'Palm' as a substring but the
      // description isn't the sign; matching is token-level now.
      final palm = GeminiService.snapToVocabulary(
        r('flat palm facing chest'),
        const ['Palm', 'Stand', 'Thank You'],
      );
      expect(palm.gesture, 'flat palm facing chest');
      expect(palm.note, startsWith('Outside dataset:'));

      // 'understand' contains 'stand' — raw substring matching used to
      // hijack it to the 'Stand' label.
      final understand = GeminiService.snapToVocabulary(
        r('understand'),
        const ['Palm', 'Stand', 'Thank You'],
      );
      expect(understand.gesture, 'understand');
      expect(understand.note, startsWith('Outside dataset:'));
    });

    test('unrecognised results pass through untouched', () {
      final unknown = GestureResult(
        gesture: 'Unknown',
        english: 'Could not determine',
        confidence: 0,
        note: 'no hand visible',
      );
      final out = GeminiService.snapToVocabulary(unknown, vocab);
      expect(out.note, 'no hand visible');
    });

    test('empty vocabulary is a no-op', () {
      final out = GeminiService.snapToVocabulary(r('anything'), const []);
      expect(out.gesture, 'anything');
      expect(out.note, isEmpty);
    });
  });
}
