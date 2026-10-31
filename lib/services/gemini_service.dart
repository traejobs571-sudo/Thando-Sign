import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sign_unit.dart';

class GestureResult {
  final String gesture;
  final String english;
  final double confidence;
  final String note;

  const GestureResult({
    required this.gesture,
    required this.english,
    this.confidence = 0.0,
    this.note = '',
  });
}

class SignDescription {
  final String phrase;
  final List<String> steps;
  final String note;

  /// One entry per meaningful word — a vocabulary label like `'Hello'`,
  /// or `'fingerspell:word'` for names/words without a standard sign.
  final List<String> signs;

  const SignDescription({
    required this.phrase,
    required this.steps,
    this.note = '',
    this.signs = const [],
  });
}

/// Thrown when the Gemini quota/rate limit is hit — caller should back off.
class GeminiQuotaException implements Exception {
  final String message;
  const GeminiQuotaException(this.message);
  @override
  String toString() => message;
}

/// Internal marker — image API rejected the key (401/403), triggering a
/// single retry with the bundled env key.
class _ImageAuthException implements Exception {
  const _ImageAuthException();
}

class GeminiService {
  static const _secureKey = 'gemini_api_key';
  // Newest first — if a model is retired or overloaded, the service falls
  // through to the next one instead of failing. The -latest aliases track
  // whatever is current on Google's side, so future deprecations largely
  // self-heal; the versioned entries are belt-and-braces fallbacks.
  static const _modelNames = [
    'gemini-flash-lite-latest', // fastest alias — tracks current lite model
    'gemini-3.8-flash',
    'gemini-flash-latest',
    'gemini-3.7-flash',
    'gemini-3.6-flash',
    'gemini-3.5-flash',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

  /// Accuracy-first list for the FINAL transcript of a session — the
  /// pro-tier models are slower and costlier, so live-segment ticks keep
  /// [_modelNames]. Unknown names fall through the same unavailable/
  /// not-found handling, so entries here are safe even if unavailable.
  static const _accurateModelNames = [
    'gemini-3-pro',
    'gemini-2.5-pro',
    ..._modelNames,
  ];

  /// The model that answered most recently — tried first on the next
  /// call so steady-state latency is one request, not a serial probe of
  /// the fallback list on every translation.
  String? _workingModel;

  /// Per-attempt ceiling — a hung request must fall through to the next
  /// model instead of stalling the whole pipeline.
  static const _requestTimeout = Duration(seconds: 15);

  /// Shared preamble for every recognition prompt: pins the model to
  /// visible signing evidence only. Without it, captions/subtitles or
  /// other on-screen text get read as "translations" and ambiguous input
  /// gets guessed instead of refused.
  static const _zslPreamble = '''
You are an expert interpreter of Zimbabwe Sign Language (ZSL). ZSL borrows from ASL, BSL and South African Sign Language and includes the standard manual alphabet for fingerspelling.

Rules you must follow:
- Translate ONLY what the signer actually performs: hand shapes, hand and arm movement, body posture and facial expression.
- IGNORE any text, subtitles, captions, logos or watermarks visible in the frames — they are never part of the signed message.
- There is no audio. Base everything on the visible signing alone; never infer words from anything else.
- If the signing is unclear or ambiguous, answer "Could not determine" with low confidence — do not guess.
- Whenever you cannot determine the sign, the NOTE field MUST state the concrete reason (e.g. hand left the frame, poor lighting, motion blur, hand partially hidden, ambiguous between two named signs) so the signer knows what to fix.
''';

  // Image-capable models, newest first — used for gesture illustrations.
  static const _imageModelNames = [
    'gemini-3-pro-image',
    'gemini-3.1-flash-image',
    'gemini-2.5-flash-image',
    'gemini-nano-banana-2.1',
  ];

  final _secure = const FlutterSecureStorage();
  String? _apiKey;

  Future<String?> getApiKey() async {
    if (_apiKey != null && _apiKey!.isNotEmpty) return _apiKey;
    try {
      final saved = await _secure.read(key: _secureKey);
      if (saved != null && saved.isNotEmpty) {
        _apiKey = saved;
        return saved;
      }
    } catch (_) {
      // Secure storage unavailable — fall through to prefs/env.
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString('gemini_api_key');
    if (legacy != null && legacy.isNotEmpty) {
      _apiKey = legacy;
      await setApiKey(legacy); // migrate into secure storage
      return legacy;
    }
    final env = dotenv.env['GEMINI_API_KEY'];
    if (env != null && env.isNotEmpty) {
      _apiKey = env;
      return env;
    }
    return null;
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    try {
      await _secure.write(key: _secureKey, value: _apiKey);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gemini_api_key');
  }

  Future<void> clearApiKey() async {
    _apiKey = null;
    try {
      await _secure.delete(key: _secureKey);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gemini_api_key');
  }

  GenerativeModel _model(
    String apiKey,
    String modelName, {
    int maxOutputTokens = 256,
  }) => GenerativeModel(
    model: modelName,
    apiKey: apiKey,
    generationConfig: GenerationConfig(
      temperature: 0.2,
      topK: 20,
      topP: 0.8,
      maxOutputTokens: maxOutputTokens,
    ),
    safetySettings: [
      SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.none),
      SafetySetting(HarmCategory.harassment, HarmBlockThreshold.none),
      SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.none),
      SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.none),
    ],
  );

  /// True when the API response indicates the key was rejected rather than
  /// the request itself failing — covers auth codes and geo/permission
  /// denials that arrive without a numeric code.
  static bool _isAuthError(String message) {
    final m = message.toLowerCase();
    return m.contains('api key') ||
        m.contains('401') ||
        m.contains('403') ||
        m.contains('permission_denied') ||
        m.contains('permission denied') ||
        m.contains('location is not supported');
  }

  /// Clears a stored key the API rejected so the bundled env key can take
  /// over. Returns false when the env key is missing or identical — meaning
  /// the bundled key itself was rejected.
  Future<bool> _useBundledKey() async {
    final env = dotenv.env['GEMINI_API_KEY'];
    if (env == null || env.isEmpty || env == _apiKey) return false;
    await clearApiKey();
    _apiKey = env;
    return true;
  }

  /// Runs [content] through the model fallback list. When the stored key is
  /// rejected and the bundled env key differs, the stored key is cleared and
  /// the request retried once with it — a stale saved key can no longer
  /// shadow a working bundled one.
  Future<GenerateContentResponse> _generateWithFallback(
    List<Content> content, {
    int maxOutputTokens = 256,
    List<String>? modelNames,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError(
        'Translation service is not configured yet. Please contact your administrator.',
      );
    }
    try {
      return await _generate(
        apiKey,
        content,
        maxOutputTokens: maxOutputTokens,
        modelNames: modelNames,
      );
    } on GenerativeAIException catch (e) {
      if (!_isAuthError(e.message)) rethrow;
      debugPrint('Gemini rejected the API key: ${e.message}');
      // Failover chain: bundled primary env key, then the secondary key —
      // whichever works is persisted so later calls start with it.
      for (final fallback in [
        dotenv.env['GEMINI_API_KEY'],
        dotenv.env['GEMINI_API_KEY_2'],
      ]) {
        if (fallback == null || fallback.isEmpty || fallback == apiKey) {
          continue;
        }
        await clearApiKey();
        _apiKey = fallback;
        try {
          return await _generate(
            fallback,
            content,
            maxOutputTokens: maxOutputTokens,
            modelNames: modelNames,
          );
        } on GenerativeAIException catch (e2) {
          debugPrint('Fallback key also rejected: ${e2.message}');
          if (!_isAuthError(e2.message)) rethrow;
        }
      }
      throw StateError('Translation service is temporarily unavailable.');
    }
  }

  /// The vocabulary block shared by every recognition prompt — the model
  /// must answer with a dataset label whenever one reasonably fits, and
  /// may only freeform when nothing does.
  static String _vocabSection(List<String> vocabulary) => vocabulary.isEmpty
      ? ''
      : '''

Known Zimbabwe Sign Language vocabulary:
${vocabulary.map((v) => '- $v').join('\n')}

You MUST answer with the closest matching label from this vocabulary whenever one reasonably fits — copy the label EXACTLY as written. Only when NO label reasonably fits, return a short freeform description instead.
''';

  /// Snaps a cloud result to the dataset via [matchVocabularyLabel]:
  /// token-level matching, never raw substring — "understand" must not
  /// snap to "Stand" and "flat palm facing chest" must not snap to
  /// "Palm". Unmatched answers stay freeform flagged "Outside dataset:"
  /// so the UI can show it wasn't a ZSL-catalogued match.
  /// Post-validation for the hybrid strict/prefer contract in
  /// [_vocabSection].
  static GestureResult snapToVocabulary(
    GestureResult result,
    List<String> vocabulary,
  ) {
    if (vocabulary.isEmpty || result.english == 'Could not determine') {
      return result;
    }
    final snapped = matchVocabularyLabel(result.gesture, vocabulary);
    if (snapped != null) {
      return GestureResult(
        gesture: snapped,
        english: result.english,
        confidence: result.confidence,
        note: result.note,
      );
    }
    return GestureResult(
      gesture: result.gesture,
      english: result.english,
      confidence: result.confidence,
      note: 'Outside dataset:${result.note.isEmpty ? '' : ' ${result.note}'}',
    );
  }

  /// Matches [query] against [vocabulary] and returns the exact dataset
  /// label, or null. The ladder: (a) normalised whole-string equality;
  /// (b) the label appearing as a consecutive whole-token sequence in
  /// the query (stems applied per token); (c) every query token inside
  /// the label's token set — allowed only when the query carries real
  /// content words, so "i love" snaps to "I Love You" while a bare "i"
  /// can't. A label made purely of anatomical words (Palm, Hand) only
  /// ever matches exactly — descriptions like "flat palm facing chest"
  /// stay freeform.
  static String? matchVocabularyLabel(
    String query,
    List<String> vocabulary,
  ) {
    if (vocabulary.isEmpty) return null;
    final qNorm = query.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');
    if (qNorm.isEmpty) return null;
    for (final label in vocabulary) {
      if (label.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '') ==
          qNorm) {
        return label;
      }
    }

    final qTokens = _signTokens(query);
    final qHasContent = qTokens.any(
      (t) => !_signAnatomical.contains(t) && !_signFunctionWords.contains(t),
    );
    // Synonym-expanded stem variants — "thanks" tries both [thank] and
    // [thank, you]. The unexpanded sequence is always the first combo.
    final qVariants = _signStemVariants(qTokens);

    String? best;
    for (final label in vocabulary) {
      final lTokens = _signTokens(label);
      if (lTokens.isEmpty) continue;
      final pureAnatomical = lTokens.every(_signAnatomical.contains);
      if (pureAnatomical) continue; // exact match already checked above
      final lStems = [for (final t in lTokens) _signStem(t)];
      final labelSet = lStems.toSet();

      var matched = false;
      for (final stems in qVariants) {
        if (lStems.length <= stems.length) {
          for (
            var i = 0;
            i + lStems.length <= stems.length && !matched;
            i++
          ) {
            matched = true;
            for (var j = 0; j < lStems.length; j++) {
              if (stems[i + j] != lStems[j]) {
                matched = false;
                break;
              }
            }
          }
        }
        if (!matched && qHasContent && stems.length > 1) {
          matched = stems.every(labelSet.contains);
        }
        if (matched) break;
      }
      if (matched && (best == null || label.length > best.length)) {
        best = label;
      }
    }
    return best;
  }

