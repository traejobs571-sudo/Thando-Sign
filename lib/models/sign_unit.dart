/// A single sign-language unit produced by the multi-LLM gloss
/// compiler — one meaningful word mapped to its sign gloss plus
/// grammar metadata.
///
/// [cardImageAsset] and [avatarAnimationClip] are future hooks: the
/// tile UI currently resolves images through the existing image chain
/// (bundled → generated → web), and avatar clips can drop in later
/// without changing consumers.
class SignUnit {
  final String gloss;
  final String originalWord;
  final bool isFingerspelled;
  final String nonManualMarker; // e.g. eyebrows_raised, head_shake, neutral

  /// Short physical description of the hand shape from the gloss
  /// compiler — e.g. "flat hand", "fist", "index pointing". Data-only
  /// for now; the image pipeline uses its own cue map.
  final String handshapeHint;

  final String cardImageAsset;
  final String avatarAnimationClip;

  const SignUnit({
    required this.gloss,
    required this.originalWord,
    this.isFingerspelled = false,
    this.nonManualMarker = 'neutral',
    this.handshapeHint = '',
    this.cardImageAsset = '',
    this.avatarAnimationClip = '',
  });

  /// Tile label the existing UI consumes — 'fingerspell:word' for OOV
  /// words so the established fingerspell rules keep applying.
  String get tileLabel =>
      isFingerspelled ? 'fingerspell:$originalWord' : gloss;

  SignUnit copyWith({
    String? gloss,
    String? originalWord,
    bool? isFingerspelled,
    String? nonManualMarker,
    String? handshapeHint,
    String? cardImageAsset,
    String? avatarAnimationClip,
  }) {
    return SignUnit(
      gloss: gloss ?? this.gloss,
      originalWord: originalWord ?? this.originalWord,
      isFingerspelled: isFingerspelled ?? this.isFingerspelled,
      nonManualMarker: nonManualMarker ?? this.nonManualMarker,
      handshapeHint: handshapeHint ?? this.handshapeHint,
      cardImageAsset: cardImageAsset ?? this.cardImageAsset,
      avatarAnimationClip: avatarAnimationClip ?? this.avatarAnimationClip,
    );
  }

  factory SignUnit.fromJson(Map<String, dynamic> json) {
    var gloss = (json['gloss'] as String? ?? '').trim();
    var original = (json['original_word'] as String? ?? '').trim();
    var fingerspelled = json['is_fingerspelled'] as bool? ?? false;
    // Models sometimes emit the fingerspell marker inside the gloss
    // itself ('fingerspell:John') instead of setting the flag — fold
    // both spellings into the same representation.
    for (final field in [gloss, original]) {
      if (field.toLowerCase().startsWith('fingerspell:')) {
        fingerspelled = true;
      }
    }
    if (fingerspelled) {
      String strip(String s) => s.toLowerCase().startsWith('fingerspell:')
          ? s.substring(12).trim()
          : s;
      gloss = strip(gloss);
      original = strip(original);
    }
    if (gloss.isEmpty) gloss = original;
    if (original.isEmpty) original = gloss;
    return SignUnit(
      gloss: gloss,
      originalWord: original,
      isFingerspelled: fingerspelled,
      nonManualMarker: json['non_manual_marker'] as String? ?? 'neutral',
      handshapeHint: json['handshape_hint'] as String? ?? '',
      cardImageAsset: json['card_asset'] as String? ?? '',
      avatarAnimationClip: json['avatar_clip'] as String? ?? '',
    );
  }
}
