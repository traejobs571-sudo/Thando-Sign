import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/translation_controller.dart';
import '../../services/connectivity_service.dart';
import '../../services/gemini_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

/// Fullscreen view meant to be held up to a hearing person: the latest
/// translation rendered as large as possible, the recognised sign, the
/// captured frame, and on-demand instructions for how the sign is made.
/// Live-updates as translations arrive.
class PresentScreen extends StatefulWidget {
  const PresentScreen({super.key});

  @override
  State<PresentScreen> createState() => _PresentScreenState();
}

class _PresentScreenState extends State<PresentScreen> {
  /// Sign instructions are fetched once per label — the descriptions
  /// don't change, and every call burns Gemini quota.
  final Map<String, SignDescription> _stepsCache = {};
  bool _loadingSteps = false;
  bool _showSteps = false;
  String? _stepsError;

  Future<void> _loadSteps(TranslationController controller) async {
    final result = controller.lastResult;
    if (result == null) return;
    if (_stepsCache.containsKey(result.gesture)) {
      setState(() => _showSteps = !_showSteps);
      return;
    }
    setState(() {
      _loadingSteps = true;
      _stepsError = null;
    });
    try {
      final desc = await context.read<GeminiService>().describeSign(
        result.gesture,
      );
      _stepsCache[result.gesture] = desc;
      if (mounted) setState(() => _showSteps = true);
    } on GeminiQuotaException {
      if (mounted) {
        setState(() => _stepsError = 'Service is busy — try again shortly.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _stepsError = 'Could not load signing steps right now.',
        );
      }
    } finally {
      if (mounted) setState(() => _loadingSteps = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TranslationController>();
    final online = context.watch<ConnectivityService>().isOnline;
    final result = controller.lastResult;
    final frame = controller.lastFrame;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  Text(
                    'Present mode',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 8),
              if (result == null)
                Expanded(
                  child: Center(
                    child: Text(
                      'Waiting for a sign…',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 20,
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Column(
                    children: [
                      if (frame != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.memory(
                            frame,
                            height: 140,
                            fit: BoxFit.cover,
                          ),
                        ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.secondary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.secondary.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          'Sign: ${result.gesture}',
                          style: const TextStyle(
                            color: AppColors.secondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width - 40,
                              ),
                              child: Text(
                                result.english == 'Could not determine'
                                    ? 'Sign not recognised'
                                    : result.english,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 96,
                                  fontWeight: FontWeight.bold,
                                  height: 1.1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (result.note.isNotEmpty &&
                          result.english != 'Could not determine')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            result.note,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              if (result != null && result.english != 'Could not determine')
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _loadingSteps || !online
                        ? null
                        : () => _loadSteps(controller),
                    icon: _loadingSteps
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sign_language_outlined),
                    label: Text(
                      _showSteps ? 'Hide signing steps' : 'Show how to sign it',
                    ),
                  ),
                ),
              if (_stepsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _stepsError!,
                    style: const TextStyle(color: AppColors.error),
                  ),
                ),
              if (_showSteps &&
                  result != null &&
                  _stepsCache[result.gesture] != null) ...[
                const SizedBox(height: 10),
                GlassCard(
                  padding: const EdgeInsets.all(14),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: ListView(
                      shrinkWrap: true,
                      children: _stepsCache[result.gesture]!.steps
                          .asMap()
                          .entries
                          .map(
                            (e) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 11,
                                    backgroundColor: AppColors.secondary
                                        .withValues(alpha: 0.2),
                                    child: Text(
                                      '${e.key + 1}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: AppColors.secondary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      e.value,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.85,
                                        ),
                                        fontSize: 13,
                                        height: 1.35,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
