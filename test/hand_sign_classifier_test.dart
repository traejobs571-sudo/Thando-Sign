import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:thando_sign_app/ml/hand_sign_classifier.dart';

void main() {
  group('normalizeLandmarks', () {
    test('recenters landmarks on the wrist', () {
      final lm = List<double>.generate(63, (i) => i.toDouble());
      final out = HandSignClassifier.normalizeLandmarks(lm);

      // Wrist (indices 0-2) becomes the origin.
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
    });

    test('scales by wrist-to-middle-knuckle distance', () {
      final lm = List<double>.generate(63, (i) => i.toDouble());
      final out = HandSignClassifier.normalizeLandmarks(lm);

      // wrist = (0,1,2), middle knuckle (index 9) = (27,28,29)
      // diff = (27,27,27) → scale = 27√3
      final scale = 27 * math.sqrt(3);
      expect(out[3], closeTo(3 / scale, 1e-9));
      expect(out[27], closeTo(27 / scale, 1e-9));
    });

    test('is invariant to translation', () {
      final base = List<double>.generate(63, (i) => i.toDouble());
      final shifted = List<double>.generate(
        63,
        (i) => base[i] + (i % 3 == 0 ? 10 : (i % 3 == 1 ? -5 : 3)),
      );
      final a = HandSignClassifier.normalizeLandmarks(base);
      final b = HandSignClassifier.normalizeLandmarks(shifted);
      for (var i = 0; i < a.length; i++) {
        expect(a[i], closeTo(b[i], 1e-9));
      }
    });
  });

  group('knnLabel', () {
    List<double> vec(double fill) => List<double>.filled(63, fill);

    test('returns null for empty samples', () {
      expect(HandSignClassifier.knnLabel(vec(0), {}), isNull);
    });

    test('returns null when all samples exceed maxDistance', () {
      final samples = {
        'Hello': [vec(10)],
      };
      expect(
        HandSignClassifier.knnLabel(vec(0), samples, maxDistance: 0.9),
        isNull,
      );
    });

    test('majority label wins within k nearest', () {
      // 3 close 'Hello' + 2 slightly farther 'Yes' → Hello with 3/5 = 0.6
      final samples = {
        'Hello': [vec(0.01), vec(0.02), vec(0.03)],
        'Yes': [vec(0.05), vec(0.06)],
      };
      final result = HandSignClassifier.knnLabel(vec(0), samples);
      expect(result, isNotNull);
      expect(result!.$1, 'Hello');
      expect(result.$2, closeTo(0.6, 1e-9));
    });

    test('returns null when the vote is too weak', () {
      // 2 'Hello', 2 'Yes', 1 'Other' → best is 2/5 = 0.4 < 0.6
      final samples = {
        'Hello': [vec(0.01), vec(0.02)],
        'Yes': [vec(0.03), vec(0.04)],
        'Other': [vec(0.05)],
      };
      expect(HandSignClassifier.knnLabel(vec(0), samples), isNull);
    });
  });
}
