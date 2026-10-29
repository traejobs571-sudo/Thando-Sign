import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'dataset_tab.dart';
import 'logs_tab.dart';
import 'overview_tab.dart';
import 'reports_screen.dart';
import 'settings_tab.dart';
import 'users_tab.dart';

/// Admin dashboard: dataset, users, logs, settings and an overview,
/// organised as tabs. Reached from the home header or Profile for admins.
class AdminConsole extends StatelessWidget {
  const AdminConsole({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: AppGradients.dark),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Expanded(
                        child: Text(
                          'Admin Dashboard',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Reports & export',
                        icon: const Icon(
                          Icons.bar_chart_outlined,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ReportsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white54,
                  indicatorColor: AppColors.primary,
                  tabs: [
                    Tab(
                      icon: Icon(Icons.space_dashboard_outlined, size: 18),
                      text: 'Overview',
                    ),
                    Tab(
                      icon: Icon(Icons.back_hand_outlined, size: 18),
                      text: 'Dataset',
                    ),
                    Tab(
                      icon: Icon(Icons.people_outline, size: 18),
                      text: 'Users',
                    ),
                    Tab(
                      icon: Icon(Icons.receipt_long_outlined, size: 18),
                      text: 'Logs',
                    ),
                    Tab(
                      icon: Icon(Icons.settings_outlined, size: 18),
                      text: 'Settings',
                    ),
                  ],
                ),
                const Expanded(
                  child: TabBarView(
                    children: [
                      OverviewTab(),
                      DatasetTab(),
                      UsersTab(),
                      LogsTab(),
                      AdminSettingsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
