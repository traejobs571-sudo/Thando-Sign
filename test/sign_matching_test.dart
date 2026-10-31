import 'package:flutter_test/flutter_test.dart';

import 'package:thando_sign_app/models/sign_unit.dart';
import 'package:thando_sign_app/services/gemini_service.dart';

void main() {
  group('matchVocabularyLabel', () {
    const vocab = [
      'Hello',
      'Walk',
      'Run',
      'Stop',
      'Stand',
      'Go',
      'Thank You',
      'How Are You',
      'I Love You',
      'Mother',
      'Palm',
      'Letter A',
    ];

    test('exact and case-insensitive matches win immediately', () {
      expect(GeminiService.matchVocabularyLabel('walk', vocab), 'Walk');
      expect(GeminiService.matchVocabularyLabel('thank you', vocab), 'Thank You');
    });

    test('inflected words resolve through stems', () {
      expect(GeminiService.matchVocabularyLabel('walking', vocab), 'Walk');
      expect(GeminiService.matchVocabularyLabel('running', vocab), 'Run');
      expect(GeminiService.matchVocabularyLabel('stopped', vocab), 'Stop');
      expect(GeminiService.matchVocabularyLabel('goes', vocab), 'Go');
    });

    test('spoken synonyms expand to the dataset phrasing', () {
      expect(GeminiService.matchVocabularyLabel('thanks', vocab), 'Thank You');
      expect(GeminiService.matchVocabularyLabel('hi', vocab), 'Hello');
      expect(GeminiService.matchVocabularyLabel('mum', vocab), 'Mother');
    });

    test('multi-word labels match inside longer queries', () {
      expect(
        GeminiService.matchVocabularyLabel('thank you for the help', vocab),
        'Thank You',
      );
      expect(
        GeminiService.matchVocabularyLabel('hey how are you doing', vocab),
        'How Are You',
      );
    });

    test('a query matches into a longer label only on real content', () {
      expect(GeminiService.matchVocabularyLabel('i love', vocab), 'I Love You');
      // A lone function word can never snap to a phrase label.
      expect(GeminiService.matchVocabularyLabel('i', vocab), isNull);
      expect(GeminiService.matchVocabularyLabel('are', vocab), isNull);
    });

    test('substring-only hits never snap', () {
      // 'understand' contains 'stand' as a substring — not a sign match.
      expect(GeminiService.matchVocabularyLabel('understand', vocab), isNull);
      expect(GeminiService.matchVocabularyLabel('walker', vocab), isNull);
    });

    test('anatomical descriptions never snap to Palm', () {
      // The classic regression: descriptions mention the handshape.
      expect(
        GeminiService.matchVocabularyLabel('flat palm facing chest', vocab),
        isNull,
      );
      expect(
        GeminiService.matchVocabularyLabel('open palm raised', vocab),
        isNull,
      );
      // But a genuine "palm" query still finds the label exactly.
      expect(GeminiService.matchVocabularyLabel('palm', vocab), 'Palm');
    });

    test('unmatched words return null', () {
      expect(GeminiService.matchVocabularyLabel('spaceship', vocab), isNull);
      expect(GeminiService.matchVocabularyLabel('', vocab), isNull);
      expect(GeminiService.matchVocabularyLabel('anything', const []), isNull);
    });
  });

  group('snapToVocabulary palm regression', () {
    const vocab = ['Palm', 'Stand', 'Thank You', 'Hello'];

    GestureResult r(String gesture, {String note = ''}) => GestureResult(
      gesture: gesture,
      english: gesture,
      confidence: 0.9,
      note: note,
    );

    test('a freeform palm description stays outside the dataset', () {
      final out = GeminiService.snapToVocabulary(
        r('flat palm facing chest', note: 'open hand shape'),
        vocab,
      );
      expect(out.gesture, 'flat palm facing chest');
      expect(out.note, startsWith('Outside dataset:'));
      expect(out.note, contains('open hand shape'));
    });

    test('"understand" does not snap to Stand', () {
      final out = GeminiService.snapToVocabulary(r('understand'), vocab);
      expect(out.gesture, 'understand');
      expect(out.note, startsWith('Outside dataset:'));
    });

    test('genuine matches still snap', () {
      expect(
        GeminiService.snapToVocabulary(r('thanks'), vocab).gesture,
        'Thank You',
      );
      expect(GeminiService.snapToVocabulary(r('Palm'), vocab).gesture, 'Palm');
    });
  });

  group('SignUnit', () {
    test('fromJson normalises a fingerspell: prefixed gloss', () {
      final u = SignUnit.fromJson({
        'gloss': 'fingerspell:John',
        'original_word': 'john',
        'is_fingerspelled': false,
      });
      expect(u.isFingerspelled, isTrue);
      expect(u.gloss, 'John');
      expect(u.originalWord, 'john');
      expect(u.tileLabel, 'fingerspell:john');
    });

    test('fromJson parses handshape_hint and defaults', () {
      final u = SignUnit.fromJson({
        'gloss': 'HELLO',
        'original_word': 'hello',
        'handshape_hint': 'open hand beside forehead',
      });
      expect(u.handshapeHint, 'open hand beside forehead');
      expect(u.nonManualMarker, 'neutral');
      expect(u.tileLabel, 'HELLO');
    });

    test('copyWith swaps the gloss and keeps the rest', () {
      const u = SignUnit(
        gloss: 'Walked',
        originalWord: 'walked',
        nonManualMarker: 'neutral',
        handshapeHint: 'two flat hands',
      );
      final snapped = u.copyWith(gloss: 'Walk');
      expect(snapped.gloss, 'Walk');
      expect(snapped.originalWord, 'walked');
      expect(snapped.handshapeHint, 'two flat hands');
      expect(snapped.isFingerspelled, u.isFingerspelled);
    });
  });
}
