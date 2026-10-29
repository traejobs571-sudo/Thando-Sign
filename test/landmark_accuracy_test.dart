import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/ml/hand_sign_classifier.dart';

/// Accuracy harness for the on-device recogniser: leave-one-out
/// nearest-neighbour over the bundled landmark samples. Prints a real
/// measured number per run instead of claiming a figure.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('k-NN leave-one-out accuracy over bundled samples', () async {
    final data =
        jsonDecode(
              await rootBundle.loadString('assets/sign_landmarks.json'),
            )
            as Map<String, dynamic>;
    final samples = <String, List<List<double>>>{};
    for (final e in data.entries) {
      samples[e.key] = [
        for (final v in e.value as List)
          (v as List).map((x) => (x as num).toDouble()).toList(),
      ];
    }
    expect(samples, isNotEmpty);

    var correct = 0;
    var total = 0;
    final misses = <String>[];
    for (final entry in samples.entries) {
      for (final v in entry.value) {
        total++;
        // Leave-one-out pool — every sample except this exact vector.
        // Normalized on load, mirroring getGestureSamples' behavior.
        final pool = <String, List<List<double>>>{};
        samples.forEach((label, vectors) {
          pool[label] = [
            for (final other in vectors)
              if (!identical(other, v))
                HandSignClassifier.normalizeLandmarks(other),
          ];
        });
        // 1-NN with no vote floor — pure separability metric.
        final guess = HandSignClassifier.knnLabel(
          HandSignClassifier.normalizeLandmarks(v),
          pool,
          k: 1,
          minScore: 0,
          maxDistance: double.infinity,
        );
        if (guess?.$1 == entry.key) {
          correct++;
        } else {
          misses.add('${entry.key}→${guess?.$1}');
        }
      }
    }

    final accuracy = correct / total;
    // ignore: avoid_print
    print(
      'Landmark k-NN LOO accuracy: '
      '${(accuracy * 100).toStringAsFixed(1)}% '
      '($correct/$total); misses: ${misses.join(', ')}',
    );
    // Sanity floor — a catastrophically broken pipeline lands near 0.
    expect(accuracy, greaterThan(0.5));
  });
}
