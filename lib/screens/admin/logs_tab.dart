import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/db_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

/// System log management: browse, filter by action, search, and clear.
class LogsTab extends StatefulWidget {
  const LogsTab({super.key});

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  List<Map<String, Object?>> _logs = [];
  bool _loading = true;
  String _search = '';
  String? _actionFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logs = await context.read<DbService>().getSystemLogs(limit: 300);
    if (mounted) {
      setState(() {
        _logs = logs;
        _loading = false;
      });
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear system logs?'),
        content: const Text(
          'All log entries on this device will be deleted and the clear '
          'will sync to the server.',
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
    if (confirmed == true && mounted) {
      await context.read<DbService>().clearSystemLogs();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = _logs
        .map((l) => l['action'] as String? ?? '')
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList();

    final filtered = _logs.where((l) {
      final action = l['action'] as String? ?? '';
      final details = (l['details'] as String? ?? '').toLowerCase();
      if (_actionFilter != null && action != _actionFilter) return false;
      if (_search.isNotEmpty &&
          !action.toLowerCase().contains(_search) &&
          !details.contains(_search)) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'System logs (${filtered.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _logs.isEmpty ? null : _clearLogs,
                icon: const Icon(
                  Icons.delete_sweep_outlined,
                  size: 18,
                  color: AppColors.error,
                ),
                label: const Text(
                  'Clear',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search logs…',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
          ),
        ),
        if (actions.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: _actionFilter == null,
                    onSelected: (_) => setState(() => _actionFilter = null),
                  ),
                ),
                ...actions.map(
                  (a) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(a),
                      selected: _actionFilter == a,
                      onSelected: (sel) =>
                          setState(() => _actionFilter = sel ? a : null),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                )
              : filtered.isEmpty
              ? Center(
                  child: Text(
                    'No log entries.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  children: filtered.map(_logTile).toList(),
                ),
        ),
      ],
    );
  }

  Widget _logTile(Map<String, Object?> log) {
    final created = DateTime.tryParse(log['created_at'] as String? ?? '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.circle, size: 8, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    log['action'] as String? ?? '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    log['details'] as String? ?? '',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (created != null)
              Text(
                DateFormat('MMM d, HH:mm').format(created),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 10,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
