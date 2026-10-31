import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/translation_controller.dart';
import '../../models/gesture_item.dart';
import '../../models/translation_record.dart';
import '../../route_observer.dart';
import '../../services/auth_service.dart';
import '../../services/connectivity_service.dart';
import '../../models/sign_unit.dart';
import '../../services/db_service.dart';
import '../../services/duck_ai_service.dart';
import '../../services/gemini_service.dart';
import '../../services/gesture_image_service.dart';
import '../../services/settings_service.dart';
import '../../services/speech_service.dart';
import '../../widgets/auto_upright_camera_preview.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/hand_landmark.dart';
import '../../theme/app_theme.dart';
import '../settings_screen.dart';
import 'present_screen.dart';
import 'session_video_screen.dart';

class TranslateScreen extends StatefulWidget {
  /// False while another bottom-nav tab is selected — MainShell keeps this
  /// widget alive in an IndexedStack, so the camera pauses instead of
  /// being torn down, and resume is instant.
  const TranslateScreen({super.key, required this.visible});

  final bool visible;

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> with RouteAware {
  Timer? _autoTimer;
  int _timerMs = AppSettings.defaultAutoTranslateMs;
  bool _continuous = false;
  bool _speechMode = false;

  bool _describing = false;
  SignDescription? _signDescription;
  String? _speechError;
  Map<String, GestureItem> _gesturesByLabel = {};

  /// Sequential highlight through the described signs — the "perform
  /// the signs back" animation after a speech→sign translation lands.
  int _activeSignIndex = -1;
  Timer? _signPlayTimer;

  /// User-corrected version of the heard phrase — speech recognition
  /// mishears names and accents, so the Heard card is editable and
  /// re-translatable. Cleared when fresh speech arrives.
  String _editedHeard = '';

  /// SignUnits from the multi-LLM gloss compiler — drives tiles and
  /// non-manual-marker badges for the latest description.
  List<SignUnit> _signUnits = [];

  // Cached in initState — provider lookups are unsafe once the widget is
  // deactivated, so dispose() must not call context.read.
  late final TranslationController _controller;
  late final SpeechService _speechSvc;

  /// The last phrase already sent for sign conversion — dedupes the
  /// auto-describe trigger below.
  String _describedText = '';

  @override
  void initState() {
    super.initState();
    _controller = context.read<TranslationController>();
    _speechSvc = context.read<SpeechService>()..addListener(_onSpeechTick);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // IndexedStack builds every tab up front — don't grab the camera
      // (or its permission dialog) until the tab is actually shown.
      if (widget.visible) await _controller.initCamera();
      // Manual mode is the default — translation only runs when the user
      // taps the capture button. The auto-translate switch remains for
      // anyone who wants hands-free operation.
    });
  }

  @override
  void didUpdateWidget(TranslateScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      _resumeCamera();
    } else {
      _pauseCamera();
    }
  }

  /// Tab hidden — stop the auto-translate timer and pause the camera.
  /// The controller stays initialized, so resuming is instant.
  void _pauseCamera() {
    _autoTimer?.cancel();
    unawaited(_controller.pauseCamera());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// The speech engine auto-stops after a few seconds of silence — the
  /// final result lands without any tap, so the mic's stop-branch never
  /// runs. Watch the service and kick off sign conversion the moment a
  /// finished phrase arrives.
  void _onSpeechTick() {
    final svc = _speechSvc;
    final text = svc.recognizedText;
    if (text.isEmpty) {
      _describedText = '';
      // A capture that ended with no text reports why — the cloud
      // transcription resolves after stop() returns, so the mic-tap
      // handler never sees this failure; without this the UI looked
      // silently dead.
      if (!svc.listening &&
          !svc.transcribing &&
          svc.lastError.isNotEmpty &&
          _speechError == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _speechError == null) {
            setState(() => _speechError = svc.lastError);
          }
        });
      }
      return;
    }
    if (!_speechMode || _describing || text == _describedText) return;
    _describedText = text;
    // Fresh speech supersedes any manual edit and clears the stale
    // "Nothing heard" error from an earlier failed attempt.
    _editedHeard = '';
    _speechError = null;
    _describeCurrentText(text);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _speechSvc.removeListener(_onSpeechTick);
    _autoTimer?.cancel();
    _signPlayTimer?.cancel();
    _controller.disposeCamera();
    super.dispose();
  }

  /// Another page was pushed over this tab — release the camera so the
  /// pushed screen (e.g. sample capture) can use it and the battery
  /// isn't drained while hidden.
  @override
  void didPushNext() {
    _autoTimer?.cancel();
    _controller.disposeCamera();
  }

  @override
  void didPopNext() => _resumeCamera();

  void _resumeCamera() {
    _controller.resumeCamera().then((_) {
      if (mounted && _controller.cameraReady && _continuous) {
        _toggleContinuous(true, _controller);
      }
    });
  }

  void _toggleContinuous(bool value, TranslationController controller) {
    setState(() => _continuous = value);
    _autoTimer?.cancel();
    if (value) {
      _timerMs = context.read<AppSettings>().autoTranslateMs;
      _autoTimer = Timer.periodic(Duration(milliseconds: _timerMs), (_) {
        // Only spend work when the on-device model sees a hand —
        // localGuess is null until the model warms up, in which case
        // captureAndTranslate's own gate still protects the API call.
        // Offline, a confident local guess is still worth capturing —
        // the on-device pipeline doesn't need internet.
        final online = context.read<ConnectivityService>().isOnline;
        if (!controller.translating &&
            controller.cameraReady &&
            !controller.autoDisabled &&
            !controller.recordingSession &&
            controller.localGuess?.handPresent != false &&
            (online || controller.localGuess?.label != null)) {
          controller.captureAndTranslate();
        }
      });
    }
  }

  Future<void> _toggleListening(SpeechService speech) async {
    if (speech.listening) {
      await speech.stop();
      // _onSpeechTick picks up the final result and runs the conversion.
      if (mounted &&
          speech.recognizedText.isEmpty &&
          !speech.transcribing) {
        setState(() => _speechError = 'Nothing heard — try speaking again.');
      }
    } else {
      _signPlayTimer?.cancel();
      setState(() {
        _signDescription = null;
        _speechError = null;
        _activeSignIndex = -1;
        _editedHeard = '';
        _signUnits = [];
      });
      await speech.start();
    }
  }

  /// Lets the user fix a misheard phrase and re-translate — on-device
  /// speech recognition struggles with names and accents, so correcting
  /// the text beats getting wrong signs.
  Future<void> _editHeard(String current) async {
    final ctrl = TextEditingController(text: current);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Correct what was heard'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Type the correct phrase…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Translate'),
          ),
        ],
      ),
    );
    if (edited == null || edited.isEmpty || edited == current || !mounted) {
      return;
    }
    setState(() {
      _editedHeard = edited;
      _describedText = edited;
      _speechError = null;
    });
    await _describeCurrentText(edited);
  }

  /// Loads gesture rows into [_gesturesByLabel] once — the speech→sign
  /// tiles need them for illustrations; loaded on entering speech mode
  /// so partial-speech tiles can render before describeSign returns.
  Future<void> _loadGestureMap() async {
    if (_gesturesByLabel.isNotEmpty || !mounted) return;
    final gestures = await context.read<DbService>().getGestures(
      activeOnly: false,
    );
    if (mounted) {
      setState(() {
        _gesturesByLabel = {
          for (final g in gestures) g.label.toLowerCase(): g,
        };
      });
    }
  }

  /// Flattens a description's SIGN entries into (label, gesture) tile
  /// pairs — 'fingerspell:word' expands into one letter tile per char,
  /// matching how [_buildSignCards] lays them out.
  List<(String, GestureItem?, String)> _signTiles(SignDescription desc) {
    final signs = desc.signs.isNotEmpty
        ? desc.signs
        : _deriveSignsFromPhrase(desc.phrase);
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');
    String markerFor(String label) {
      for (final u in _signUnits) {
        final key = u.isFingerspelled ? u.originalWord : u.gloss;
        if (norm(key) == norm(label)) return u.nonManualMarker;
      }
      return '';
    }

    final tiles = <(String, GestureItem?, String)>[];
    for (final sign in signs) {
      if (sign.toLowerCase().startsWith('fingerspell:')) {
        // Every fingerspelled word becomes alphabet letter tiles —
        // letter_x.png assets are bundled for all 26 letters, so any
        // length renders. Long names used to fall through as one
        // unmatched tile that could only draw the fallback palm.
        for (final char in sign.substring(12).toLowerCase().split('')) {
          if (!RegExp('[a-z]').hasMatch(char)) continue;
          tiles.add((
            char.toUpperCase(),
            _gesturesByLabel['letter $char'],
            '',
          ));
        }
      } else {
        tiles.add((sign, _resolveGesture(sign), markerFor(sign)));
      }
    }
    return tiles;
  }

  /// Multi-source gloss chain — Gemini structured output first, then
  /// duck_ai labels, then the local tokenizer. Each hop only runs when
  /// the previous one failed, keeping cost and latency down; local
  /// derivation guarantees every word is covered.
  Future<({List<SignUnit> units, List<String> steps, String note})>
  _compileSigns(String phrase, List<String> vocab) async {
    // Capture service refs before any await (BuildContext lint).
    final gemini = context.read<GeminiService>();
    final duckAi = context.read<DuckAiService>();
    ({List<SignUnit> units, List<String> steps, String note})? result;
    try {
      result = await gemini.compileSignGloss(phrase, vocab);
    } catch (_) {}
    if (result == null) {
      // duck_ai hop now returns steps as well as sign labels — the
      // fallback path keeps showing real instructions when Gemini is
      // quota-blocked instead of a "needs the cloud" placeholder.
      final duck = await duckAi.describeSigns(phrase, vocabulary: vocab);
      if (duck != null && duck.signs.isNotEmpty) {
        result = (
          units: [for (final s in duck.signs) _unitFromLabel(s)],
          steps: duck.steps,
          note: duck.note,
        );
      }
    }
    result ??= (
      units: [
        for (final s in _deriveSignsFromPhrase(phrase)) _unitFromLabel(s),
      ],
      steps: const <String>[],
      note: '',
    );

    // Coverage pass — append locally-derived words the AI gloss missed.
    // A derived word counts as covered when EITHER the gloss or the
    // spoken original word matches it, stems included — otherwise
    // "going" mapped to gloss "Go" spawned a duplicate
    // fingerspell:going tile at the end.
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');
    String stemJoin(String s) => [
          for (final t in _wordTokens(s)) _stemWord(t),
        ].join();
    bool covers(SignUnit u, String derived) {
      final bare = derived.replaceAll('fingerspell:', '');
      final dKeys = {norm(bare), stemJoin(bare)};
      final uKeys = {
        norm(u.gloss),
        norm(u.originalWord),
        stemJoin(u.gloss),
        stemJoin(u.originalWord),
      };
      return dKeys.any(uKeys.contains);
    }

    final units = [...result.units];
    for (final d in _deriveSignsFromPhrase(phrase)) {
      if (!units.any((u) => covers(u, d))) {
        units.add(_unitFromLabel(d));
      }
    }
    return (units: units, steps: result.steps, note: result.note);
  }

  SignUnit _unitFromLabel(String label) {
    if (label.toLowerCase().startsWith('fingerspell:')) {
      final word = label.substring(12).trim();
      return SignUnit(
        gloss: word,
        originalWord: word,
        isFingerspelled: true,
      );
    }
    return SignUnit(gloss: label, originalWord: label);
  }

  /// Word/short-phrase → dataset-gesture lookup for speech tiles.
  /// Exact key first, then per-token stem and synonym expansion so
  /// "walking" finds "Walk" and "thanks" finds "Thank You". Labels made
  /// entirely of anatomical words (Palm, Hand) only ever match exactly —
  /// a non-palm word must never resolve onto a "Palm" row.
  GestureItem? _resolveGesture(String phrase) {
    final exact = _gesturesByLabel[phrase.toLowerCase().trim()];
    if (exact != null) return exact;
    final tokens = _wordTokens(phrase);
    if (tokens.isEmpty) return null;

    // Alternatives per token position: the stem itself plus each
    // synonym expansion, so "thanks" can try both [thank] and
    // [thank, you]. Combos stay tiny — ≤3 tokens × a few synonyms.
    final options = [
      for (final t in tokens)
        <List<String>>[
          [_stemWord(t)],
          for (final syn in _wordSynonyms[t] ?? const <String>[])
            [for (final st in _wordTokens(syn)) _stemWord(st)],
        ],
    ];
    var combos = <List<String>>[[]];
    for (final opts in options) {
      combos = [
        for (final c in combos)
          for (final o in opts) [...c, ...o],
      ];
      if (combos.length > 64) combos = combos.sublist(0, 64);
    }

    GestureItem? best;
    for (final entry in _gesturesByLabel.entries) {
      final lTokens = _wordTokens(entry.key);
      if (lTokens.isEmpty) continue;
      // Anatomy-only labels are exact-match territory (handled above).
      if (lTokens.every(_anatomicalWords.contains)) continue;
      final lStems = [for (final t in lTokens) _stemWord(t)];
      for (final combo in combos) {
        if (listEquals(combo, lStems)) {
          if (best == null || entry.key.length > best.label.length) {
            best = entry.value;
          }
          break;
        }
      }
    }
    return best;
  }

  /// Steps [_activeSignIndex] through every tile (~1.2s each) — the
  /// sequential "performance" of the translated signs. Clears the
  /// highlight when the sequence finishes.
  void _startSignPlayback() {
    _signPlayTimer?.cancel();
    final desc = _signDescription;
    if (desc == null) return;
    final count = _signTiles(desc).length;
    if (count == 0) return;
    var i = 0;
    setState(() => _activeSignIndex = 0);
    _signPlayTimer = Timer.periodic(const Duration(milliseconds: 1200), (
      timer,
    ) {
      i++;
      if (i >= count) {
        timer.cancel();
        _signPlayTimer = null;
        if (mounted) setState(() => _activeSignIndex = -1);
        return;
      }
      if (mounted) setState(() => _activeSignIndex = i);
    });
  }

  Future<void> _describeCurrentText(String text) async {
    var phrase = text.trim();
    if (phrase.isEmpty) {
      setState(() => _speechError = 'Nothing heard — try speaking again.');
      return;
    }
    setState(() => _describing = true);
    try {
      final db = context.read<DbService>();
      // Internet correction pass — catches names the on-device
      // recogniser mishears (e.g. "Thando" → "Kendall"). The corrected
      // phrase replaces what we translate and what the card shows.
      final corrected = await context.read<DuckAiService>().correctHeard(
        phrase,
      );
      if (corrected != null && mounted) {
        phrase = corrected;
        setState(() => _editedHeard = corrected);
      }
      final gestures = await db.getGestures(activeOnly: false);
      // Load the vocabulary first so sign cards render even if the
      // cloud call below fails.
      if (mounted) {
        setState(() {
          _gesturesByLabel = {
            for (final g in gestures) g.label.toLowerCase(): g,
          };
        });
      }
      if (!mounted) return;
      // Multi-source gloss chain — Gemini → duck_ai → local
      // tokenizer, each only on the previous one's failure.
      final compiled = await _compileSigns(
        phrase,
        gestures.map((g) => g.label).toList(),
      );
      _signUnits = compiled.units;
      final mergedDesc = SignDescription(
        phrase: phrase,
        steps: compiled.steps,
        note: compiled.note,
        signs: [for (final u in compiled.units) u.tileLabel],
      );
      if (mounted) {
        setState(() => _signDescription = mergedDesc);
        _startSignPlayback();
      }
      await _recordSpeechTranslation(phrase, mergedDesc);
    } on GeminiQuotaException {
      unawaited(
        _fallbackSignCards(
          phrase,
          'Translation service is busy — wait a moment and retry.',
        ),
      );
    } catch (e) {
      unawaited(
        _fallbackSignCards(
          phrase,
          e is StateError
              ? e.message
              : 'Could not translate — check your connection and retry.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _describing = false);
        // The cloud-verified transcript may have landed while this
        // describe was running — the tick drops updates while busy, so
        // translate the newest text here instead of leaving it stale.
        final latest = _speechSvc.recognizedText;
        if (latest.isNotEmpty && latest != _describedText) {
          _describedText = latest;
          unawaited(_describeCurrentText(latest));
        }
      }
    }
  }

  /// When the primary describe throws, the same multi-source chain
  /// still fills the cards — duck_ai/local usually cover the outage.
  Future<void> _fallbackSignCards(String phrase, String message) async {
    if (!mounted) return;
    final compiled = await _compileSigns(
      phrase,
      _gesturesByLabel.values.map((g) => g.label).toList(),
    );
    if (!mounted) return;
    _signUnits = compiled.units;
    final signs = [for (final u in compiled.units) u.tileLabel];
    setState(() {
      _speechError = message;
      _signDescription = signs.isEmpty
          ? null
          : SignDescription(
              phrase: phrase,
              steps: compiled.steps.isNotEmpty
                  ? compiled.steps
                  : const [
                      'Detailed instructions need the cloud — the sign tiles above come from the local dataset.',
                    ],
              note: compiled.note,
              signs: signs,
            );
      _activeSignIndex = -1;
    });
    _startSignPlayback();
  }

  /// Speech translations land in history like sign translations do —
  /// input_type 'speech' rows sync to Supabase with everything else.
  Future<void> _recordSpeechTranslation(
    String phrase,
    SignDescription desc,
  ) async {
    try {
      final user = context.read<AuthService>().currentUser;
      if (user == null) return;
      await context.read<DbService>().saveTranslation(
        TranslationRecord(
          userId: user.id!,
          inputType: 'speech',
          inputLabel: phrase,
          translatedText: desc.signs.isNotEmpty
              ? desc.signs.join(' / ')
              : desc.steps.first,
          confidence: 0,
          source: 'gemini',
          createdAt: DateTime.now(),
        ),
      );
    } catch (_) {
      // Recording is best-effort — never interrupt the display flow.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TranslationController>();
    final conn = context.watch<ConnectivityService>();
    final speech = context.watch<SpeechService>();
    final settings = context.watch<AppSettings>();

    // Admin-tuned interval changed mid-session — rebuild the timer so the
    // new cadence applies without restarting the screen.
    if (_continuous && !_speechMode && settings.autoTranslateMs != _timerMs) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toggleContinuous(true, controller);
      });
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.dark),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 130),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Live Translator',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white,
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Sign → Text'),
                    icon: Icon(Icons.back_hand_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Speech → Sign'),
                    icon: Icon(Icons.mic_outlined, size: 18),
                  ),
                ],
                selected: {_speechMode},
                onSelectionChanged: (s) {
                  final speech = s.first;
                  setState(() => _speechMode = speech);
                  // The camera isn't needed while the mic does the work —
                  // stop the stream in speech mode and bring it back on
                  // return to sign mode.
                  if (speech) {
                    _autoTimer?.cancel();
                    _controller.disposeCamera();
                    unawaited(_loadGestureMap());
                  } else {
                    _signPlayTimer?.cancel();
                    _activeSignIndex = -1;
                    _resumeCamera();
                  }
                },
              ),
              const SizedBox(height: 16),
              if (!conn.isOnline)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: GlassCard(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.wifi_off_outlined,
                          color: AppColors.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'You are offline. Connect to Wi-Fi or mobile data — live translation needs internet.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_speechMode)
                _buildSpeechMode(speech, conn)
              else
                _buildGestureMode(controller, conn),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ gesture mode

  Widget _buildGestureMode(
    TranslationController controller,
    ConnectivityService conn,
  ) {
    return Column(
      children: [
        _buildCameraCard(controller, conn),
        const SizedBox(height: 14),
        _buildMotionCard(controller),
        const SizedBox(height: 14),
        _buildBatchCard(controller),
        const SizedBox(height: 14),
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GlassCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppColors.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      controller.error!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.autorenew, color: AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Auto-translate',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Translates automatically when a sign appears.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _continuous,
                activeThumbColor: AppColors.primary,
                onChanged: controller.recordingSession
                    ? null
                    : (v) => _toggleContinuous(v, controller),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildResultCard(controller),
      ],
    );
  }

  /// Dynamic-sign capture: records a timed burst of frames while the
  /// signer performs one sign, so the cloud model sees the hand's
  /// movement — needed for signs that can't be told apart from a still.
  Widget _buildMotionCard(TranslationController controller) {
    final capturing = controller.capturingMotion;
    final busy = capturing || controller.translating;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.gesture_outlined,
                color: AppColors.accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Dynamic sign',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (capturing)
                Text(
                  '${controller.motionCaptured}/${TranslationController.motionFrameCount}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Signs that move (hello, come, go…) — hold the frame steady and perform the sign while it records.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      controller.cameraReady &&
                          !busy &&
                          !controller.recordingSession
                      ? controller.captureMotionBurst
                      : null,
                  icon: Icon(
                    capturing
                        ? Icons.fiber_manual_record
                        : Icons.videocam_outlined,
                    size: 18,
                  ),
                  label: Text(
                    capturing ? 'Recording… sign now' : 'Record sign (~2s)',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: capturing
                        ? AppColors.error
                        : AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
          if (capturing) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value:
                    controller.motionCaptured /
                    TranslationController.motionFrameCount,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Multi-sign capture: the user stashes one frame per sign, then sends
  /// the whole batch in a single request — fingerspelled words and
  /// multi-sign phrases come back as one combined translation.
  Widget _buildBatchCard(TranslationController controller) {
    final count = controller.batchFrames.length;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.photo_library_outlined,
                color: AppColors.secondary,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Multi-sign capture',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (count > 0)
                Text(
                  '$count/${TranslationController.maxBatchFrames} frames',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Add a frame for each sign, then translate them together into one phrase.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      controller.cameraReady && !controller.recordingSession
                      ? controller.captureToBatch
                      : null,
                  icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                  label: const Text('Add frame'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        count >= 2 &&
                            !controller.translating &&
                            !controller.recordingSession
                        ? controller.translateBatch
                        : null,
                    icon: const Icon(Icons.translate, size: 18),
                    label: const Text('Translate all'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear captured frames',
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.error,
                    size: 20,
                  ),
                  onPressed: controller.clearBatch,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCameraCard(
    TranslationController controller,
    ConnectivityService conn,
  ) {
    final cam = controller.cameraController;
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: cam != null && cam.value.isInitialized
              ? 1 / cam.value.aspectRatio
              : 4 / 5,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cam != null && cam.value.isInitialized)
                AutoUprightCameraPreview(cam)
              else
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: controller.error == null
                        ? const CircularProgressIndicator(
                            color: AppColors.primary,
                          )
                        : const Icon(
                            Icons.videocam_off_outlined,
                            color: Colors.white54,
                            size: 48,
                          ),
                  ),
                ),
              // Guide frame sized as a fraction of the preview — large
              // enough for big hands and full-arm signs, while keeping the
              // subject centred for the recognition model.
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.86,
                  heightFactor: 0.72,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.9),
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: _StatusChip(
                  label: controller.cameraReady
                      ? 'Camera ready'
                      : 'Initializing',
                  color: controller.cameraReady
                      ? AppColors.success
                      : AppColors.warning,
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: _StatusChip(
                  label: controller.translating
                      ? 'Analyzing'
                      : (_continuous ? 'Continuous' : 'Manual'),
                  color: _continuous ? AppColors.accent : AppColors.secondary,
                ),
              ),
              if (controller.recordingSession)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _StatusChip(
                      label:
                          'REC ${_fmtElapsed(controller.sessionElapsed)} / ${_fmtElapsed(const Duration(seconds: TranslationController.sessionMaxSeconds))}',
                      color: AppColors.error,
                    ),
                  ),
                ),
              // Kept clear of the centred capture/record row (which spans
              // roughly the bottom 100px) — long chips could otherwise
              // slide under the buttons.
              Positioned(
                bottom: 112,
                left: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StatusChip(
                      label: conn.statusLabel,
                      color: conn.isOnline
                          ? AppColors.success
                          : AppColors.error,
                    ),
                    if (controller.localGuess?.label != null) ...[
                      const SizedBox(width: 6),
                      _StatusChip(
                        label: 'On-device: ${controller.localGuess!.label}',
                        color: AppColors.accent,
                      ),
                    ] else if (controller.localGuess?.handPresent == true) ...[
                      const SizedBox(width: 6),
                      const _StatusChip(
                        label: 'Hand detected',
                        color: AppColors.secondary,
                      ),
                    ],
                  ],
                ),
              ),
              if (controller.lastFrame != null)
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      controller.lastFrame!,
                      width: 72,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              // Front/back lens switch — bottom-left corner, hidden on
              // single-camera devices and locked during busy states.
              if (controller.cameras.length > 1)
                Positioned(
                  left: 12,
                  bottom: 8,
                  child: _FlipButton(
                    enabled: controller.canSwitchCamera,
                    onTap: controller.switchCamera,
                  ),
                ),
              // Rolling live captions — the transcript grows under the
              // REC chip while the person signs, so a live signer can
              // see their words appear in near real time.
              if (controller.recordingSession &&
                  (controller.liveTranscript.isNotEmpty ||
                      controller.liveStatus.isNotEmpty ||
                      controller.liveSigns.isNotEmpty))
                Positioned(
                  top: 44,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(180),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (controller.liveTranscript.isNotEmpty)
                          Text(
                            controller.liveTranscript,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                        if (controller.liveStatus.isNotEmpty)
                          Text(
                            controller.liveStatus,
                            style: const TextStyle(
                              color: Color(0xFFF59E0B),
                              fontSize: 11,
                            ),
                          ),
                        if (controller.liveSigns.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _LiveSignStrip(signs: controller.liveSigns),
                        ],
                      ],
                    ),
                  ),
                ),
              // Elapsed-time progress strip pinned to the bottom edge of
              // the preview while a conversation recording is running.
              if (controller.recordingSession)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value:
                        controller.sessionElapsed.inSeconds /
                        TranslationController.sessionMaxSeconds,
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                    valueColor: const AlwaysStoppedAnimation(AppColors.error),
                  ),
                ),
              // Capture + record buttons — centred at the bottom of the
              // preview so they stay visible regardless of scroll.
              Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CaptureButton(
                        busy: controller.translating,
                        enabled:
                            controller.cameraReady &&
                            !controller.recordingSession,
                        onTap: () =>
                            controller.captureAndTranslate(manual: true),
                      ),
                      const SizedBox(width: 20),
                      _RecordButton(
                        recording: controller.recordingSession,
                        enabled:
                            controller.cameraReady &&
                            !controller.translating &&
                            !controller.capturingMotion,
                        onTap: () => controller.recordingSession
                            ? controller.stopSessionRecording()
                            : controller.startSessionRecording(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// m:ss formatting for the REC elapsed-time chip.
  static String _fmtElapsed(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildResultCard(TranslationController controller) {
    final result = controller.lastResult;
    if (result == null) {
      return GlassCard(
        child: Column(
          children: [
            const Icon(
              Icons.sign_language_outlined,
              size: 40,
              color: AppColors.primary,
            ),
            const SizedBox(height: 10),
            const Text(
              'No translation yet',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Show a sign inside the frame, then tap the button — or add several frames and translate them together.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
    }

    if (result.english == 'Could not determine') {
      return GlassCard(
        child: Row(
          children: [
            const Icon(Icons.back_hand_outlined, color: AppColors.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sign not recognised',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    result.note.isNotEmpty ? result.note : 'Keep the sign inside the frame with good lighting and try again.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.back_hand_outlined,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.gesture,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Confidence ${(result.confidence * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (controller.lastSessionVideoPath != null)
                IconButton(
                  tooltip: 'Replay recorded session',
                  icon: const Icon(
                    Icons.play_circle_outline,
                    color: AppColors.primary,
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SessionVideoScreen(
                        path: controller.lastSessionVideoPath!,
                      ),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Present to a hearing person',
                icon: const Icon(
                  Icons.present_to_all_outlined,
                  color: AppColors.secondary,
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PresentScreen()),
                ),
              ),
              IconButton(
                tooltip: 'Speak',
                icon: const Icon(
                  Icons.volume_up_outlined,
                  color: AppColors.accent,
                ),
                onPressed: controller.speakLast,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              result.english,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          if (result.note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              result.note,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------- speech mode

  Widget _buildSpeechMode(SpeechService speech, ConnectivityService conn) {
    // An edited phrase replaces the raw recognition for display — the
    // service text itself can't be changed, so the override lives here.
    final heard = _editedHeard.isNotEmpty
        ? _editedHeard
        : (speech.recognizedText.isNotEmpty
              ? speech.recognizedText
              : speech.partialText);

    return Column(
      children: [
        GlassCard(
          child: Column(
            children: [
              GestureDetector(
                onTap: conn.isOnline ? () => _toggleListening(speech) : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: speech.listening
                        ? const LinearGradient(
                            colors: [AppColors.error, AppColors.warning],
                          )
                        : AppGradients.hero,
                    boxShadow: [
                      BoxShadow(
                        color:
                            (speech.listening
                                    ? AppColors.error
                                    : AppColors.primary)
                                .withValues(alpha: 0.4),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: Icon(
                    speech.listening ? Icons.stop : Icons.mic,
                    size: 44,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                speech.listening
                    ? 'Listening… tap to stop'
                    : 'Tap and speak — I\'ll show the ZSL signs',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (heard.isNotEmpty)
          GlassCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Heard',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        heard,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Correct and re-translate',
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: AppColors.secondary,
                    size: 20,
                  ),
                  onPressed: _describing ? null : () => _editHeard(heard),
                ),
              ],
            ),
          ),
        // Live sign tiles from the partial phrase — rendered from the
        // local vocabulary while the person is still speaking, so signs
        // appear in real time before the cloud description lands.
        if (_signDescription == null && heard.isNotEmpty) ...[
          const SizedBox(height: 14),
          _buildLiveSignTiles(heard),
        ],
        if (_describing) ...[
          const SizedBox(height: 14),
          const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          ),
        ],
        if (_speechError != null) ...[
          const SizedBox(height: 14),
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: AppColors.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _speechError!,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_signDescription != null) ...[
          const SizedBox(height: 14),
          _buildSignCards(_signDescription!),
          const SizedBox(height: 14),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.sign_language_outlined,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Sign: ${_signDescription!.phrase}',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ..._signDescription!.steps.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: AppColors.secondary.withValues(
                            alpha: 0.2,
                          ),
                          child: Text(
                            '${e.key + 1}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.secondary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            e.value,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_signDescription!.note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _signDescription!.note,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Offline sign tiles for the partial phrase while the person is
  /// still speaking — real-time feedback before the cloud description
  /// and its richer tiles arrive.
  Widget _buildLiveSignTiles(String heard) {
    final signs = _deriveSignsFromPhrase(heard);
    if (signs.isEmpty) return const SizedBox.shrink();
    final tiles = <Widget>[];
    for (final sign in signs) {
      if (sign.toLowerCase().startsWith('fingerspell:')) {
        // Alphabet tiles for every fingerspelled word — bundled letter
        // art covers all 26 letters, so any length renders offline.
        for (final char in sign.substring(12).toLowerCase().split('')) {
          if (RegExp('[a-z]').hasMatch(char)) {
            tiles.add(_LiveSignTile(label: char.toUpperCase()));
          }
        }
      } else {
        tiles.add(_LiveSignTile(label: sign));
      }
    }
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Signs so far',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 12, children: tiles),
        ],
      ),
    );
  }

  /// One tile per sign the model mapped the phrase to — gesture
  /// illustrations where they exist, letter tiles for fingerspelled
  /// names/words. When the model omits SIGN lines, words are mapped to
  /// the dataset vocabulary locally so the cards still render.
  Widget _buildSignCards(SignDescription desc) {
    final tiles = _signTiles(desc);
    if (tiles.isEmpty) return const SizedBox.shrink();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Signs',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Replay signs',
                icon: const Icon(
                  Icons.replay,
                  color: AppColors.secondary,
                  size: 18,
                ),
                onPressed: _startSignPlayback,
              ),
            ],
          ),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 0; i < tiles.length; i++)
              _SignTile(
                label: tiles[i].$1,
                gesture: tiles[i].$2,
                marker: tiles[i].$3,
                active: _activeSignIndex == i,
              ),
          ]),
        ],
      ),
    );
  }

  /// Offline-safe sign mapping: greedy longest n-gram match of phrase
  /// words against the dataset via [_resolveGesture] — 5 tokens down to
  /// 1 — so "what is your name" and "how are you" stay whole and
  /// inflected words ("walking"→Walk, "thanks"→Thank You) still hit.
  /// Unmatched content words become `fingerspell:word` entries.
  List<String> _deriveSignsFromPhrase(String phrase) {
    const filler = {
      'the',
      'a',
      'an',
      'is',
      'my',
      'to',
      'and',
      'of',
      'in',
      'on',
      'at',
      'it',
      'am',
      'are',
      'i',
      'me',
      'be',
    };
    final tokens = _wordTokens(phrase);
    final out = <String>[];
    var i = 0;
    while (i < tokens.length) {
      var matched = false;
      for (final n in [5, 4, 3, 2, 1]) {
        if (i + n > tokens.length) continue;
        final g = _resolveGesture(tokens.sublist(i, i + n).join(' '));
        if (g != null) {
          out.add(g.label);
          i += n;
          matched = true;
          break;
        }
      }
      if (!matched) {
        if (!filler.contains(tokens[i])) {
          out.add('fingerspell:${tokens[i]}');
        }
        i++;
      }
    }
    return out;
  }
}

/// A single sign tile — 64px illustration (resolved/generated on demand)
/// with the gesture label underneath. [active] highlights the tile
/// during the sequential playback animation.
class _SignTile extends StatelessWidget {
  const _SignTile({
    required this.label,
    this.gesture,
    this.active = false,
    this.marker = '',
  });

  final String label;
  final GestureItem? gesture;
  final bool active;

  /// Non-manual grammar marker from the gloss compiler —
  /// eyebrows_raised / eyebrows_furrowed / head_shake / '' or 'neutral'.
  final String marker;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? AppColors.accent : Colors.transparent,
              width: 2,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.45),
                      blurRadius: 12,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(width: 64, height: 64, child: _image(context)),
              ),
              if (marker.isNotEmpty && marker != 'neutral')
                Positioned(
                  top: 2,
                  right: 2,
                  child: _MarkerBadge(marker: marker),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 64,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _image(BuildContext context) {
    final g = gesture;
    return FutureBuilder<File?>(
      future: g == null
          ? Future<File?>.value(null)
          : context
                .read<GestureImageService>()
                .ensureImage(g)
                .timeout(const Duration(seconds: 15), onTimeout: () => null),
      builder: (context, snap) {
        if (snap.data != null) {
          return Image.file(snap.data!, fit: BoxFit.cover);
        }
        final loading =
            g != null &&
            !snap.hasError &&
            snap.connectionState != ConnectionState.done;
        return _fallback(context, g, loading);
      },
    );
  }

  /// Guaranteed visual for every tile: bundled illustration art
  /// (alphabet + curated words), then the captured hand-skeleton sample,
  /// then a letter/glyph — all fully offline. A tiny spinner overlays
  /// the corner while an AI/cloud image is still resolving.
  Widget _fallback(BuildContext context, GestureItem? g, bool loading) {
    final asset =
        signAssetFor(g?.label ?? '') ??
        signAssetFor(label) ??
        signAssetFor('letter ${label.toLowerCase()}');
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: AppColors.primary.withValues(alpha: 0.12),
          child: asset != null
              ? Image.asset(asset, fit: BoxFit.contain)
              : g == null
              ? _base(context)
              : FutureBuilder<List<double>?>(
                  future: context.read<DbService>().getSampleLandmarks(g.label),
                  builder: (_, s) => s.data != null
                      ? LandmarkHand(landmarks: s.data!)
                      : _base(context),
                ),
        ),
        if (loading)
          const Positioned(
            right: 4,
            bottom: 4,
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: AppColors.primary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _base(BuildContext context) {
    if (label.length == 1) {
      return Center(
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    // AI-generated sign illustration first (consistent style, real
    // gesture drawings), web image as fallback — never an emoji.
    return FutureBuilder<File?>(
      future: context.read<GestureImageService>().imageForWord(label),
      builder: (context, snap) {
        final f = snap.data;
        if (f != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(f, fit: BoxFit.cover),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return _tileSpinner();
        }
        return FutureBuilder<String?>(
          future: context.read<DuckAiService>().signImageUrl(label),
          builder: (context, s) {
            final url = s.data;
            if (url != null) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _signIcon(),
                ),
              );
            }
            if (s.connectionState != ConnectionState.done) {
              return _tileSpinner();
            }
            return _signIcon();
          },
        );
      },
    );
  }

  Widget _tileSpinner() => const Center(
    child: SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: AppColors.secondary,
      ),
    ),
  );

  /// Last-resort tile visual — a text badge, never a hand icon: an
  /// open-palm glyph lied about the sign for every unmatched word.
  Widget _signIcon() {
    final words = label
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return const Center(
        child: Text(
          '?',
          style: TextStyle(
            color: AppColors.secondary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    final text = words.length > 1
        ? words.take(2).map((w) => w[0]).join().toUpperCase()
        : (words.first.length == 1
              ? words.first.toUpperCase()
              : words.first.substring(0, 2).toUpperCase());
    return Center(
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Horizontal strip of sign tiles that grows as a session recognises
/// signs — auto-scrolls to the newest entry so the latest sign is
/// always in view without the user touching anything.
class _LiveSignStrip extends StatefulWidget {
  const _LiveSignStrip({required this.signs});

  final List<String> signs;

  @override
  State<_LiveSignStrip> createState() => _LiveSignStripState();
}

class _LiveSignStripState extends State<_LiveSignStrip> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_LiveSignStrip old) {
    super.didUpdateWidget(old);
    if (widget.signs.length != old.signs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemCount: widget.signs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => _LiveSignTile(label: widget.signs[i]),
      ),
    );
  }
}

/// Lightweight offline-only sign tile for live surfaces — bundled
/// illustration, recorded landmark skeleton, glyph or letter. Never
/// waits on the network/image-generation path so it can't stall a
/// real-time strip.
class _LiveSignTile extends StatelessWidget {
  const _LiveSignTile({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 52, height: 52, child: _image(context)),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 60,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 9),
          ),
        ),
      ],
    );
  }

  Widget _image(BuildContext context) {
    final asset =
        signAssetFor(label) ?? signAssetFor('letter ${label.toLowerCase()}');
    if (asset != null) {
      return Container(
        color: AppColors.primary.withValues(alpha: 0.12),
        child: Image.asset(asset, fit: BoxFit.contain),
      );
    }
    return Container(
      color: AppColors.primary.withValues(alpha: 0.12),
      child: FutureBuilder<List<double>?>(
        future: context.read<DbService>().getSampleLandmarks(label),
        builder: (context, snap) {
          if (snap.data != null) {
            return LandmarkHand(landmarks: snap.data!);
          }
          if (label.length == 1) {
            return Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
          }
          // AI illustration first, web image fallback — never an emoji.
          return FutureBuilder<File?>(
            future: context.read<GestureImageService>().imageForWord(label),
            builder: (context, gen) {
              final f = gen.data;
              if (f != null) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(f, fit: BoxFit.cover),
                );
              }
              if (gen.connectionState != ConnectionState.done) {
                return _liveTileSpinner();
              }
              return FutureBuilder<String?>(
                future: context.read<DuckAiService>().signImageUrl(label),
                builder: (context, s) {
                  final url = s.data;
                  if (url != null) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _liveSignIcon(),
                      ),
                    );
                  }
                  if (s.connectionState != ConnectionState.done) {
                    return _liveTileSpinner();
                  }
                  return _liveSignIcon();
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _liveTileSpinner() => const Center(
    child: SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: AppColors.secondary,
      ),
    ),
  );

  /// Text-badge fallback — an open-palm icon implied a sign that isn't
  /// actually one, so unmatched words show their initials instead.
  Widget _liveSignIcon() {
    final words = label
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return const Center(
        child: Text(
          '?',
          style: TextStyle(
            color: AppColors.secondary,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    final text = words.length > 1
        ? words.take(2).map((w) => w[0]).join().toUpperCase()
        : (words.first.length == 1
              ? words.first.toUpperCase()
              : words.first.substring(0, 2).toUpperCase());
    return Center(
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Small badge marking non-manual grammar on a sign tile —
/// eyebrows_raised → yes/no question, eyebrows_furrowed → wh-question,
/// head_shake → negation. Icons only, never emoji.
class _MarkerBadge extends StatelessWidget {
  const _MarkerBadge({required this.marker});

  final String marker;

  @override
  Widget build(BuildContext context) {
    final icon = switch (marker) {
      'eyebrows_raised' => Icons.help_outline,
      'eyebrows_furrowed' => Icons.help,
      'head_shake' => Icons.block,
      _ => null,
    };
    if (icon == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 12, color: Colors.black),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Round record/stop button beside the shutter — starts a session
/// recording (red dot) and stops + translates it (stop square).
class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.recording,
    required this.enabled,
    required this.onTap,
  });

  final bool recording;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: recording
                  ? AppColors.error
                  : (enabled
                        ? Colors.white.withValues(alpha: 0.15)
                        : Colors.black54),
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: (recording ? AppColors.error : Colors.black)
                      .withValues(alpha: 0.4),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Center(
              child: Icon(
                recording ? Icons.stop : Icons.fiber_manual_record,
                color: recording ? Colors.white : AppColors.error,
                size: 30,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              recording ? 'Stop & translate' : 'Record session',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small flip-camera control pinned to the bottom-left of the preview.
class _FlipButton extends StatelessWidget {
  const _FlipButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: 'Switch camera',
        icon: const Icon(Icons.cameraswitch_outlined, size: 22),
        color: Colors.white,
        disabledColor: Colors.white38,
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

/// Round shutter-style button centred on the camera preview — the manual
/// capture control, always on screen regardless of scroll position.
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: enabled && !busy ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled ? AppGradients.hero : null,
              color: enabled ? null : Colors.black54,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Icon(
                      enabled ? Icons.translate : Icons.wifi_off_outlined,
                      color: Colors.white,
                      size: 28,
                    ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'Translate Now',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Speech→sign word matching — file-private helpers.
// Keep _stemWord/_wordTokens identical to the copies in
// gemini_service.dart: the two sides implement the same conservative
// stemming contract by design.
// ---------------------------------------------------------------------

/// Lowercase word tokens for sign matching.
List<String> _wordTokens(String s) => s
    .toLowerCase()
    .split(RegExp("[^a-z0-9']+"))
    .where((w) => w.isNotEmpty)
    .toList();

/// Conservative English stem for transcript words — strips only the
/// inflections speech actually produces. A missed stem just costs a
/// fingerspell tile; a wrong stem could hijack a real sign.
String _stemWord(String w) {
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
String _undouble(String s) {
  if (s.length > 2 && s[s.length - 1] == s[s.length - 2]) {
    return s.substring(0, s.length - 1);
  }
  return s;
}

/// Body-part vocabulary — labels made entirely of these only match
/// exactly; they never resolve loosely from other words.
const _anatomicalWords = {
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

/// Small spoken-English synonym expansions for vocabulary lookup —
/// keyed on the spoken token, values are the dataset phrasing. Kept
/// deliberately short: every entry trades a fingerspell tile for the
/// risk of a wrong sign.
const _wordSynonyms = <String, List<String>>{
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
