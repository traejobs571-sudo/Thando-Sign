import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/controllers/translation_controller.dart';
import 'package:thando_sign_app/ml/hand_sign_classifier.dart';
import 'package:thando_sign_app/services/gemini_service.dart';

void main() {
  GestureResult cloud(String gesture, double conf, {String note = ''}) =>
      GestureResult(
        gesture: gesture,
        english: gesture,
        confidence: conf,
        note: note,
      );

  group('gateResult', () {
    test('low-confidence cloud answers become Could not determine with reason', () {
      final out = TranslationController.gateResult(
        cloud('Waving', 0.30, note: 'hand half out of frame'),
        source: 'gemini',
      );
      expect(out.english, 'Could not determine');
      expect(out.note, contains('hand half out of frame'));
    });

    test('confident answers pass through', () {
      final out = TranslationController.gateResult(
        cloud('Hello', 0.9),
        source: 'gemini',
      );
      expect(out.english, 'Hello');
    });

    test('on-device answers are never gated', () {
      final out = TranslationController.gateResult(
        cloud('Letter A', 0.1),
        source: 'on-device',
      );
      expect(out.english, 'Letter A');
    });
  });

  group('ensembleResult', () {
    const vocab = ['Hello', 'Letter A', 'Father'];

    test('agreement boosts confidence', () {
      final guess = HandGuess(
        handPresent: true,
        presence: 0.9,
        label: 'Hello',
        confidence: 0.8,
      );
      final out = TranslationController.ensembleResult(
        cloud('Hello', 0.7),
        guess,
        vocab,
      );
      expect(out.gesture, 'Hello');
      expect(out.confidence, 0.95);
    });

    test('confident trained label beats a conflicting cloud answer', () {
      final guess = HandGuess(
        handPresent: true,
        presence: 0.9,
        label: 'Letter A',
        confidence: 0.85,
      );
      final out = TranslationController.ensembleResult(
        cloud('Father', 0.7),
        guess,
        vocab,
      );
      expect(out.gesture, 'Letter A');
      expect(out.note, contains('on-device'));
    });

    test('weak guess cannot override the cloud answer', () {
      final guess = HandGuess(
        handPresent: true,
        presence: 0.9,
        label: 'Letter A',
        confidence: 0.5,
      );
      final out = TranslationController.ensembleResult(
        cloud('Father', 0.7),
        guess,
        vocab,
      );
      expect(out.gesture, 'Father');
    });

    test('no guess or unrecognised cloud passes through', () {
      final unknown = GestureResult(
        gesture: 'Unknown',
        english: 'Could not determine',
        confidence: 0,
      );
      expect(
        TranslationController.ensembleResult(unknown, null, vocab).gesture,
        'Unknown',
      );
    });
  });
}
