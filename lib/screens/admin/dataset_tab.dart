import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/gesture_item.dart';
import '../../services/db_service.dart';
import '../../services/gesture_image_service.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/validators.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/hand_landmark.dart';
import 'sample_capture_screen.dart';

/// Gesture dataset management: search, add, edit, enable/disable,
/// per-gesture sample capture, delete.
class DatasetTab extends StatefulWidget {
  const DatasetTab({super.key});

  @override
  State<DatasetTab> createState() => _DatasetTabState();
}

class _DatasetTabState extends State<DatasetTab> {
  List<GestureItem> _gestures = [];
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

  // Realtime pushes bump lastRemoteChangeAt — reload the dataset so
  // changes made on another device (or in the Supabase dashboard)
  // appear without a manual refresh.
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
    final gestures = await context.read<DbService>().getGestures(
      activeOnly: false,
    );
    if (mounted) {
      setState(() {
        _gestures = gestures;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _gestures
        .where(
          (g) =>
              _search.isEmpty ||
              g.label.toLowerCase().contains(_search) ||
              g.category.toLowerCase().contains(_search),
        )
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Gesture dataset (${filtered.length}/${_gestures.length})',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showGestureDialog(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search gestures…',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
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
                    'No gestures match.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: filtered.map(_gestureTile).toList(),
                ),
        ),
      ],
    );
  }

  Widget _gestureTile(GestureItem g) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            _GestureThumb(gesture: g),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    g.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${g.meaning} • ${g.category}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: g.isActive,
              activeThumbColor: AppColors.primary,
              onChanged: (v) async {
                await context.read<DbService>().updateGestureStatus(g.id!, v);
                _load();
              },
            ),
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                color: Colors.white.withValues(alpha: 0.6),
                size: 20,
              ),
              color: AppColors.surfaceVariant,
              onSelected: (action) async {
                if (action == 'samples') {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SampleCaptureScreen(label: g.label),
                    ),
                  );
                } else if (action == 'edit') {
                  await _showGestureDialog(existing: g);
                } else if (action == 'regenerate') {
                  await context.read<GestureImageService>().regenerate(g);
                } else if (action == 'upload') {
                  await _pickGestureImage(g);
                } else if (action == 'delete') {
                  await _confirmDelete(g);
                }
                _load();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(
                  value: 'samples',
                  child: Text('Collect sign samples'),
                ),
                PopupMenuItem(value: 'upload', child: Text('Upload image')),
                PopupMenuItem(
                  value: 'regenerate',
                  child: Text('Regenerate image'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Delete',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Lets the admin attach any image from the device (downloaded sign
  /// illustration, dictionary photo…) — stored locally, shared via the
  /// gesture-images bucket when signed in.
  Future<void> _pickGestureImage(GestureItem g) async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Sign image',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    final file = await context.read<GestureImageService>().setImage(g, bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            file != null
                ? 'Image set for ${g.label}'
                : 'Could not set the image',
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(GestureItem g) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete gesture?'),
        content: Text(
          'Remove "${g.label}" from the dataset? The sign will stop '
          'being recognised.',
        ),
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
    if (confirmed == true && mounted) {
      await context.read<DbService>().deleteGesture(g.id!);
    }
  }

  /// Add or edit dialog — validation errors render inside the dialog so
  /// invalid input always produces a visible message.
  Future<void> _showGestureDialog({GestureItem? existing}) async {
    final label = TextEditingController(text: existing?.label ?? '');
    final meaning = TextEditingController(text: existing?.meaning ?? '');
    final category = TextEditingController(text: existing?.category ?? '');
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add ZSL gesture' : 'Edit gesture'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: label,
                decoration: const InputDecoration(
                  labelText: 'Label (e.g. Hello)',
                ),
              ),
              TextField(
                controller: meaning,
                decoration: const InputDecoration(labelText: 'Meaning'),
              ),
              TextField(
                controller: category,
                decoration: const InputDecoration(labelText: 'Category'),
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
                final labelError = Validators.required(label.text, 'Label');
                final meaningError = Validators.required(
                  meaning.text,
                  'Meaning',
                );
                if (labelError != null || meaningError != null) {
                  setDialogState(() => error = labelError ?? meaningError);
                  return;
                }
                try {
                  final db = context.read<DbService>();
                  if (existing == null) {
                    await db.addGesture(
                      label.text,
                      meaning.text,
                      category.text,
                    );
                  } else {
                    await db.updateGesture(
                      existing.id!,
                      label.text,
                      meaning.text,
                      category.text,
                    );
                  }
                  if (context.mounted) Navigator.pop(context, true);
                } on StateError catch (e) {
                  setDialogState(() => error = e.message);
                }
              },
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );

    label.dispose();
    meaning.dispose();
    category.dispose();
    if (saved == true) _load();
  }
}

/// Row thumbnail — shows the gesture's illustration, resolving
/// (downloading or generating) it on demand via [GestureImageService].
/// Falls back to the captured hand-skeleton sample — always offline —
/// then to a hand icon.
class _GestureThumb extends StatelessWidget {
  const _GestureThumb({required this.gesture});

  final GestureItem gesture;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 40,
        height: 40,
        child: FutureBuilder<File?>(
          future: context
              .read<GestureImageService>()
              .ensureImage(gesture)
              .timeout(const Duration(seconds: 15), onTimeout: () => null),
          builder: (context, snap) {
            final file = snap.data;
            if (file != null) {
              return Image.file(file, fit: BoxFit.cover);
            }
            final asset = signAssetFor(gesture.label);
            return Container(
              color: AppColors.secondary.withValues(alpha: 0.15),
              child: asset != null
                  ? Image.asset(asset, fit: BoxFit.contain)
                  : FutureBuilder<List<double>?>(
                      future: context.read<DbService>().getSampleLandmarks(
                        gesture.label,
                      ),
                      builder: (_, s) {
                        if (s.data != null) {
                          return LandmarkHand(landmarks: s.data!);
                        }
                        final glyph = signGlyphFor(gesture.label);
                        return glyph != null
                            ? Text(glyph, style: const TextStyle(fontSize: 20))
                            : const Icon(
                                Icons.back_hand_outlined,
                                color: AppColors.secondary,
                                size: 18,
                              );
                      },
                    ),
            );
          },
        ),
      ),
    );
  }
}
