import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// MediaPipe-style hand topology: bone connections between the 21
/// landmark points (wrist 0, thumb 1-4, index 5-8, middle 9-12,
/// ring 13-16, pinky 17-20).
const _bones = [
  [0, 1],
  [1, 2],
  [2, 3],
  [3, 4],
  [0, 5],
  [5, 6],
  [6, 7],
  [7, 8],
  [5, 9],
  [9, 10],
  [10, 11],
  [11, 12],
  [9, 13],
  [13, 14],
  [14, 15],
  [15, 16],
  [13, 17],
  [17, 18],
  [18, 19],
  [19, 20],
  [0, 17],
];

/// Draws a hand-sign skeleton from a captured landmark vector
/// (63 floats: 21 points × x,y,z, normalised 0..1). This is the
/// always-offline visual for a sign — it shows the real hand shape the
/// model was trained on, so tiles never render empty.
class HandLandmarkPainter extends CustomPainter {
  HandLandmarkPainter(
    this.landmarks, {
    this.boneColor = const Color(0xE6FFFFFF),
    this.jointColor = const Color(0xFF8BE9D9),
  });

  final List<double> landmarks;
  final Color boneColor;
  final Color jointColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.length < 42) return;
    var pts = List.generate(
      21,
      (i) => Offset(landmarks[i * 3], landmarks[i * 3 + 1]),
    );

    // Fit the landmark bounding box into the canvas with padding.
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final spanX = (maxX - minX).clamp(1e-6, 1.0);
    final spanY = (maxY - minY).clamp(1e-6, 1.0);
    final pad = size.shortestSide * 0.14;
    final scale = ((size.width - pad * 2) / spanX).clamp(0.0, double.infinity);
    final scaleY = (size.height - pad * 2) / spanY;
    final s = scale < scaleY ? scale : scaleY;
    final offX = (size.width - spanX * s) / 2 - minX * s;
    final offY = (size.height - spanY * s) / 2 - minY * s;
    pts = pts.map((p) => Offset(p.dx * s + offX, p.dy * s + offY)).toList();

    final bonePaint = Paint()
      ..color = boneColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final b in _bones) {
      canvas.drawLine(pts[b[0]], pts[b[1]], bonePaint);
    }
    final jointPaint = Paint()..color = jointColor;
    for (final p in pts) {
      canvas.drawCircle(p, 2.6, jointPaint);
    }
  }

  @override
  bool shouldRepaint(HandLandmarkPainter old) =>
      old.landmarks != landmarks ||
      old.boneColor != boneColor ||
      old.jointColor != jointColor;
}

/// Bundled sign illustrations under `assets/signs/`, resolved by gesture
/// label — drop any `<label>.png` (spaces → underscores) into the folder
/// and it is picked up automatically, no code changes needed. Fully
/// offline. Loaded once via [SignAssets.load] at startup.
abstract final class SignAssets {
  static Map<String, String> _byStem = {};

  static Future<void> load() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      _byStem = {
        for (final p in manifest.listAssets())
          if (p.startsWith('assets/signs/'))
            p.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), ''): p,
      };
    } catch (_) {
      _byStem = {};
    }
  }
}

/// Returns the bundled asset path for [label], or null.
/// 'Thank You' -> assets/signs/thank_you.png, 'Letter A' -> letter_a.png.
String? signAssetFor(String label) {
  final k = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return SignAssets._byStem[k];
}

/// Deterministic offline glyph for a sign label — an emoji that
/// communicates the sign's meaning with zero network, zero samples.
/// Covers the seeded vocabulary; unknown labels return null so the
/// caller falls back to the letter/icon tile.
String? signGlyphFor(String label) => _glyphs[label.toLowerCase()];

