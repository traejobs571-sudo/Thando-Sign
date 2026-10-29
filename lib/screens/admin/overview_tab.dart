import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/backup_service.dart';
import '../../services/db_service.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stat_tile.dart';
import 'reports_screen.dart';

/// Dashboard landing: usage stats, sync health and the common admin
/// actions (backup, reports) in one glance.
class OverviewTab extends StatelessWidget {
  const OverviewTab({super.key});

  @override
  Widget build(BuildContext context) {
    final db = context.read<DbService>();
    final sync = context.watch<SyncService>();
    final tileWidth = (MediaQuery.of(context).size.width - 52) / 2;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FutureBuilder<Map<String, int>>(
          future: db.getTranslationStats(),
          builder: (context, snapshot) {
            final s =
                snapshot.data ??
                {'total': 0, 'users': 0, 'gestures': 0, 'today': 0};
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: tileWidth,
                  child: StatTile(
                    title: 'Translations',
                    value: '${s['total']}',
                    icon: Icons.translate,
                    color: AppColors.primary,
                    subtitle: '${s['today']} today',
                  ),
                ),
                SizedBox(
                  width: tileWidth,
                  child: StatTile(
                    title: 'Users',
                    value: '${s['users']}',
                    icon: Icons.people_outline,
                    color: AppColors.secondary,
                  ),
                ),
                SizedBox(
                  width: tileWidth,
                  child: StatTile(
                    title: 'Gestures',
                    value: '${s['gestures']}',
                    icon: Icons.back_hand_outlined,
                    color: AppColors.accent,
                  ),
                ),
                SizedBox(
                  width: tileWidth,
                  child: StatTile(
                    title: 'Pending sync',
                    value: '${sync.pendingCount}',
                    icon: Icons.cloud_upload_outlined,
                    color: AppColors.warning,
                    subtitle: sync.enabled
                        ? (sync.canSync ? 'Connected' : 'Waiting')
                        : 'Local only',
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    sync.enabled
                        ? (sync.canSync
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined)
                        : Icons.cloud_off_outlined,
                    color: sync.canSync ? AppColors.success : AppColors.warning,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      !sync.enabled
                          ? 'Local only — Supabase not configured'
                          : sync.canSync
                          ? 'Supabase connected'
                          : 'Supabase configured — ${sync.blocker}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (sync.enabled)
                    TextButton.icon(
                      onPressed: sync.syncing ? null : sync.syncNow,
                      icon: sync.syncing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync, size: 18),
                      label: Text(sync.syncing ? 'Syncing…' : 'Sync now'),
                    ),
                ],
              ),
              if (sync.lastSyncAt != null)
                Text(
                  'Last synced ${DateFormat('MMM d, HH:mm').format(sync.lastSyncAt!)}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              if (sync.lastError != null)
                Text(
                  sync.lastError!,
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _backup(context),
                icon: const Icon(Icons.backup_outlined, size: 18),
                label: const Text('Backup now'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReportsScreen()),
                ),
                icon: const Icon(Icons.bar_chart_outlined, size: 18),
                label: const Text('Reports'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _backup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<BackupService>().shareBackup();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }
}
