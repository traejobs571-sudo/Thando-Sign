import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Internet-knowledge accuracy layer via SerpAPI through the
/// `serp-proxy` Supabase Edge Function — the API key never ships in the
/// app. `duck_ai` answers text questions; `google_images` finds real
/// sign illustrations. Every method degrades silently to null when the
/// backend, network or key is unavailable.
class DuckAiService {
  DuckAiService({required this.supabase});

  final SupabaseService supabase;

  Future<Map<String, dynamic>?> _search(
    String query,
    String engine,
  ) async {
    if (!supabase.enabled) return null;
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'serp-proxy',
        body: {'q': query, 'engine': engine},
      );
      final data = res.data;
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// Free-text answer from the duck_ai engine, or null.
  Future<String?> ask(String question) async {
    final data = await _search(question, 'duck_ai');
    if (data == null) return null;
    for (final key in ['response', 'answer', 'text']) {
      final t = data[key];
      if (t is String && t.trim().isNotEmpty) return t.trim();
    }
    return null;
  }

  /// Fixes likely speech-recognition errors (names, accents) — returns
  /// the corrected phrase, or null when nothing needs fixing.
  Future<String?> correctHeard(String heard) async {
    // Hard cap — correction must never stall the actual translation.
    final answer = await ask(
      'This phrase came from speech recognition of a Zimbabwean English '
      'speaker and may contain misheard words, names or broken grammar '
      '(e.g. "it had a" instead of "at a", "Kendall" instead of '
      '"Thando"). If anything looks misheard, reply with ONLY the '
      'corrected phrase preserving the speaker\'s intent. '
      'If it looks correct, reply with ONLY the word OK.\n\n"$heard"',
    ).timeout(const Duration(seconds: 4), onTimeout: () => null);
    if (answer == null) return null;
    final clean = answer
        .replaceAll('"', '')
        .replaceAll(RegExp(r'^.*?:\s*'), '')
        .trim();
    if (clean.isEmpty ||
        clean.toUpperCase() == 'OK' ||
        clean.toLowerCase() == heard.trim().toLowerCase()) {
      return null;
    }
    return clean;
  }

  /// Sign words for a phrase per the internet AI — a second opinion to
  /// merge with Gemini's SIGN lines so every word maps to a real sign.
  /// When [vocabulary] is provided the prompt names the dataset labels
  /// and results are filtered to labels that match it (or explicit
  /// fingerspell entries). Pure body-part answers like "Palm" are
  /// always dropped — they describe the handshape, not the sign.
  /// Returns parsed labels (may include 'fingerspell:x' entries), or
  /// null when unavailable/slow.
  Future<List<String>?> signsForPhrase(
    String phrase, {
    List<String> vocabulary = const [],
  }) async {
    final vocab = vocabulary.isEmpty
        ? ''
        : '\nPrefer these exact sign labels when one fits: '
              '${vocabulary.join(', ')}';
    final answer = await ask(
      'List the sign language signs used to sign this phrase, in order. '
      'Reply with ONLY a comma-separated list — vocabulary words as '
      'plain words, and fingerspell:name for names or words with no '
      'standard sign. Example: Hello, My Name, fingerspell:John'
      '$vocab\n\n"$phrase"',
    ).timeout(const Duration(seconds: 8), onTimeout: () => null);
    if (answer == null) return null;
    final signs = _filterSigns(answer.split(','), phrase);
    return signs.isEmpty ? null : signs;
  }

