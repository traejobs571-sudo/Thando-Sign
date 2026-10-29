import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/db_service.dart';
import '../../widgets/app_logo.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stat_tile.dart';
import '../../theme/app_theme.dart';
import '../admin/admin_console.dart';
import '../settings_screen.dart';
import 'main_shell.dart';

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final user = auth.currentUser;
    final db = context.read<DbService>();

    return Container(
      decoration: const BoxDecoration(gradient: AppGradients.dark),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hello, ${user?.name.split(' ').first ?? 'User'}',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Ready to translate Zimbabwe Sign Language?',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                if (auth.isAdmin)
                  IconButton(
                    tooltip: 'Admin console',
                    icon: const Icon(
                      Icons.admin_panel_settings_outlined,
                      color: Colors.white,
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AdminConsole()),
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
            const SizedBox(height: 24),
            GlassCard(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Live ZSL → English',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Point the camera at a signer and translate gestures to English in real time.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: () => context
                              .findAncestorStateOfType<MainShellState>()
                              ?.selectTab(1),
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Start translating'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  const AppLogo(size: 84),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Global usage counts are system-level info — only admins see them.
            if (auth.isAdmin)
            FutureBuilder<Map<String, int>>(
              future: db.getTranslationStats(),
              builder: (context, snapshot) {
                final stats =
                    snapshot.data ??
                    {'total': 0, 'users': 0, 'gestures': 0, 'today': 0};
                return Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        title: 'Translations',
                        value: '${stats['total']}',
                        icon: Icons.translate,
                        color: AppColors.primary,
                        subtitle: '${stats['today']} today',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        title: 'ZSL gestures',
                        value: '${stats['gestures']}',
                        icon: Icons.sign_language_outlined,
                        color: AppColors.secondary,
                        subtitle: 'In dataset',
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            const Text(
              'How it works',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            const _StepTile(
              number: '1',
              title: 'Position the signer',
              text: 'Keep hands clearly inside the frame with good lighting.',
            ),
            const _StepTile(
              number: '2',
              title: 'Capture a gesture',
              text: 'Tap Translate Now to analyse the gesture in the frame.',
            ),
            const _StepTile(
              number: '3',
              title: 'Read & listen',
              text: 'The app shows the English meaning and speaks it aloud.',
            ),
            const SizedBox(height: 20),
            GlassCard(
              child: Row(
                children: [
                  const Icon(
                    Icons.privacy_tip_outlined,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Live camera frames are never stored or uploaded — only the recognised text is kept. Session recordings stay on this device and are never sent anywhere. Do not capture sensitive information.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.number,
    required this.title,
    required this.text,
  });

  final String number;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.primary.withValues(alpha: 0.2),
              child: Text(
                number,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
