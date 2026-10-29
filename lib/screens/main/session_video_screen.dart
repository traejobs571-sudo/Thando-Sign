import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

/// Replays the compressed .mp4 saved from a conversation recording.
/// The clip is stored on-device only — it never syncs or leaves the
/// phone — so this screen simply plays the file back for review.
class SessionVideoScreen extends StatefulWidget {
  const SessionVideoScreen({super.key, required this.path});

  final String path;

  @override
  State<SessionVideoScreen> createState() => _SessionVideoScreenState();
}

class _SessionVideoScreenState extends State<SessionVideoScreen> {
  VideoPlayerController? _player;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final file = File(widget.path);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() => _error = 'Recording is no longer available.');
      return;
    }
    final player = VideoPlayerController.file(file);
    try {
      await player.initialize();
      await player.setLooping(true);
      await player.play();
    } catch (_) {
      await player.dispose();
      if (mounted) {
        setState(() => _error = 'Could not play this recording.');
      }
      return;
    }
    if (!mounted) {
      await player.dispose();
      return;
    }
    setState(() => _player = player);
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.dark),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Recorded session',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: player == null
                          ? Center(
                              child: _error != null
                                  ? Text(
                                      _error!,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                      textAlign: TextAlign.center,
                                    )
                                  : const CircularProgressIndicator(
                                      color: AppColors.primary,
                                    ),
                            )
                          : GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (player.value.isPlaying) {
                                  player.pause();
                                } else {
                                  player.play();
                                }
                              },
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Center(
                                    child: AspectRatio(
                                      aspectRatio: player.value.aspectRatio > 0
                                          ? player.value.aspectRatio
                                          : 16 / 9,
                                      child: VideoPlayer(player),
                                    ),
                                  ),
                                  ValueListenableBuilder<VideoPlayerValue>(
                                    valueListenable: player,
                                    builder: (context, value, _) {
                                      if (value.hasError) {
                                        return Text(
                                          value.errorDescription ??
                                              'Playback error occurred.',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                          textAlign: TextAlign.center,
                                        );
                                      }
                                      return value.isPlaying
                                          ? const SizedBox.shrink()
                                          : const Icon(
                                              Icons.play_circle_fill,
                                              size: 64,
                                              color: Colors.white70,
                                            );
                                    },
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                if (player != null) ...[
                  const SizedBox(height: 14),
                  ValueListenableBuilder(
                    valueListenable: player,
                    builder: (context, value, _) => Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: VideoProgressIndicator(
                            player,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: AppColors.primary,
                              bufferedColor: Colors.white24,
                              backgroundColor: Colors.white10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${_fmt(value.position)} / ${_fmt(value.duration)}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
