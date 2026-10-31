import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/db_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import '../widgets/glass_card.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final tts = context.read<TtsService>();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.dark),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionTitle('Voice output'),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Adjust how translations sound when spoken aloud.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _sliderRow(
                      icon: Icons.speed,
                      label: 'Speed',
                      value: settings.speechRate,
                      min: 0.2,
                      max: 1.0,
                      divisions: 8,
                      display: settings.speechRate.toStringAsFixed(2),
                      onChanged: (v) => settings.setSpeechRate(v),
                      onChangeEnd: tts.setRate,
                    ),
                    _sliderRow(
                      icon: Icons.graphic_eq,
                      label: 'Pitch',
                      value: settings.speechPitch,
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      display: settings.speechPitch.toStringAsFixed(2),
                      onChanged: (v) => settings.setSpeechPitch(v),
                      onChangeEnd: tts.setPitch,
                    ),
                    _sliderRow(
                      icon: Icons.volume_up_outlined,
                      label: 'Volume',
                      value: settings.speechVolume,
                      min: 0.0,
                      max: 1.0,
                      divisions: 10,
                      display:
                          '${(settings.speechVolume * 100).toStringAsFixed(0)}%',
                      onChanged: (v) => settings.setSpeechVolume(v),
                      onChangeEnd: tts.setVolume,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => context.read<TtsService>().speak(
                          'Hello, this is Thando Sign.',
                        ),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Test voice'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _sectionTitle('Translations'),
              GlassCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(
                        Icons.record_voice_over_outlined,
                        color: AppColors.secondary,
                      ),
                      title: const Text(
                        'Speak results automatically',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: Text(
                        'Read each translation aloud as soon as it is recognised — including live captions while a session is recording',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 12,
                        ),
                      ),
                      value: settings.autoSpeak,
                      activeThumbColor: AppColors.primary,
                      onChanged: settings.setAutoSpeak,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _sectionTitle('My data'),
              GlassCard(
                child: InkWell(
                  onTap: _clearHistory,
                  borderRadius: BorderRadius.circular(10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          color: AppColors.error,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Clear my history',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Delete all of my translations on this device',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.shield_outlined, color: AppColors.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Camera frames are processed for recognition and are never stored; recorded session clips stay on this device and are never uploaded. When online, your translation history and account details sync securely to the ThandoSign server.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    ),
  );

  Widget _sliderRow({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, color: AppColors.secondary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
            Text(display, style: const TextStyle(color: Colors.white)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: AppColors.primary,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  Future<void> _clearHistory() async {
    final user = context.read<AuthService>().currentUser;
    if (user == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'All of your translations on this device will be deleted. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await context.read<DbService>().deleteTranslationsForUser(
      user.id!,
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Removed $removed translations.')));
    }
  }
}
