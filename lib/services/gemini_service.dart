import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError(
        'Translation service is not configured yet. Please contact your administrator.',
      );
    }
    try {
      return await _generate(apiKey, content, maxOutputTokens: maxOutputTokens);
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

  /// Snaps a cloud result to the dataset: exact (case-insensitive) label
  /// → normalised casing; a label contained in the answer or vice versa
  /// → snapped to the longest match; otherwise kept as freeform and
  /// flagged "Outside dataset:" so the UI can show it wasn't a
  /// ZSL-catalogued match. Post-validation for the hybrid strict/prefer
  /// contract in [_vocabSection].
  static GestureResult snapToVocabulary(
    GestureResult result,
    List<String> vocabulary,
  ) {
    if (vocabulary.isEmpty || result.english == 'Could not determine') {
      return result;
    }
    final want = result.gesture.trim().toLowerCase();
    String? exact;
    String? contained;
    for (final label in vocabulary) {
      final l = label.toLowerCase();
      if (l == want) {
        exact = label;
        break;
      }
      if (want.contains(l) || l.contains(want)) {
        if (contained == null || label.length > contained.length) {
          contained = label;
        }
      }
    }
    final snapped = exact ?? contained;
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
  /// Longer transcripts need the bigger output budget.
  Future<GestureResult> identifySigningSession(
    List<Uint8List> frames, {
    String mimeType = 'image/jpeg',
    List<String> vocabulary = const [],
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
  /// probe of the whole list.
  Future<GenerateContentResponse> _generate(
    String apiKey,
    List<Content> content, {
    int maxOutputTokens = 256,
  }) async {
    var sawQuota = false;
    final ordered = <String>[
      ?_workingModel,
      ..._modelNames.where((m) => m != _workingModel),
    ];
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
    final prompt =
        'Flat vector-style instructional illustration, upper body of a '
        'friendly cartoon person performing the Zimbabwe Sign Language '
        'sign for "$label"${meaning.isNotEmpty ? ' ($meaning)' : ''} on a '
        'plain white background. Clean simple outlines, soft flat colors, '
        'both hands clearly visible with distinct finger positions, a '
        'curved arrow showing hand movement direction if the sign moves, '
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
    final ordered = <String>[
      ?_workingModel,
      ..._modelNames.where((m) => m != _workingModel),
    ];
    for (final name in ordered) {
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
