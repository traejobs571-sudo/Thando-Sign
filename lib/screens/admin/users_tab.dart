import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/user.dart';
import '../../services/auth_service.dart';
import '../../services/db_service.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

/// User account management: search, activate/deactivate, promote/demote,
/// reset password, delete.
class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  List<User> _users = [];
  bool _loading = true;
  String _search = '';
  SyncService? _sync;
  DateTime? _lastRemoteSeen;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sync = context.read<SyncService>();
      _lastRemoteSeen = _sync!.lastRemoteChangeAt;
      _sync!.addListener(_onSyncTick);
    });
  }

  // Profiles pulled down by a sync bump lastRemoteChangeAt — reload so
  // users registered on other devices appear without a manual refresh.
  void _onSyncTick() {
    if (!mounted || _sync?.lastRemoteChangeAt == _lastRemoteSeen) return;
    _lastRemoteSeen = _sync?.lastRemoteChangeAt;
    _load();
  }

  @override
  void dispose() {
    _sync?.removeListener(_onSyncTick);
    super.dispose();
  }

  Future<void> _load() async {
    final users = await context.read<DbService>().getUsers();
    if (mounted) {
      setState(() {
        _users = users;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _users
        .where(
          (u) =>
              _search.isEmpty ||
              u.name.toLowerCase().contains(_search) ||
              u.email.toLowerCase().contains(_search),
        )
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Users (${filtered.length}/${_users.length})',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search users…',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) =>
                setState(() => _search = v.trim().toLowerCase()),
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
                    'No users match.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: filtered.map(_userTile).toList(),
                ),
        ),
      ],
    );
  }

  Widget _userTile(User u) {
    final self = context.read<AuthService>().currentUser;
    final isSelf = self?.id == u.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.primary.withValues(alpha: 0.15),
              child: Text(
                u.name.isNotEmpty ? u.name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    u.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    u.email,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                  if (!u.isActive)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        'Deactivated',
                        style: TextStyle(
                          color: AppColors.error,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else if (u.passwordHash == DbService.remoteOnlyPasswordHash)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Cloud account — hasn\'t signed in here yet',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color:
                    (u.role == 'admin' ? AppColors.accent : AppColors.secondary)
                        .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                u.role,
                style: TextStyle(
                  color: u.role == 'admin'
                      ? AppColors.accent
                      : AppColors.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!isSelf)
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert,
                  color: Colors.white.withValues(alpha: 0.6),
                  size: 20,
                ),
                color: AppColors.surfaceVariant,
                onSelected: (action) => _userAction(u, action),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'toggle_active',
                    child: Text(u.isActive ? 'Deactivate' : 'Reactivate'),
                  ),
                  PopupMenuItem(
                    value: 'toggle_role',
                    child: Text(
                      u.role == 'admin' ? 'Demote to user' : 'Promote to admin',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'reset_password',
                    child: Text('Reset password'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Delete',
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                ],
              )
            else
              const SizedBox(width: 40),
          ],
        ),
      ),
    );
  }

  Future<void> _userAction(User u, String action) async {
    final db = context.read<DbService>();
    switch (action) {
      case 'toggle_active':
        await db.updateUserStatus(u.id!, !u.isActive);
      case 'toggle_role':
        await db.updateUserRole(u.id!, u.role == 'admin' ? 'user' : 'admin');
      case 'reset_password':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Reset password?'),
            content: Text(
              'A temporary password will be generated for ${u.name}. '
              'They must change it at next sign-in.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Reset'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          final temp = await db.resetUserPassword(u.id!);
          if (mounted) {
            await showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Temporary password'),
                content: SelectableText(
                  'Share this password with ${u.name}:\n\n'
                  '$temp\n\n'
                  'They will be asked to set a new password at next sign-in.',
                ),
                actions: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: temp));
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            );
          }
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete user?'),
            content: Text('Permanently remove ${u.name} (${u.email})?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await db.deleteUser(u.id!);
        }
    }
    if (mounted) _load();
  }
}
