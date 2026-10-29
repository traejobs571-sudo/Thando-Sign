import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/db_service.dart';
import '../../services/gemini_service.dart';
import '../../services/gesture_image_service.dart';
import '../../services/settings_service.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

/// Admin system settings: recognition tuning, sync status and the
/// destructive data controls (backup, restore, reset, clear).
class AdminSettingsTab extends StatefulWidget {
  const AdminSettingsTab({super.key});

  @override
  State<AdminSettingsTab> createState() => _AdminSettingsTabState();
}

class _AdminSettingsTabState extends State<AdminSettingsTab> {
  String? _maskedKey;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final key = await context.read<GeminiService>().getApiKey();
    if (!mounted) return;
    setState(() {
      _maskedKey = (key == null || key.length < 8)
          ? null
          : '••••••••${key.substring(key.length - 4)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final sync = context.watch<SyncService>();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _sectionTitle('Recognition'),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.key_outlined, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Gemini API key',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _maskedKey ?? 'Using bundled key / not set',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _showKeyDialog,
                    child: const Text('Change'),
                  ),
                  if (_maskedKey != null)
                    TextButton(
                      onPressed: () async {
                        await context.read<GeminiService>().clearApiKey();
                        _loadKey();
                      },
                      child: const Text(
                        'Clear',
                        style: TextStyle(color: AppColors.error),
                      ),
                    ),
                ],
              ),
              const Divider(height: 24),
              _sliderRow(
                icon: Icons.timer_outlined,
                title: 'Auto-translate interval',
                subtitle: '${settings.autoTranslateMs} ms between captures',
                value: settings.autoTranslateMs.toDouble(),
                min: 400,
                max: 4000,
                divisions: 18,
                label: '${settings.autoTranslateMs} ms',
                onChanged: (v) => settings.setAutoTranslateMs(v.round()),
              ),
              const Divider(height: 24),
              _sliderRow(
                icon: Icons.tune,
                title: 'On-device confidence floor',
                subtitle:
                    '${(settings.localConfidenceFloor * 100).toStringAsFixed(0)}% — below this, frames escalate to Gemini',
                value: settings.localConfidenceFloor,
                min: 0.50,
                max: 0.95,
                divisions: 9,
                label: settings.localConfidenceFloor.toStringAsFixed(2),
                onChanged: settings.setLocalConfidenceFloor,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle('Access'),
        GlassCard(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(
              Icons.person_add_alt_outlined,
              color: AppColors.secondary,
            ),
            title: const Text(
              'Allow new registrations',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              'When off, the Create account screen refuses new sign-ups on this device',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            value: settings.allowRegistration,
            activeThumbColor: AppColors.primary,
            onChanged: settings.setAllowRegistration,
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle('Sync'),
        GlassCard(
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    sync.canSync
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: sync.canSync ? AppColors.success : AppColors.warning,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sync.enabled
                              ? '${sync.pendingCount} change${sync.pendingCount == 1 ? '' : 's'} pending'
                              : 'Supabase not configured',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (sync.lastSyncAt != null)
                          Text(
                            'Last synced ${DateFormat('MMM d, HH:mm').format(sync.lastSyncAt!)}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 12,
                            ),
                          ),
                        if (sync.enabled && !sync.canSync)
                          Text(
                            sync.blocker ?? '',
                            style: const TextStyle(
                              color: AppColors.warning,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (sync.enabled)
                    TextButton.icon(
                      onPressed: sync.syncing ? null : sync.syncNow,
                      icon: const Icon(Icons.sync, size: 18),
                      label: Text(sync.syncing ? 'Syncing…' : 'Sync now'),
                    ),
                ],
              ),
              if (sync.enabled) ...[
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Cloud sync',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    'Push local changes and receive live dataset updates',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                  value: settings.cloudSyncEnabled,
                  activeThumbColor: AppColors.primary,
                  onChanged: settings.setCloudSyncEnabled,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle('Data'),
        GlassCard(
          child: Column(
            children: [
              _sliderRow(
                icon: Icons.history_outlined,
                title: 'History retention',
                subtitle: settings.historyRetentionDays == 0
                    ? 'Keep translations forever'
                    : 'Auto-suggested purge: keep last ${settings.historyRetentionDays} days',
                value: settings.historyRetentionDays.toDouble(),
                min: 0,
                max: 365,
                divisions: 12,
                label: settings.historyRetentionDays == 0
                    ? 'Forever'
                    : '${settings.historyRetentionDays}d',
                onChanged: (v) => settings.setHistoryRetentionDays(v.round()),
              ),
              const Divider(height: 24),
              _actionTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Purge old history',
                subtitle: 'Delete translations older than the retention period',
                color: AppColors.warning,
                onTap: _busy ? null : _purgeHistory,
              ),
              const Divider(height: 20),
              _actionTile(
                icon: Icons.backup_outlined,
                title: 'Backup now',
                subtitle: 'Export the full database to share or store',
                color: AppColors.primary,
                onTap: _busy ? null : _backup,
              ),
              const Divider(height: 20),
              _actionTile(
                icon: Icons.restore_outlined,
                title: 'Restore from backup',
                subtitle: 'Replace all data with a .db backup file',
                color: AppColors.warning,
                onTap: _busy ? null : _restore,
              ),
              const Divider(height: 20),
              _actionTile(
                icon: Icons.dataset_outlined,
                title: 'Reset gesture dataset',
                subtitle: 'Restore the bundled ZSL vocabulary',
                color: AppColors.warning,
                onTap: _busy ? null : _resetDataset,
              ),
              const Divider(height: 20),
              _actionTile(
                icon: Icons.image_outlined,
                title: 'Generate gesture images',
                subtitle: 'AI-create illustrations for gestures missing one',
                color: AppColors.secondary,
                onTap: _busy ? null : _generateImages,
              ),
              const Divider(height: 20),
              _actionTile(
                icon: Icons.delete_sweep_outlined,
                title: 'Clear system logs',
                subtitle: 'Delete all log entries on this device',
                color: AppColors.error,
                onTap: _busy ? null : _clearLogs,
              ),
            ],
          ),
        ),
      ],
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
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: AppColors.secondary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: AppColors.primary,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: Colors.white.withValues(alpha: 0.4)),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- actions

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      await context.read<BackupService>().shareBackup();
    } catch (e) {
      debugPrint('Backup failed: $e');
      _toast('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final file = await context.read<BackupService>().pickAndValidateBackup();
      if (file == null || !mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore backup?'),
          content: Text(
            'This replaces ALL current data with ${file.path.split(Platform.pathSeparator).last}. '
            'You will be signed out. This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      await context.read<BackupService>().restoreFrom(file);
      if (!mounted) return;
      await context.read<AuthService>().logout();
      if (mounted) context.go('/login');
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetDataset() async {
    final confirmed = await _confirm(
      'Reset gesture dataset?',
      'Custom gestures are removed and the bundled ZSL vocabulary is '
          'restored. The change syncs to the server.',
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<DbService>().resetGestureDataset();
      _toast('Dataset reset to defaults.');
    } catch (e) {
      _toast('Reset failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Walks the dataset and generates/uploads an illustration for every
  /// gesture that doesn't already have one cached. Serialized inside the
  /// service — this just kicks the queue.
  Future<void> _generateImages() async {
    setState(() => _busy = true);
    try {
      final images = context.read<GestureImageService>();
      final gestures = await context.read<DbService>().getGestures(
        activeOnly: false,
      );
      var made = 0;
      for (final g in gestures) {
        final uuid = g.uuid;
        if (uuid == null || (await images.cachedFile(uuid)) != null) {
          continue;
        }
        if (await images.ensureImage(g) != null) made++;
        if (!mounted) return;
      }
      _toast(
        made == 0
            ? 'Every gesture already has an image.'
            : 'Generated $made gesture image${made == 1 ? '' : 's'}.',
      );
    } catch (e) {
      _toast('Image generation failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeHistory() async {
    final settings = context.read<AppSettings>();
    if (settings.historyRetentionDays == 0) {
      _toast('Retention is set to "Forever" — nothing to purge.');
      return;
    }
    final confirmed = await _confirm(
      'Purge old history?',
      'Translations older than ${settings.historyRetentionDays} days will be '
          'deleted from this device. This cannot be undone.',
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final cutoff = DateTime.now().subtract(
        Duration(days: settings.historyRetentionDays),
      );
      final removed = await context
          .read<DbService>()
          .purgeTranslationsOlderThan(cutoff);
      _toast('Purged $removed old translations.');
    } catch (e) {
      _toast('Purge failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await _confirm(
      'Clear system logs?',
      'All log entries on this device will be deleted.',
    );
    if (confirmed != true || !mounted) return;
    await context.read<DbService>().clearSystemLogs();
    _toast('System logs cleared.');
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showKeyDialog() async {
    final controller = TextEditingController();
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Gemini API key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  hintText: 'Paste a Gemini API key',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final key = controller.text.trim();
                if (key.length < 10) {
                  setDialogState(() => error = 'That key looks too short.');
                  return;
                }
                await context.read<GeminiService>().setApiKey(key);
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (saved == true) _loadKey();
  }
}
