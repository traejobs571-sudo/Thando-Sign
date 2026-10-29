import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/app_theme.dart';
import 'glass_card.dart';

/// Shared palette so every chart on the reports screen stays consistent.
const reportPalette = [
  AppColors.primary,
  AppColors.secondary,
  AppColors.accent,
  AppColors.warning,
  AppColors.error,
  Colors.purple,
  Colors.cyan,
  Colors.pink,
];

/// Card wrapper with a title row used by every report chart.
class ReportCard extends StatelessWidget {
  const ReportCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Bar chart of per-day counts. When [days] exceeds a month the values are
/// rolled up into weekly buckets so the bars stay readable.
class ActivityBarChart extends StatelessWidget {
  const ActivityBarChart({
    super.key,
    required this.byDay,
    required this.days,
    this.color = AppColors.primary,
    this.emptyLabel = 'No activity in this period',
  });

  /// 'YYYY-MM-DD' → count.
  final Map<String, int> byDay;
  final int days;
  final Color color;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final buckets = _buckets();
    final total = buckets.fold<int>(0, (s, b) => s + b.value);
    if (total == 0) {
      return _Empty(label: emptyLabel);
    }
    final maxY = (buckets.map((b) => b.value).fold<int>(0, (a, b) => b > a ? b : a)).toDouble();

    return SizedBox(
      height: 180,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxY * 1.2,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: const AxisTitles(),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= buckets.length) {
                    return const SizedBox.shrink();
                  }
                  // Only label a handful of bars to avoid crowding.
                  final step = (buckets.length / 6).ceil();
                  if (i % step != 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      buckets[i].label,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 10,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                return BarTooltipItem(
                  '${buckets[group.x].label}: ${rod.toY.round()}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < buckets.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: buckets[i].value.toDouble(),
                    color: color,
                    width: days <= 7 ? 22 : (days <= 31 ? 8 : 14),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  List<_Bucket> _buckets() {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: days - 1));
    final fmt = DateFormat('d/M');
    final key = DateFormat('yyyy-MM-dd');

    if (days <= 31) {
      return [
        for (var i = 0; i < days; i++)
          _Bucket(
            label: fmt.format(start.add(Duration(days: i))),
            value: byDay[key.format(start.add(Duration(days: i)))] ?? 0,
          ),
      ];
    }

    // Weekly buckets, aligned to Monday.
    final buckets = <_Bucket>[];
    var cursor = start.subtract(Duration(days: (start.weekday - 1) % 7));
    while (!cursor.isAfter(today)) {
      var sum = 0;
      for (var i = 0; i < 7; i++) {
        sum += byDay[key.format(cursor.add(Duration(days: i)))] ?? 0;
      }
      buckets.add(_Bucket(label: fmt.format(cursor), value: sum));
      cursor = cursor.add(const Duration(days: 7));
    }
    return buckets;
  }
}

class _Bucket {
  const _Bucket({required this.label, required this.value});
  final String label;
  final int value;
}

/// Donut chart with a legend for categorical breakdowns.
class BreakdownPie extends StatelessWidget {
  const BreakdownPie({super.key, required this.data, this.emptyLabel});

  final Map<String, int> data;
  final String? emptyLabel;

  @override
  Widget build(BuildContext context) {
    final entries = data.entries.where((e) => e.value > 0).toList();
    if (entries.isEmpty) {
      return _Empty(label: emptyLabel ?? 'No data in this period');
    }
    final total = entries.fold<int>(0, (s, e) => s + e.value);

    return Row(
      children: [
        SizedBox(
          width: 140,
          height: 140,
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 30,
              sections: [
                for (var i = 0; i < entries.length; i++)
                  PieChartSectionData(
                    value: entries[i].value.toDouble(),
                    color: reportPalette[i % reportPalette.length],
                    radius: 34,
                    title:
                        '${(entries[i].value / total * 100).toStringAsFixed(0)}%',
                    titleStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < entries.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: reportPalette[i % reportPalette.length],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entries[i].key,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        '${entries[i].value}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Ranked label/value rows with proportional bars — used for top signs.
class RankedBars extends StatelessWidget {
  const RankedBars({super.key, required this.rows, this.emptyLabel});

  /// Rows shaped like {'label': String, 'c': int} from getTopSigns.
  final List<Map<String, Object?>> rows;
  final String? emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _Empty(label: emptyLabel ?? 'No data in this period');
    }
    final max = rows
        .map((r) => (r['c'] as num).toInt())
        .fold<int>(0, (a, b) => b > a ? b : a);

    return Column(
      children: [
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Text(
                    rows[i]['label'] as String? ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: max == 0
                          ? 0
                          : (rows[i]['c'] as num).toInt() / max,
                      minHeight: 8,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation(
                        reportPalette[i % reportPalette.length],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(rows[i]['c'] as num).toInt()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
