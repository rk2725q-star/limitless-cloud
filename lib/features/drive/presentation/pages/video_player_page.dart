import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';

/// Full-featured built-in video player with controls overlay.
class VideoPlayerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const VideoPlayerPage({super.key, required this.args});

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  CloudFile get _file => widget.args['file'] as CloudFile;

  bool _loading = true;
  bool _error = false;
  VideoPlayerController? _controller;
  bool _playing = false;
  bool _controlsVisible = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _loadVideo() async {
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final telegramService = TelegramStorageService(authService);
      final f = await telegramService.downloadFile(_file.telegramMessageId, _file.name);
      if (!mounted) return;

      final ctrl = VideoPlayerController.file(f);
      await ctrl.initialize();

      ctrl.addListener(() {
        if (!mounted) return;
        setState(() {
          _playing = ctrl.value.isPlaying;
          _position = ctrl.value.position;
          _duration = ctrl.value.duration;
        });
      });

      setState(() {
        _controller = ctrl;
        _loading = false;
      });

      // Auto-play
      await ctrl.play();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_playing) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  double get _progress {
    if (_duration.inMilliseconds == 0) return 0.0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          children: [
            // ── Video frame ────────────────────────────────────────────────
            Center(
              child: _loading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : _error
                      ? _buildError()
                      : _controller != null
                          ? AspectRatio(
                              aspectRatio: _controller!.value.aspectRatio,
                              child: VideoPlayer(_controller!),
                            )
                          : const SizedBox.shrink(),
            ),

            // ── Controls overlay ───────────────────────────────────────────
            if (_controlsVisible && !_loading && !_error && _controller != null)
              AnimatedOpacity(
                opacity: _controlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: _buildControls(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.videocam_off_rounded, color: Colors.white30, size: 80),
      const SizedBox(height: 16),
      const Text('Could not load video', style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 16),
      ElevatedButton.icon(
        onPressed: () { setState(() { _loading = true; _error = false; }); _loadVideo(); },
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Retry'),
        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
      ),
    ]);
  }

  Widget _buildControls() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent, Colors.transparent, Colors.black87],
          stops: [0.0, 0.2, 0.7, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      _file.name,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.download_rounded, color: Colors.white),
                    onPressed: () => ref.read(driveProvider.notifier).downloadFile(_file, onProgress: (_) {}),
                  ),
                ],
              ),
            ),

            const Spacer(),

            // ── Center play/pause button ──────────────────────────────────
            GestureDetector(
              onTap: _togglePlay,
              child: Container(
                width: 72, height: 72,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black54,
                ),
                child: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 44,
                ),
              ),
            ),

            const Spacer(),

            // ── Bottom controls ───────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                children: [
                  // Progress slider
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      activeTrackColor: AppTheme.primary,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: AppTheme.primary,
                      overlayColor: AppTheme.primary.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: _progress,
                      onChanged: (v) {
                        final pos = Duration(
                            milliseconds: (v * _duration.inMilliseconds).toInt());
                        _controller!.seekTo(pos);
                      },
                    ),
                  ),
                  // Time row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmtDuration(_position),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      // Speed / info
                      Text(
                        FileUtils.formatFileSize(_file.sizeBytes),
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      Text(_fmtDuration(_duration),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Control row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.replay_10_rounded, color: Colors.white70, size: 28),
                        onPressed: () => _controller!.seekTo(Duration(
                            milliseconds: (_position.inMilliseconds - 10000).clamp(0, _duration.inMilliseconds))),
                      ),
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: _togglePlay,
                        child: Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.primary.withValues(alpha: 0.9),
                          ),
                          child: Icon(
                            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.forward_10_rounded, color: Colors.white70, size: 28),
                        onPressed: () => _controller!.seekTo(Duration(
                            milliseconds: (_position.inMilliseconds + 10000).clamp(0, _duration.inMilliseconds))),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
