import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/services/duck_ai_service.dart';

void main() {
  group('parseDescribeAnswer', () {
    test('parses SIGNS/STEPS/NOTE layout', () {
      final out = DuckAiService.parseDescribeAnswer(
        'SIGNS: Hello, How Are You, fingerspell:Thando\n'
        'STEPS:\n'
        'Open hand beside forehead, wave side to side\n'
        'Flip both hands palms-down to palms-up\n'
        'NOTE: Fingerspell the name',
      );
      expect(out, isNotNull);
      expect(out!.signs, ['Hello', 'How Are You', 'fingerspell:Thando']);
      expect(out.steps.length, 2);
      expect(out.note, 'Fingerspell the name');
    });

    test('tolerates numbered and bulleted step lines', () {
      final out = DuckAiService.parseDescribeAnswer(
        'SIGNS: Thank You\n'
        'STEPS:\n'
        '1. Flat fingers touch the chin\n'
        '- Move the hand forward\n'
        'NOTE:',
      );
      expect(out!.steps, [
        'Flat fingers touch the chin',
        'Move the hand forward',
      ]);
    });

    test('empty or missing SIGNS returns null', () {
      expect(DuckAiService.parseDescribeAnswer('no idea'), isNull);
      expect(DuckAiService.parseDescribeAnswer('SIGNS:\nSTEPS:\nx'), isNull);
    });
  });
}