  /// Full sign description for a phrase via duck_ai — the fallback that
  /// keeps Speech→Sign useful when the Gemini gloss compiler is down or
  /// quota-blocked: one search returns both the sign list and the
  /// instruction steps, so fallback cards show real instructions
  /// instead of a "needs the cloud" placeholder. Returns null when
  /// unavailable/slow or the answer has no signs.
  Future<({List<String> signs, List<String> steps, String note})?>
      describeSigns(
    String phrase, {
    List<String> vocabulary = const [],
  }) async {
    final vocab = vocabulary.isEmpty
        ? ''
        : '\nPrefer these exact sign labels when one fits: '
              '${vocabulary.join(', ')}';
    final answer = await ask(
      'You are helping a hearing person sign this English phrase in '
      'Zimbabwe Sign Language. Reply in EXACTLY this format, no extra '
      'text:\n'
      'SIGNS: <comma-separated sign labels in order — plain words, or '
      'fingerspell:name for names/words with no standard sign>\n'
      'STEPS:\n'
      '<2-5 short instruction steps, one per line — hand shape, '
      'position, movement>\n'
      'NOTE: <one short sentence of context, or blank>$vocab\n\n'
      '"$phrase"',
    ).timeout(const Duration(seconds: 8), onTimeout: () => null);
    if (answer == null) return null;
    final parsed = parseDescribeAnswer(answer);
    if (parsed == null) return null;
    final signs = _filterSigns(parsed.signs, phrase);
    if (signs.isEmpty) return null;
    return (signs: signs, steps: parsed.steps, note: parsed.note);
  }

  /// Parses the SIGNS:/STEPS:/NOTE: answer — tolerant of numbered and
  /// bulleted step lines. Split out so unit tests can drive it without
  /// a backend. Pure body-part items on SIGNS: are filtered by the
  /// caller (needs the phrase for context).
  static ({List<String> signs, List<String> steps, String note})?
      parseDescribeAnswer(String answer) {
    final signs = <String>[];
    final steps = <String>[];
    var note = '';
    var inSteps = false;
    for (final raw in answer.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();
      if (upper.startsWith('SIGNS:')) {
        signs.addAll(
          line
              .substring(6)
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty),
        );
        inSteps = false;
      } else if (upper.startsWith('STEPS:')) {
        inSteps = true;
        final inline = line.substring(6).trim();
        if (inline.isNotEmpty) steps.add(inline);
      } else if (upper.startsWith('NOTE:')) {
        note = line.substring(5).trim();
        inSteps = false;
      } else if (inSteps) {
        // '1. text', '- text', 'STEP: text' or a bare instruction line.
        final numbered = RegExp(r'^(?:\d+[.)]|[-*•])\s*(.*)$').firstMatch(line);
        steps.add((numbered?.group(1) ?? line).trim());
      }
    }
    if (signs.isEmpty) return null;
    return (signs: signs, steps: steps, note: note);
  }

  /// Drops hallucinated anatomy ("palm", "hand" alone describe the
  /// handshape, not a sign) unless the speaker actually said the word.
  List<String> _filterSigns(Iterable<String> items, String phrase) {
    final phraseTokens = phrase
        .toLowerCase()
        .split(RegExp('[^a-z0-9]+'))
        .toSet();
    final signs = <String>[];
    for (final part in items) {
      final s = part.trim();
      if (s.isEmpty) continue;
      final norm = s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');
      if (_anatomicalWords.contains(norm) && !phraseTokens.contains(norm)) {
        continue;
      }
      signs.add(s);
    }
    return signs;
  }

  static const _anatomicalWords = {
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

  /// Cached per-label — tiles rebuild often and must not re-search on
  /// every paint.
  final Map<String, Future<String?>> _imageUrlCache = {};

  /// Web-image URL for a label, memoised — repeated tiles hit the
  /// cache, never the network twice.
  Future<String?> signImageUrl(String label) => _imageUrlCache.putIfAbsent(
    label.toLowerCase(),
    () => searchSignImage(label),
  );

  /// First usable web image URL for a sign illustration, or null.
  /// Excludes "palm" from the query for non-palm signs — otherwise
  /// stock photos of open palms dominate the results.
  Future<String?> searchSignImage(String label) async {
    final excludePalm = label.toLowerCase().contains('palm')
        ? ''
        : ' -palm';
    final data = await _search(
      'Zimbabwe sign language "$label" sign illustration$excludePalm',
      'google_images',
    );
    final results = data?['images_results'];
    if (results is List) {
      for (final r in results) {
        final u = r is Map ? r['original'] : null;
        if (u is String && u.startsWith('http')) return u;
      }
    }
    return null;
  }
}
