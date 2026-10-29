import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/db_service.dart';
import '../../widgets/report_charts.dart';
import '../../widgets/stat_tile.dart';
import '../../theme/app_theme.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final db = context.read<DbService>();
    final tileWidth = (MediaQuery.of(context).size.width - 52) / 2;

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
                  const Expanded(
                    child: Text(
                      'Reports',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Export',
                    icon: const Icon(
                      Icons.download_outlined,
                      color: Colors.white,
                    ),
                    color: AppColors.surfaceVariant,
                    onSelected: (v) => _export(context, db, v),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'translations',
                        child: Text('Export translations (CSV)'),
                      ),
                      PopupMenuItem(
                        value: 'engagement',
                        child: Text('Export user engagement (CSV)'),
                      ),
                      PopupMenuItem(
                        value: 'users',
                        child: Text('Export users (CSV)'),
                      ),
                      PopupMenuItem(
                        value: 'logs',
                        child: Text('Export system logs (CSV)'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 7, label: Text('7 days')),
                    ButtonSegment(value: 30, label: Text('30 days')),
                    ButtonSegment(value: 90, label: Text('90 days')),
                  ],
                  selected: {_days},
                  onSelectionChanged: (s) => setState(() => _days = s.first),
                ),
              ),
              const SizedBox(height: 16),
              FutureBuilder<Map<String, int>>(
                future: db.getEngagementSummary(_days),
                builder: (context, snapshot) {
                  final s =
                      snapshot.data ??
                      {
                        'translations': 0,
                        'activeUsers': 0,
                        'logins': 0,
                        'newUsers': 0,
                        'totalUsers': 0,
                        'inactiveUsers': 0,
                      };
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: tileWidth,
                        child: StatTile(
                          title: 'Translations',
                          value: '${s['translations']}',
                          icon: Icons.translate,
                          color: AppColors.primary,
                          subtitle: 'last $_days days',
                        ),
                      ),
                      SizedBox(
                        width: tileWidth,
                        child: StatTile(
                          title: 'Active users',
                          value: '${s['activeUsers']}',
                          icon: Icons.people_alt_outlined,
                          color: AppColors.secondary,
                          subtitle: 'of ${s['totalUsers']} total',
                        ),
                      ),
                      SizedBox(
                        width: tileWidth,
                        child: StatTile(
                          title: 'Sign-ins',
                          value: '${s['logins']}',
                          icon: Icons.login_outlined,
                          color: AppColors.accent,
                          subtitle: 'last $_days days',
                        ),
                      ),
                      SizedBox(
                        width: tileWidth,
                        child: StatTile(
                          title: 'New users',
                          value: '${s['newUsers']}',
                          icon: Icons.person_add_alt_outlined,
                          color: AppColors.warning,
                          subtitle: '${s['inactiveUsers']} deactivated',
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              ReportCard(
                title: 'Translation activity',
                subtitle: _days <= 31
                    ? 'Translations per day'
                    : 'Translations per week',
                child: FutureBuilder<Map<String, int>>(
                  future: db.getTranslationsByDay(_days),
                  builder: (context, snapshot) => ActivityBarChart(
                    byDay: snapshot.data ?? const {},
                    days: _days,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ReportCard(
                title: 'New users',
                subtitle: _days <= 31
                    ? 'Registrations per day'
                    : 'Registrations per week',
                child: FutureBuilder<Map<String, int>>(
                  future: db.getSignupsByDay(_days),
                  builder: (context, snapshot) => ActivityBarChart(
                    byDay: snapshot.data ?? const {},
                    days: _days,
                    color: AppColors.warning,
                    emptyLabel: 'No sign-ups in this period',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ReportCard(
                title: 'Recognition source',
                subtitle: 'Cloud vs on-device answers',
                child: FutureBuilder<Map<String, int>>(
                  future: db.getTranslationsBySource(_days),
                  builder: (context, snapshot) =>
                      BreakdownPie(data: snapshot.data ?? const {}),
                ),
              ),
              const SizedBox(height: 16),
              ReportCard(
                title: 'Input type',
                subtitle: 'Gesture, multi-sign and speech input',
                child: FutureBuilder<Map<String, int>>(
                  future: db.getTranslationsByType(_days),
                  builder: (context, snapshot) =>
                      BreakdownPie(data: snapshot.data ?? const {}),
                ),
              ),
              const SizedBox(height: 16),
              ReportCard(
                title: 'Top signs',
                subtitle: 'Most frequently translated inputs',
                child: FutureBuilder<List<Map<String, Object?>>>(
                  future: db.getTopSigns(_days),
                  builder: (context, snapshot) =>
                      RankedBars(rows: snapshot.data ?? const []),
                ),
              ),
              const SizedBox(height: 16),
              ReportCard(
                title: 'User engagement',
                subtitle: 'Per-user activity over the last $_days days',
                child: FutureBuilder<List<Map<String, Object?>>>(
                  future: db.getUserEngagement(_days),
                  builder: (context, snapshot) {
                    final rows = snapshot.data ?? const [];
                    if (rows.isEmpty) {
                      return Text(
                        'No users yet.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 13,
                        ),
                      );
                    }
                    return Column(children: rows.map(_engagementRow).toList());
                  },
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'System logs now live in the Logs tab of the admin dashboard. '
                'Use the export menu above for CSV downloads.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _engagementRow(Map<String, Object?> r) {
    final name = r['name'] as String? ?? '';
    final email = r['email'] as String? ?? '';
    final role = r['role'] as String? ?? 'user';
    final isActive = (r['is_active'] as int? ?? 1) == 1;
    final translations = (r['translations'] as num?)?.toInt() ?? 0;
    final logins = (r['logins'] as num?)?.toInt() ?? 0;
    final lastActive = r['last_active'] as String?;
    final joined = r['created_at'] as String?;

    String fmt(String? iso) {
      if (iso == null) return '—';
      final dt = DateTime.tryParse(iso);
      return dt == null ? '—' : DateFormat('d MMM, HH:mm').format(dt);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor:
                (role == 'admin' ? AppColors.accent : AppColors.primary)
                    .withValues(alpha: 0.15),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: role == 'admin' ? AppColors.accent : AppColors.primary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (!isActive)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text(
                          'deactivated',
                          style: TextStyle(
                            color: AppColors.error,
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
                Text(
                  email,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
                Text(
                  'Last active ${fmt(lastActive)} · joined ${fmt(joined)}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$translations',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'translations · $logins sign-ins',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, DbService db, String what) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getTemporaryDirectory();
      final content = switch (what) {
        'translations' => await _translationsCsv(db),
        'engagement' => await _engagementCsv(db),
        'users' => await _usersCsv(db),
        _ => await _logsCsv(db),
      };
      final file = File('${dir.path}/thandosign_${what}_export.csv');
      await file.writeAsString(content);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'ThandoSign $what export',
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<String> _translationsCsv(DbService db) async {
    final rows = await db.getAllTranslations(limit: 1000);
    final csv = StringBuffer(
      'id,user_id,type,gesture,english,confidence,source,created_at\n',
    );
    for (final r in rows) {
      csv.writeln(
        '${r.id},${r.userId},${r.inputType},${_csv(r.inputLabel)},${_csv(r.translatedText)},${r.confidence},${r.source},${r.createdAt.toIso8601String()}',
      );
    }
    return csv.toString();
  }

  Future<String> _engagementCsv(DbService db) async {
    final rows = await db.getUserEngagement(_days);
    final csv = StringBuffer(
      'name,email,role,active,translations,logins,last_active,joined\n',
    );
    for (final r in rows) {
      csv.writeln(
        '${_csv('${r['name']}')},${_csv('${r['email']}')},${r['role']},'
        '${(r['is_active'] as int? ?? 1) == 1},${r['translations']},'
        '${r['logins']},${r['last_active'] ?? ''},${r['created_at'] ?? ''}',
      );
    }
    return csv.toString();
  }

  Future<String> _usersCsv(DbService db) async {
    final users = await db.getUsers();
    final csv = StringBuffer('id,name,email,role,active,created_at\n');
    for (final u in users) {
      csv.writeln(
        '${u.id},${_csv(u.name)},${_csv(u.email)},${u.role},${u.isActive},${u.createdAt.toIso8601String()}',
      );
    }
    return csv.toString();
  }

  Future<String> _logsCsv(DbService db) async {
    final logs = await db.getSystemLogs(limit: 1000);
    final csv = StringBuffer('id,user_id,action,details,created_at\n');
    for (final l in logs) {
      csv.writeln(
        '${l['id']},${l['user_id']},${_csv(l['action'] as String? ?? '')},${_csv(l['details'] as String? ?? '')},${l['created_at']}',
      );
    }
    return csv.toString();
  }

  String _csv(String v) => '"${v.replaceAll('"', '""')}"';
}
