import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../controllers/translation_controller.dart';
import '../../widgets/glass_card.dart';
import '../../theme/app_theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TranslationController>().loadHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TranslationController>();
    final items = controller.history;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.dark),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Text('History', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('Your recent translations', style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text('No translations yet.\nCapture a gesture to see it here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), height: 1.5)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 130),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final t = items[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: GlassCard(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: AppColors.secondary.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(Icons.translate, color: AppColors.secondary),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(t.translatedText,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                                        const SizedBox(height: 3),
                                        Text('Gesture: ${t.inputLabel}',
                                            style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text('${(t.confidence * 100).toStringAsFixed(0)}%',
                                            style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold)),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(DateFormat('MMM d, HH:mm').format(t.createdAt),
                                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 10)),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