const _glyphs = <String, String>{
  // Fingerspelling
  'letter a': '🇦', 'letter b': '🇧', 'letter c': '🇨', 'letter d': '🇩',
  'letter e': '🇪', 'letter f': '🇫', 'letter g': '🇬', 'letter h': '🇭',
  'letter i': '🇮', 'letter j': '🇯', 'letter k': '🇰', 'letter l': '🇱',
  'letter m': '🇲', 'letter n': '🇳', 'letter o': '🇴', 'letter p': '🇵',
  'letter q': '🇶', 'letter r': '🇷', 'letter s': '🇸', 'letter t': '🇹',
  'letter u': '🇺', 'letter v': '🇻', 'letter w': '🇼', 'letter x': '🇽',
  'letter y': '🇾', 'letter z': '🇿',
  // Greetings & responses
  'hello': '👋', 'goodbye': '👋', 'thank you': '🙏', 'please': '🙏',
  'welcome': '🤗', 'welcome back': '🤗', 'good morning': '🌅',
  'good afternoon': '🌞', 'good evening': '🌆', 'excuse me': '🙋',
  'see you later': '👋', 'god bless you': '🙏',
  'yes': '👍', 'no': '👎', 'good': '👍', 'bad': '👎', 'sorry': '😔',
  'fine': '😊', 'maybe': '🤷', 'okay': '👌', 'understand': '💡',
  'i do not understand': '❓',
  // Phrases & questions
  'how are you': '🤔', 'i am fine': '😊', 'what is your name': '📛',
  'my name is': '📛', 'i love you': '🤟', 'how much': '💰',
  'i need help': '🆘', 'name': '📛', 'where': '❓', 'what': '❓',
  'who': '❓', 'when': '❓', 'why': '❓', 'how': '❓',
  // Numbers
  'zero': '0️⃣', 'one': '1️⃣', 'two': '2️⃣', 'three': '3️⃣',
  'four': '4️⃣', 'five': '5️⃣', 'six': '6️⃣', 'seven': '7️⃣',
  'eight': '8️⃣', 'nine': '9️⃣', 'ten': '🔟',
  // Time & days
  'today': '📅', 'tomorrow': '⏭️', 'yesterday': '⏮️', 'morning': '🌅',
  'afternoon': '🌞', 'evening': '🌆', 'night': '🌙', 'week': '🗓️',
  'month': '🗓️', 'year': '📆', 'monday': '📅', 'tuesday': '📅',
  'wednesday': '📅', 'thursday': '📅', 'friday': '📅',
  'saturday': '📅', 'sunday': '📅', 'time': '⏰',
  // Daily life
  'help': '🆘', 'water': '💧', 'eat': '🍽️', 'drink': '🥤',
  'sleep': '😴', 'money': '💵', 'home': '🏠', 'work': '💼',
  'toilet': '🚻', 'phone': '📞',
  // Food
  'food': '🍽️', 'sadza': '🌽', 'bread': '🍞', 'rice': '🍚',
  'meat': '🍖', 'chicken': '🍗', 'fish': '🐟', 'fruit': '🍎',
  'vegetables': '🥬', 'sugar': '🍬', 'salt': '🧂', 'breakfast': '🍳',
  'lunch': '🍱', 'supper': '🍽️', 'hungry': '😋', 'thirsty': '🥵',
  // Actions
  'wait': '✋', 'come': '🫴', 'go': '🏃', 'stop': '✋', 'look': '👀',
  'give': '🫲', 'want': '🙋', 'finish': '✅', 'sit': '🪑',
  'stand': '🧍', 'walk': '🚶', 'run': '🏃', 'call': '📞',
  'write': '✍️', 'read': '📖',
  // People & family
  'family': '👨‍👩‍👧‍👦', 'friend': '🤝', 'mother': '👩', 'father': '👨',
  'child': '🧒', 'baby': '👶', 'brother': '👦', 'sister': '👧',
  'grandmother': '👵', 'grandfather': '👴', 'husband': '🤵',
  'wife': '👰', 'uncle': '👨', 'aunt': '👩', 'love': '❤️',
  'you': '👉', 'me': '🙋', 'deaf': '🧏', 'sign language': '🤟',
  'interpreter': '🧏',
  // Emotions
  'happy': '😊', 'sad': '😢', 'angry': '😠', 'cry': '😢',
  'afraid': '😨',
  // Health
  'doctor': '👨‍⚕️', 'nurse': '👩‍⚕️', 'hospital': '🏥', 'clinic': '🏥',
  'ambulance': '🚑', 'medicine': '💊', 'sick': '🤒', 'pain': '😖',
  'fever': '🌡️', 'headache': '🤕', 'cough': '😷', 'pregnant': '🤰',
  // Education
  'school': '🏫', 'teacher': '👩‍🏫', 'student': '🧑‍🎓', 'learn': '📚',
  'book': '📖', 'class': '🏫',
  // Travel & places
  'kombi': '🚐', 'bus': '🚌', 'car': '🚗', 'road': '🛣️',
  'village': '🏘️', 'town': '🏙️', 'city': '🏙️', 'market': '🛒',
  'church': '⛪',
  // Emergency & weather
  'police': '👮', 'fire': '🔥', 'accident': '💥', 'danger': '⚠️',
  'rain': '🌧️', 'sun': '☀️', 'hot': '🔥',
};

/// Convenience widget for the skeleton — fills its parent.
class LandmarkHand extends StatelessWidget {
  const LandmarkHand({
    super.key,
    required this.landmarks,
    this.boneColor = const Color(0xE6FFFFFF),
    this.jointColor = const Color(0xFF8BE9D9),
  });

  final List<double> landmarks;
  final Color boneColor;
  final Color jointColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HandLandmarkPainter(
        landmarks,
        boneColor: boneColor,
        jointColor: jointColor,
      ),
    );
  }
}