  /// Stem sequences for the query with each token independently
  /// expandable through [_signSynonyms] — "thanks" yields [thank] and
  /// [thank, you]. Capped so odd inputs can't explode combinatorially.
  static List<List<String>> _signStemVariants(List<String> tokens) {
    var combos = <List<String>>[[]];
    for (final t in tokens) {
      final options = <List<String>>[
        [_signStem(t)],
        for (final syn in _signSynonyms[t] ?? const <String>[])
          [for (final st in _signTokens(syn)) _signStem(st)],
      ];
      combos = [
        for (final c in combos)
          for (final o in options) [...c, ...o],
      ];
      if (combos.length > 64) return combos.sublist(0, 64);
    }
    return combos;
  }

  /// Lowercase word tokens for sign matching.
  static List<String> _signTokens(String s) => s
      .toLowerCase()
      .split(RegExp("[^a-z0-9']+"))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Conservative English stem for transcript words — strips only the
  /// inflections speech actually produces. A missed stem just costs a
  /// fingerspell tile; a wrong stem could hijack a real sign.
  static String _signStem(String w) {
    if (w.length <= 3) return w;
    if (w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
    if (w.endsWith('ing')) return _undouble(w.substring(0, w.length - 3));
    if (w.endsWith('ed')) return _undouble(w.substring(0, w.length - 2));
    if (w.endsWith('es') &&
        !w.endsWith('ses') &&
        w.substring(0, w.length - 2).length >= 2) {
      return w.substring(0, w.length - 2);
    }
    if (w.endsWith('s') &&
        !w.endsWith('ss') &&
        !w.endsWith('us') &&
        w.length > 4) {
      return w.substring(0, w.length - 1);
    }
    return w;
  }

  /// Drops a doubled final consonant left by -ing/-ed stripping:
  /// running→runn→run, stopped→stopp→stop.
  static String _undouble(String s) {
    if (s.length > 2 && s[s.length - 1] == s[s.length - 2]) {
      return s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Body-part vocabulary — never counts as match evidence, since
  /// gesture descriptions mention hands constantly.
  static const _signAnatomical = {
    'palm',
    'palms',
    'hand',
    'hands',
    'finger',
    'fingers',
    'wrist',
    'arm',
    'arms',
    'fist',
  };

  /// Function words — a query can't match INTO a longer label on these
  /// alone ("i" must never snap to "I Am Fine").
  static const _signFunctionWords = {
    'i',
    'a',
    'an',
    'the',
    'is',
    'am',
    'are',
    'was',
    'my',
    'me',
    'you',
    'your',
    'to',
    'of',
    'in',
    'on',
    'at',
    'it',
    'be',
    'do',
    'for',
    'and',
  };

  /// Spoken-English synonym expansions — keep in sync with the copy in
  /// translate_screen.dart; both sides share the same conservative
  /// stemming/synonym contract by design.
  static const _signSynonyms = <String, List<String>>{
    'thanks': ['thank you'],
    'hi': ['hello'],
    'hey': ['hello'],
    'bye': ['goodbye'],
    'ok': ['okay'],
    'yeah': ['yes'],
    'yep': ['yes'],
    'nope': ['no'],
    'nah': ['no'],
    'mum': ['mother'],
    'mom': ['mother'],
    'mommy': ['mother'],
    'mama': ['mother'],
    'dad': ['father'],
    'daddy': ['father'],
    'papa': ['father'],
    'kid': ['child'],
    'kids': ['child'],
    'granny': ['grandmother'],
    'grandma': ['grandmother'],
    'grandpa': ['grandfather'],
    'hubby': ['husband'],
    'wifey': ['wife'],
    'buddy': ['friend'],
    'pal': ['friend'],
    'bathroom': ['toilet'],
    'restroom': ['toilet'],
    'loo': ['toilet'],
    'ill': ['sick'],
    'unwell': ['sick'],
    'doc': ['doctor'],
    'taxi': ['kombi'],
    'minibus': ['kombi'],
    'shop': ['market'],
    'store': ['market'],
    'sob': ['cry'],
    'scared': ['afraid'],
    'frightened': ['afraid'],
    'mad': ['angry'],
    'stroll': ['walk'],
  };

  /// Recognise a ZSL gesture from a camera frame. Passing [vocabulary]
  /// constrains Gemini to known labels, which keeps results consistent.
  /// [referenceImages] (label → JPEG bytes) upgrades the prompt to
  /// classification — the model picks the closest match against actual
  /// sign illustrations instead of identifying from memory alone.
  Future<GestureResult> identifyGesture(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
    List<String> vocabulary = const [],
    Map<String, Uint8List> referenceImages = const {},
  }) async {
    final refs = referenceImages.entries
        .where((e) => vocabulary.isEmpty || vocabulary.contains(e.key))
        .toList();
    final prompt = refs.isEmpty
        ? '''
$_zslPreamble
Analyse the hand sign in this image. Focus on hand shape, finger positions, palm orientation and location relative to the body. If it is a fingerspelling letter, identify the letter.${_vocabSection(vocabulary)}
'''
        : '''
$_zslPreamble
The images after this prompt are reference illustrations for ${refs.length} candidate ZSL signs — each reference is labelled "REFERENCE: <label>". The LAST image is the live camera frame. Compare the live frame's hand shape, finger positions, palm orientation and body location against the references, then answer with the label of the closest match.${_vocabSection(vocabulary)}
''';

    final content = <Content>[
      Content.multi([
        TextPart(prompt),
        for (final e in refs) ...[
          TextPart('REFERENCE: ${e.key}'),
          DataPart('image/jpeg', e.value),
        ],
        TextPart('LIVE FRAME:'),
        DataPart(mimeType, imageBytes),
      ]),
    ];
    content.first.parts.add(
      TextPart('''
Return your answer in exactly this format (no extra text):
GESTURE: <label — from the vocabulary list if it matches, otherwise a short description>
ENGLISH: <the English meaning>
CONFIDENCE: <0.00-1.00>
NOTE: <one short sentence about the sign or any ambiguity>

If no clear sign is visible, return:
GESTURE: Unknown
ENGLISH: Could not determine
CONFIDENCE: 0.00
NOTE: <why it was unclear>
'''),
    );

    try {
      final response = await _generateWithFallback(content);
      final text = response.text?.trim() ?? '';
      debugPrint('Recognition response: $text');
      return _parseGesture(text);
    } on GenerativeAIException catch (e) {
      _throwTyped(e);
      throw StateError('Translation service error — please try again.');
    } catch (e) {
      if (e is StateError || e is GeminiQuotaException) rethrow;
      throw StateError(
        'Could not reach the translation service. Check your internet connection.',
      );
    }
  }

  /// Recognise a sequence of signs captured as multiple frames in a
  /// single request — fingerspelled words or multi-sign phrases come
  /// back as one English phrase. Much faster than a request per frame.
  Future<GestureResult> identifyGestureSequence(
    List<Uint8List> frames, {
    String mimeType = 'image/jpeg',
    List<String> vocabulary = const [],
  }) async {
    final vocabSection = _vocabSection(vocabulary);

    final prompt =
        '''
$_zslPreamble
The attached ${frames.length} images were captured in order and show a sequence of signs — for example fingerspelled letters forming a word, or several signs forming a short phrase. Identify each sign in order and combine them into the intended English word or phrase.$vocabSection

Return your answer in exactly this format (no extra text):
GESTURE: <each sign identified, in order, separated by spaces>
ENGLISH: <the combined English word or phrase>
CONFIDENCE: <0.00-1.00>
NOTE: <one short sentence about the sequence or any ambiguity>

If no clear signs are visible, return:
GESTURE: Unknown
ENGLISH: Could not determine
CONFIDENCE: 0.00
NOTE: <why it was unclear>
''';

    try {
      final response = await _generateWithFallback([
        Content.multi([
          TextPart(prompt),
          for (final frame in frames) DataPart(mimeType, frame),
        ]),
      ]);
      final text = response.text?.trim() ?? '';
      debugPrint('Sequence response: $text');
      return _parseGesture(text);
    } on GenerativeAIException catch (e) {
      _throwTyped(e);
      throw StateError('Translation service error — please try again.');
    } catch (e) {
      if (e is StateError || e is GeminiQuotaException) rethrow;
      throw StateError(
        'Could not reach the translation service. Check your internet connection.',
      );
    }
  }

  /// Recognise ONE dynamic sign captured as a short burst of consecutive
  /// frames. Unlike [identifyGestureSequence] (one frame per sign), these
  /// frames show the same sign mid-movement, so the prompt steers the
  /// model towards hand path, direction and shape change over time —
  /// the cues that distinguish dynamic ZSL signs.
  Future<GestureResult> identifyDynamicSign(
    List<Uint8List> frames, {
    String mimeType = 'image/jpeg',
    List<String> vocabulary = const [],
  }) async {
    final vocabSection = _vocabSection(vocabulary);

    final prompt =
        '''
$_zslPreamble
The attached ${frames.length} images are consecutive frames (~250ms apart) of ONE sign being performed — they capture the same sign in motion, not a sequence of different signs. Analyse how the hand(s) move: the path and direction of travel, changes in hand shape, palm orientation and repetition. Use the movement to identify the sign.$vocabSection

Return your answer in exactly this format (no extra text):
GESTURE: <label — from the vocabulary list if it matches, otherwise a short description>
ENGLISH: <the English meaning>
CONFIDENCE: <0.00-1.00>
NOTE: <one short sentence about the movement or any ambiguity>

If no clear sign is visible, return:
GESTURE: Unknown
ENGLISH: Could not determine
CONFIDENCE: 0.00
NOTE: <why it was unclear>
''';

    try {
      final response = await _generateWithFallback([
        Content.multi([
          TextPart(prompt),
          for (final frame in frames) DataPart(mimeType, frame),
        ]),
      ]);
      final text = response.text?.trim() ?? '';
      debugPrint('Dynamic-sign response: $text');
      return _parseGesture(text);
    } on GenerativeAIException catch (e) {
      _throwTyped(e);
      throw StateError('Translation service error — please try again.');
    } catch (e) {
      if (e is StateError || e is GeminiQuotaException) rethrow;
      throw StateError(
        'Could not reach the translation service. Check your internet connection.',
      );
    }
  }

  /// Transcribe an entire recorded signing session from sampled frames.
  /// Unlike [identifyGestureSequence] (one frame per sign) or
  /// [identifyDynamicSign] (one sign mid-movement), these frames span a
  /// continuous message from a single signer — the model must segment
  /// the signing itself and return everything that was communicated.
  /// Longer transcripts need the bigger output budget. [preferAccuracy]
  /// is for the end-of-session call — live-segment ticks keep the fast
  /// default models.
  Future<GestureResult> identifySigningSession(
    List<Uint8List> frames, {
    String mimeType = 'image/jpeg',
    List<String> vocabulary = const [],
    bool preferAccuracy = false,
  }) async {
    final vocabSection = _vocabSection(vocabulary);

    final prompt =
        '''
$_zslPreamble
The attached ${frames.length} images are consecutive frames (~300ms apart) of ONE person signing a continuous ZSL message — a full sentence or short conversation, not a single sign. Segment the signing yourself: identify every distinct sign in order (including fingerspelled words and signs repeated across multiple frames), then combine them into the complete English message the person communicated.$vocabSection

Return your answer in exactly this format (no extra text):
GESTURE: <every sign identified, in order, separated by spaces>
ENGLISH: <the complete English translation of the whole message>
CONFIDENCE: <0.00-1.00>
NOTE: <one short sentence about the session or any ambiguity>

If no clear signs are visible, return:
GESTURE: Unknown
ENGLISH: Could not determine
CONFIDENCE: 0.00
NOTE: <why it was unclear>
''';

    try {
      final response = await _generateWithFallback(
        [
          Content.multi([
            TextPart(prompt),
            for (final frame in frames) DataPart(mimeType, frame),
          ]),
        ],
        maxOutputTokens: 1024,
        modelNames: preferAccuracy ? _accurateModelNames : null,
      );
      final text = response.text?.trim() ?? '';
      debugPrint('Session response: $text');
      return _parseGesture(text);
    } on GenerativeAIException catch (e) {
      _throwTyped(e);
      throw StateError('Translation service error — please try again.');
    } catch (e) {
      if (e is StateError || e is GeminiQuotaException) rethrow;
      throw StateError(
        'Could not reach the translation service. Check your internet connection.',
      );
    }
  }

  /// Describe how to sign a phrase in ZSL — used for speech → sign output.
  /// [vocabulary] constrains the SIGN lines to real dataset labels so the
  /// UI can resolve each sign to a stored gesture + illustration.
  /// Structured sign-gloss compilation — the first hop in the
  /// multi-source chain (duck_ai and local derivation follow on
  /// failure). Returns
  /// SignUnits + instruction steps; throws so callers can fall through.
  Future<({List<SignUnit> units, List<String> steps, String note})>
  compileSignGloss(String phrase, List<String> vocabulary) async {
    final vocab = vocabulary.isEmpty
        ? ''
        : '\nKnown sign vocabulary: ${vocabulary.join(', ')}\n'
              'You MUST use a label from this vocabulary whenever one '
              'reasonably fits — copy it EXACTLY as written for the '
              'gloss. Only invent a gloss when NO label reasonably fits.';
    final response = await _generateWithFallback([
      Content.text(
        'You are an expert Zimbabwe Sign Language (ZSL) translator. '
        'Convert this English phrase to sign gloss order — drop filler '
        'words, use Time→Topic→Comment order, mark proper names and '
        'words with no standard sign as is_fingerspelled, and tag '
        'question or negation grammar in non_manual_marker '
        '(eyebrows_raised for yes/no questions, eyebrows_furrowed for '
        'wh-questions, head_shake for negation, else neutral). Give each '
        'sign a short physical handshape_hint (e.g. "flat hand", "fist", '
        '"index pointing", "ILY handshape").\n\n'
        'Phrase: "$phrase"$vocab\n\n'
        'Reply with ONLY JSON, no markdown: {"signs":[{"gloss":"HELLO",'
        '"original_word":"hello","is_fingerspelled":false,'
        '"non_manual_marker":"neutral","handshape_hint":"open hand"}],'
        '"steps":["step"],"note":""}',
      ),
    ]);
    final text = (response.text ?? '')
        .replaceAll(RegExp(r'```(?:json)?'), '')
        .trim();
    final parsed = jsonDecode(text);
    if (parsed is! Map) throw StateError('bad gloss response');
    final units = <SignUnit>[
      for (final s in parsed['signs'] as List? ?? const [])
        if (s is Map<String, dynamic>) SignUnit.fromJson(s),
    ];
    if (units.isEmpty) throw StateError('empty gloss response');
    // Snap loose model glosses onto the exact dataset labels — the tile
    // layer keys its image chain on the label, so a near-miss like
    // "Walked" must come back as "Walk".
    final validated = vocabulary.isEmpty
        ? units
        : [
            for (final u in units)
              if (u.isFingerspelled)
                u
              else
                u.copyWith(
                  gloss:
                      matchVocabularyLabel(u.gloss, vocabulary) ?? u.gloss,
                ),
          ];
    return (
      units: validated,
      steps: <String>[
        for (final s in parsed['steps'] as List? ?? const [])
          if (s is String) s,
      ],
      note: parsed['note'] as String? ?? '',
    );
  }

  Future<SignDescription> describeSign(
    String phrase, {
    List<String> vocabulary = const [],
  }) async {
    final vocabSection = vocabulary.isEmpty
        ? ''
        : '''

Known ZSL vocabulary (prefer these exact labels on SIGN lines):
${vocabulary.map((v) => '- $v').join('\n')}
''';

    final prompt =
        '''
You are an expert teacher of Zimbabwe Sign Language (ZSL).

Explain how to sign this English phrase in ZSL, step by step, so a hearing person can perform it or a deaf person can confirm it:
"$phrase"$vocabSection

Return in exactly this format:
PHRASE: <the phrase>
SIGN: <the ZSL gesture name for a meaningful word — one SIGN line per meaningful word in the phrase, in order>
STEP: <instruction 1>
STEP: <instruction 2>
STEP: <instruction 3>
NOTE: <one sentence of context, e.g. regional ZSL variation or fingerspelling advice>

Rules:
- Emit one SIGN line per content word (skip filler words like "my", "is", "the", "a" unless they carry the meaning). Use the common ZSL gesture name, e.g. SIGN: Hello.
- For proper names or words with no standard ZSL sign, emit SIGN: fingerspell:<word> instead.
- Use 2-6 STEP lines. Keep each step short and physical (hand shape, position, movement).
''';

    try {
      final response = await _generateWithFallback([Content.text(prompt)]);
      return _parseSignDescription(response.text?.trim() ?? '', phrase);
    } on GenerativeAIException catch (e) {
      _throwTyped(e);
      throw StateError('Translation service error — please try again.');
    } catch (e) {
      if (e is StateError || e is GeminiQuotaException) rethrow;
      throw StateError(
        'Could not reach the translation service. Check your internet connection.',
      );
    }
  }

  /// Tries each model in [_modelNames]; moves to the next when a model has
  /// been retired or is not found on the API. The last model that worked
  /// goes first — steady-state calls are a single request, not a serial
  /// probe of the whole list. Passing [modelNames] overrides the order
  /// entirely (accuracy-first calls don't get short-circuited by the
  /// cached fast model).
  Future<GenerateContentResponse> _generate(
    String apiKey,
    List<Content> content, {
    int maxOutputTokens = 256,
    List<String>? modelNames,
  }) async {
    var sawQuota = false;
    final names = modelNames ?? _modelNames;
    final ordered = modelNames == null
        ? <String>[
            ?_workingModel,
            ...names.where((m) => m != _workingModel),
          ]
        : List.of(names);
    for (final name in ordered) {
      try {
        final res = await _model(
          apiKey,
          name,
          maxOutputTokens: maxOutputTokens,
        ).generateContent(content).timeout(_requestTimeout);
        _workingModel = name;
        return res;
      } on TimeoutException {
        // A hung request falls through like an overloaded model — the
        // pipeline stalls forever without the cap.
        debugPrint('Model $name timed out after $_requestTimeout');
        continue;
      } on GenerativeAIException catch (e) {
        final m = e.message.toLowerCase();
        // Key/auth problems won't be fixed by switching models — let the
        // caller decide whether another key is worth trying.
        if (_isAuthError(m)) {
          debugPrint('Gemini rejected the API key: ${e.message}');
          rethrow;
        }
        // Quotas are per-model — another model may still have room.
        // Retired or overloaded models should also fall through.
        if (m.contains('quota') ||
            m.contains('rate limit') ||
            m.contains('429') ||
            m.contains('resource_exhausted') ||
            m.contains('not found') ||
            m.contains('no longer available') ||
            m.contains('not supported') ||
            m.contains('deprecated') ||
            m.contains('high demand') ||
            m.contains('unavailable') ||
            m.contains('overloaded') ||
            m.contains('503')) {
          if (m.contains('quota') ||
              m.contains('rate limit') ||
              m.contains('429') ||
              m.contains('resource_exhausted')) {
            sawQuota = true;
          }
          debugPrint('Model $name unavailable: ${e.message}');
          continue;
        }
        rethrow;
      }
    }
    if (sawQuota) {
      throw GeminiQuotaException('Translation service is busy.');
    }
    throw StateError('Translation service is temporarily unavailable.');
  }

  /// Once an image model reports quota exhaustion (429) the whole
  /// generation pipeline is skipped until this time — otherwise every
  /// missing tile serializes four doomed requests and spins forever.
  DateTime _imageBlockedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Generates a hand-sign illustration for [label] as image bytes.
  /// Runs through the image-capable model chain via raw REST (the Dart
  /// SDK doesn't reliably expose inline-image response parts). Returns
  /// null on total failure — callers show a placeholder, never an error.
  Future<Uint8List?> generateGestureImage(String label, String meaning) async {
    if (DateTime.now().isBefore(_imageBlockedUntil)) return null;
    var apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) return null;
    final cue = _physicalSignCue(label);
    final prompt =
        'Flat vector-style instructional illustration, upper body of a '
        'friendly cartoon person performing the Zimbabwe Sign Language '
        'sign for "$label"${meaning.isNotEmpty ? ' ($meaning)' : ''} on a '
        'plain white background. Clean simple outlines, soft flat colors, '
        'both hands clearly visible with distinct finger positions'
        '${cue.isNotEmpty ? ' — the sign uses $cue' : ''}. '
        'Show that specific handshape; do NOT draw a generic flat open '
        'palm unless that is literally the sign. '
        'A curved arrow shows hand movement direction if the sign moves, '
        'the word "$label" in bold capital letters underneath. No '
        'photorealism, no extra objects.';

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _generateImage(apiKey!, prompt);
      } on _ImageAuthException {
        // Saved key rejected — one retry with the bundled env key.
        debugPrint('Gemini image API rejected the key');
        if (!await _useBundledKey()) return null;
        apiKey = _apiKey;
      }
    }
    return null;
  }

  /// Physical handshape cue for image prompts. Without a concrete shape
  /// the image models default to a cartoon person holding up a flat
  /// palm for every sign, so known labels carry their real shape here.
  /// Fingerspelling letters get a generic letter instruction — the 26
  /// alphabet images are bundled assets anyway.
  static String _physicalSignCue(String label) {
    final l = label.toLowerCase();
    if (l.startsWith('letter ') && l.length == 8) {
      return 'the manual-alphabet fingerspelling handshape for the '
          'letter ${l.substring(7).toUpperCase()}';
    }
    return _signCues[l] ?? '';
  }

  static const _signCues = <String, String>{
    'hello': 'an open hand beside the forehead waving side to side',
    'goodbye': 'an open hand waving side to side',
    'thank you': 'flat fingers touching the chin, then moving forward',
    'please': 'a flat hand circling on the chest',
    'sorry': 'a fist circling on the chest',
    'excuse me': 'fingertips of one hand brushing across the other palm',
    'yes': 'a fist nodding up and down',
    'no': 'index and middle fingers snapping closed onto the thumb',
    'i love you': 'thumb, index and pinky extended in the ILY handshape',
    'good': 'one flat hand touching the lips, moving forward onto the other palm',
    'bad': 'fingers touching the lips, then the hand flips palm-down',
    'help': 'a fist resting on an open palm, both lifting slightly',
    'stop': 'the edge of one hand chopping down onto the other palm',
    'wait': 'both open hands held up with fingers spread, palms forward',
    'come': 'an index finger curling toward the signer',
    'go': 'index fingers pointing forward, moving away',
    'eat': 'fingertips of a closed hand tapping the mouth',
    'drink': 'a thumb tipping toward the mouth like a cup',
    'water': 'a W handshape — index, middle and ring fingers up — tapping the chin',
    'food': 'fingertips of a closed hand tapping the mouth twice',
    'name': 'index and middle fingers of both hands crossing in an X',
    'what': 'an index finger sliding across the open palm',
    'where': 'an index finger wagging side to side',
    'who': 'a thumb tracing the chin under a closed fist',
    'why': 'a Y handshape at the forehead rocking side to side',
    'when': 'an index finger circling around the other raised index finger',
    'how': 'knuckles of both hands pressed together, rolling outward',
    'how are you': 'both hands flipping from palms-down to palms-up',
    'how much': 'loose fists tapping thumbs against index fingers',
    'money': 'fingertips tapping the open palm',
    'deaf': 'an index finger touching the ear, then the mouth',
    'sign language': 'both hands alternating small circles at the chest',
    'walk': 'two flat hands alternating forward steps like walking feet',
    'run': 'L-shaped index and thumb pumping forward',
    'sit': 'index and middle fingers of one hand bent over the other hand',
    'stand': 'index and middle fingers standing on the other palm',
    'mother': 'the thumb of an open hand touching the chin',
    'father': 'the thumb of an open hand touching the forehead',
    'child': 'a flat hand patting downward at child height',
    'baby': 'both arms cradled as if rocking a baby',
    'friend': 'index fingers of both hands hooking together',
    'family': 'both hands in F shapes circling into a joined ring',
    'happy': 'open hands brushing upward on the chest',
    'sad': 'open hands drooping down in front of the face',
    'angry': 'clawed fingers pulling away from the face',
    'love': 'both arms crossed over the chest in a hug',
    'want': 'open clawed hands pulling toward the signer',
    'need': 'an X handshape — bent index finger — pressing downward',
    'understand': 'an index finger flicking upward beside the forehead',
    'my name is': 'index and middle fingers tapping the other flat hand',
    'sick': 'middle fingers of both hands touching forehead and stomach',
    'doctor': 'two fingers tapping the pulse at the wrist',
    'hospital': 'index and middle fingers drawing a cross on the upper arm',
    'school': 'one flat hand clapping down onto the other palm',
    'book': 'both hands opening like a book',
    'work': 'a fist tapping down onto the other fist',
    'home': 'fingertips of a closed hand touching the cheek',
    'phone': 'thumb and pinky extended, held at the ear',
    'call': 'thumb and pinky extended, held at the ear',
    'sleep': 'an open hand drawing down over closing eyes',
    'kombi': 'a flat hand roof shape over a fist, like a minibus taxi',
    'bus': 'a flat hand roof shape over a fist, like a bus',
    'car': 'both fists gripping an invisible steering wheel',
    'rain': 'open fingers wiggling downward like falling rain',
    'sun': 'a circle drawn above the head',
    'hot': 'an open hand fanning the face',
    'cold': 'both fists shaking at the shoulders, shivering',
    'hungry': 'a C handshape sliding down the chest',
    'thirsty': 'an index finger sliding down the throat',
    'sadza': 'fingers of a closed hand rolling as if moulding sadza',
    'toilet': 'a T handshape shaken side to side',
    'time': 'an index finger tapping the wrist where a watch sits',
    'today': 'both Y handshapes dipping down together',
    'tomorrow': 'a thumb at the cheek arcing forward',
    'yesterday': 'a thumb at the cheek arcing backward',
    'morning': 'an arm rising like the sun over the other forearm',
    'night': 'one flat hand arcing down over the other arm',
    'week': 'an index finger sliding across the open palm',
    'welcome': 'both hands open, pulling toward the chest in welcome',
    'god bless you': 'one hand raised, fingers spread, lowering in blessing',
    'see you later': 'an index finger pointing at the eye, then outward',
    'fine': 'a thumbs-up hand tapping the chest',
    'okay': 'thumb and index forming an O, other fingers extended',
    'maybe': 'both open palms seesawing up and down',
    'me': 'an index finger pointing at the chest',
    'you': 'an index finger pointing forward at the other person',
    'cry': 'index fingers tracing tears down the cheeks',
    'afraid': 'open hands flicking outward from the chest',
    'pay': 'fingertips of one hand sliding off the other palm forward',
    'write': 'one hand writing on the other open palm',
    'read': 'eyes following an open palm like a page',
    'look': 'index and middle fingers pointing at the eyes, then outward',
    'give': 'a fist or flat hand extending forward from the body',
    'finish': 'both hands flicking open from closed fists, palms out',
    'learn': 'fingertips picking information off the palm to the forehead',
    'teacher': 'fingertips picking off the palm forward, then hands moving down in the person sign',
    'student': 'fingertips picking off the palm to the forehead, then the person sign',
    'ambulance': 'an open hand rotating like a siren light',
    'police': 'a C handshape touching the chest where a badge sits',
    'fire': 'open fingers wiggling upward like flames',
    'danger': 'a thumb tapping the shoulder then moving forward sharply',
    'accident': 'both fists colliding in front of the chest',
    'prayer': 'both palms pressed together',
    'church': 'a C handshape tapping the back of the other hand',
    'market': 'one flat hand moving under the other in a selling motion',
    'village': 'fingertips of both hands joined in a roof shape',
    'town': 'fingertips of both hands joined in a roof shape',
    'city': 'fingertips of both hands joined in a roof shape, larger',
    'road': 'both flat hands pointing forward side by side like lanes',
    'i do not understand': 'an index finger flicking down beside the forehead, with head shake',
    'i need help': 'a fist resting on an open palm, both lifting',
    'what is your name': 'index and middle fingers crossing in an X with eyebrows furrowed',
  };

  Future<Uint8List?> _generateImage(String apiKey, String prompt) async {
    for (final name in _imageModelNames) {
      try {
        final bytes = await _callImageApi(apiKey, name, prompt);
        if (bytes != null) return bytes;
      } on _ImageAuthException {
        rethrow;
      } catch (e) {
        debugPrint('Image model $name failed: $e');
        final m = '$e'.toLowerCase();
        if (m.contains('quota') || m.contains('429')) {
          final until = DateTime.now().add(
            _retryDelay('$e') ?? const Duration(minutes: 15),
          );
          if (until.isAfter(_imageBlockedUntil)) _imageBlockedUntil = until;
          debugPrint(
            'Image quota exhausted — paused until '
            '$_imageBlockedUntil',
          );
          return null;
        }
        if (e is SocketException || m.contains('failed host lookup')) {
          // Connectivity dropped — remaining models fail identically.
          _imageBlockedUntil = DateTime.now().add(const Duration(seconds: 60));
          return null;
        }
      }
    }
    return null;
  }

  /// Parses the retryDelay hint from a Gemini quota error body
  /// (e.g. `"retryDelay": "70434s"`), clamped to 1–60 minutes.
  static Duration? _retryDelay(String body) {
    final m = RegExp('"retryDelay"\\s*:\\s*"(\\d+)s"').firstMatch(body);
    if (m == null) return null;
    final s = int.tryParse(m.group(1)!) ?? 0;
    if (s <= 0) return null;
    return Duration(seconds: s.clamp(60, 3600));
  }

  Future<Uint8List?> _callImageApi(
    String apiKey,
    String model,
    String prompt,
  ) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$model:generateContent?key=$apiKey',
    );
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {
            'responseModalities': ['IMAGE'],
          },
        }),
      );
      final res = await req.close().timeout(
        const Duration(seconds: 60),
      );
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const _ImageAuthException();
      }
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}: $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final candidates = json['candidates'] as List? ?? const [];
      for (final c in candidates) {
        final parts = (c['content']?['parts'] as List?) ?? const [];
        for (final p in parts) {
          final inline = p['inlineData'] ?? p['inline_data'];
          if (inline is Map && inline['data'] is String) {
            return base64Decode(inline['data'] as String);
          }
        }
      }
      return null; // model answered with text only
    } finally {
      client.close();
    }
  }

  // --------------------------------------------------------- Files API (video)

  /// Transcribes a recorded signing session by uploading the real .mp4 to
  /// the Gemini Files API — video carries actual motion, which is
  /// dramatically more accurate for continuous ZSL than sampled stills.
  /// Returns null on any upload/poll/generation failure so the caller can
  /// fall back to the sampled-frames path.
  Future<GestureResult?> identifySigningSessionFromVideo(
    File video, {
    List<String> vocabulary = const [],
  }) async {
    var apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) return null;

    String? fileName;
    try {
      final uploaded = await _uploadVideoFile(apiKey, video);
      if (uploaded == null) return null;
      fileName = uploaded.$1;
      apiKey = _apiKey ?? apiKey; // auth retry may have swapped keys
      if (!await _awaitFileActive(apiKey, fileName)) return null;
      final text = await _generateVideoTranscript(
        apiKey,
        uploaded.$2,
        vocabulary,
      );
      if (text == null) return null;
      debugPrint('Video session response: $text');
      return _parseGesture(text);
    } catch (e) {
      debugPrint('Video session translation failed: $e');
      return null;
    } finally {
      // Files expire after 48h anyway — deleting now just frees the
      // project's storage quota sooner.
      if (fileName != null) unawaited(_deleteGeminiFile(fileName));
    }
  }

  /// Resumable-uploads [video] via `upload/v1beta/files`. Returns
  /// (file name, file uri), or null on failure. Retries once with the
  /// bundled env key when the stored key is rejected.
  Future<(String, String)?> _uploadVideoFile(
    String apiKey,
    File video,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final key = attempt == 0 ? apiKey : _apiKey;
      if (key == null || key.isEmpty) return null;
      try {
        final bytes = await video.readAsBytes();
        final client = HttpClient();
        try {
          final start = await client.postUrl(
            Uri.parse(
              'https://generativelanguage.googleapis.com/upload/v1beta/files'
              '?key=$key',
            ),
          );
          start.headers
            ..set('X-Goog-Upload-Protocol', 'resumable')
            ..set('X-Goog-Upload-Command', 'start')
            ..set(
              'X-Goog-Upload-Header-Content-Length',
              '${bytes.length}',
            )
            ..set('X-Goog-Upload-Header-Content-Type', 'video/mp4');
          start.headers.contentType = ContentType.json;
          start.write(
            jsonEncode({
              'file': {'display_name': 'thando-signing-session'},
            }),
          );
          final startRes = await start.close().timeout(
            const Duration(seconds: 20),
          );
          if (startRes.statusCode == 401 || startRes.statusCode == 403) {
            throw const _ImageAuthException();
          }
          final uploadUrl = startRes.headers.value('x-goog-upload-url');
          await utf8.decodeStream(startRes);
          if (startRes.statusCode != 200 || uploadUrl == null) {
            debugPrint('File upload start failed: ${startRes.statusCode}');
            return null;
          }

          final up = await client.postUrl(Uri.parse(uploadUrl));
          up.headers
            ..set('Content-Length', '${bytes.length}')
            ..set('X-Goog-Upload-Offset', '0')
            ..set('X-Goog-Upload-Command', 'upload, finalize');
          up.add(bytes);
          final upRes = await up.close().timeout(
            const Duration(seconds: 120),
          );
          final body = await utf8.decodeStream(upRes);
          if (upRes.statusCode == 401 || upRes.statusCode == 403) {
            throw const _ImageAuthException();
          }
          if (upRes.statusCode != 200) {
            debugPrint('File upload failed: ${upRes.statusCode} $body');
            return null;
          }
          final file =
              (jsonDecode(body) as Map<String, dynamic>)['file']
                  as Map<String, dynamic>?;
          final name = file?['name'] as String?;
          final uri = file?['uri'] as String?;
          if (name == null || uri == null) return null;
          return (name, uri);
        } finally {
          client.close();
        }
      } on _ImageAuthException {
        debugPrint('Gemini Files API rejected the key');
        if (!await _useBundledKey()) return null;
      } catch (e) {
        debugPrint('File upload error: $e');
        return null;
      }
    }
    return null;
  }

  /// Polls `GET /v1beta/{name}` until the file reaches ACTIVE — uploads
  /// are processed asynchronously, and generateContent refuses files
  /// still in PROCESSING.
  Future<bool> _awaitFileActive(String apiKey, String name) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final client = HttpClient();
        try {
          final req = await client.getUrl(
            Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/$name'
              '?key=$apiKey',
            ),
          );
          final res = await req.close().timeout(
            const Duration(seconds: 15),
          );
          final body = await utf8.decodeStream(res);
          if (res.statusCode != 200) return false;
          final state =
              (jsonDecode(body) as Map<String, dynamic>)['state'] as String?;
          if (state == 'ACTIVE') return true;
          if (state == 'FAILED') return false;
        } finally {
          client.close();
        }
      } catch (_) {
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    return false;
  }

  /// `generateContent` with a `file_data` part through raw REST — the
  /// SDK's Content parts have no file reference type in this version.
  /// Walks [_modelNames] with the same quota/not-found fall-through and
  /// bundled-key retry as [_generateWithFallback].
  Future<String?> _generateVideoTranscript(
    String apiKey,
    String fileUri,
    List<String> vocabulary,
  ) async {
    final vocabSection = _vocabSection(vocabulary);
    final prompt =
        '''
$_zslPreamble
The attached video shows ONE person signing a continuous ZSL message — a full sentence or short conversation, not a single sign. Segment the signing yourself: identify every distinct sign in order (including fingerspelled words and signs repeated across the video), then combine them into the complete English message the person communicated.$vocabSection

Return your answer in exactly this format (no extra text):
GESTURE: <every sign identified, in order, separated by spaces>
ENGLISH: <the complete English translation of the whole message>
CONFIDENCE: <0.00-1.00>
NOTE: <one short sentence about the session or any ambiguity>

If no clear signs are visible, return:
GESTURE: Unknown
ENGLISH: Could not determine
CONFIDENCE: 0.00
NOTE: <why it was unclear>
''';

    var sawQuota = false;
    // Final session transcript — accuracy-first order; the pro entries
    // fall through to the flash list automatically if unavailable.
    for (final name in _accurateModelNames) {
      final res = await _restGenerate(apiKey, name, {
        'contents': [
          {
            'parts': [
              {'text': prompt},
              {
                'file_data': {'mime_type': 'video/mp4', 'file_uri': fileUri},
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.2,
          'topK': 20,
          'topP': 0.8,
          'maxOutputTokens': 1024,
        },
      });
      if (res == _restAuthFailed) {
        debugPrint('Gemini rejected the API key for video transcript');
        if (!await _useBundledKey()) return null;
        apiKey = _apiKey!;
        continue;
      }
      if (res == null) {
        debugPrint('Video model $name failed — trying next');
        continue;
      }
      if (res == _restQuotaHit) {
        sawQuota = true;
        continue;
      }
      _workingModel = name;
      return res;
    }
    if (sawQuota) {
      throw const GeminiQuotaException('Translation service is busy.');
    }
    return null;
  }

  static const _restAuthFailed = '\u0000auth';
  static const _restQuotaHit = '\u0000quota';

  /// Minimal REST generateContent for payloads the SDK can't express
  /// (file_data parts). Returns response text, or a sentinel for
  /// auth/quota failures, or null for anything else.
  Future<String?> _restGenerate(
    String apiKey,
    String model,
    Map<String, Object?> body,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/'
          '$model:generateContent?key=$apiKey',
        ),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 90));
      final text = await utf8.decodeStream(res);
      if (res.statusCode == 401 || res.statusCode == 403) {
        return _restAuthFailed;
      }
      if (res.statusCode == 429) return _restQuotaHit;
      if (res.statusCode != 200) {
        debugPrint('$model generateContent ${res.statusCode}: $text');
        return null;
      }
      final json = jsonDecode(text) as Map<String, dynamic>;
      final candidates = json['candidates'] as List? ?? const [];
      final out = StringBuffer();
      for (final c in candidates) {
        final parts = (c['content']?['parts'] as List?) ?? const [];
        for (final p in parts) {
          if (p['text'] is String) out.write(p['text']);
        }
      }
      return out.toString().trim();
    } on TimeoutException {
      return null;
    } catch (e) {
      debugPrint('$model REST generateContent error: $e');
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _deleteGeminiFile(String name) async {
    final apiKey = _apiKey;
    if (apiKey == null || apiKey.isEmpty) return;
    try {
      final client = HttpClient();
      try {
        final req = await client.deleteUrl(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/$name'
            '?key=$apiKey',
          ),
        );
        await req.close().timeout(const Duration(seconds: 10));
      } finally {
        client.close();
      }
    } catch (_) {}
  }

  void _throwTyped(GenerativeAIException e) {
    final m = e.message.toLowerCase();
    if (m.contains('quota') ||
        m.contains('rate limit') ||
        m.contains('429') ||
        m.contains('resource_exhausted')) {
      throw GeminiQuotaException('Translation service is busy.');
    }
    if (m.contains('api key') || m.contains('401') || m.contains('403')) {
      throw StateError('Translation service is temporarily unavailable.');
    }
  }

  GestureResult _parseGesture(String text) {
    String? getValue(String label) {
      final match = RegExp(
        '^$label:\\s*(.*)\$',
        multiLine: true,
        caseSensitive: false,
      ).firstMatch(text);
      return match?.group(1)?.trim();
    }

    return GestureResult(
      gesture: getValue('GESTURE') ?? 'Unknown',
      english: getValue('ENGLISH') ?? 'Could not determine',
      confidence: double.tryParse(getValue('CONFIDENCE') ?? '0.0') ?? 0.0,
      note: getValue('NOTE') ?? '',
    );
  }

  SignDescription _parseSignDescription(String text, String fallback) {
    final steps = RegExp(
      r'^STEP:\s*(.*)$',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(text).map((m) => m.group(1)!.trim()).toList();
    final signs = RegExp(
      r'^SIGN:\s*(.*)$',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(text).map((m) => m.group(1)!.trim()).toList();
    final note =
        RegExp(
          r'^NOTE:\s*(.*)$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(text)?.group(1)?.trim() ??
        '';
    return SignDescription(
      phrase: fallback,
      steps: steps.isEmpty
          ? ['No instructions returned — try a simpler phrase.']
          : steps,
      note: note,
      signs: signs,
    );
  }
}
