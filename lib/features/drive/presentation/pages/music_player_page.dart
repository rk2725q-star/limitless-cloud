import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';

class MusicPlayerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const MusicPlayerPage({super.key, required this.args});

  @override
  ConsumerState<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends ConsumerState<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  CloudFile get _file => widget.args['file'] as CloudFile;

  final _player = AudioPlayer();
  bool _loading = true;
  bool _error = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  late AnimationController _discController;

  @override
  void initState() {
    super.initState();
    _discController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
    _discController.stop();

    _player.onPlayerStateChanged.listen((s) {
      if (mounted) {
        setState(() => _playing = s == PlayerState.playing);
        if (s == PlayerState.playing) {
          _discController.repeat();
        } else {
          _discController.stop();
        }
      }
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() { _playing = false; _position = Duration.zero; });
        _discController.stop();
        _discController.reset();
      }
    });

    _loadAndPlay();
  }

  @override
  void dispose() {
    _player.dispose();
    _discController.dispose();
    super.dispose();
  }

  Future<void> _loadAndPlay() async {
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final telegramService = TelegramStorageService(authService);
      final f = await telegramService.downloadFile(_file.telegramMessageId, _file.name);
      if (!mounted) return;
      setState(() { _loading = false; });
      await _player.setSourceDeviceFile(f.path);
      await _player.resume();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  void _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.resume();
    }
  }

  void _seekTo(double value) {
    final pos = Duration(milliseconds: (value * _duration.inMilliseconds).toInt());
    _player.seek(pos);
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(_file.extension);
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Music Player', style: TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: Icon(_file.isStarred ? Icons.star_rounded : Icons.star_border_rounded,
                color: AppTheme.warning),
            onPressed: () => ref.read(driveProvider.notifier).toggleStar(_file),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? _buildError()
              : _buildPlayer(color, progress),
    );
  }

  Widget _buildError() {
    return const Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline_rounded, color: AppTheme.error, size: 64),
        SizedBox(height: 16),
        Text('Could not load audio', style: TextStyle(color: Colors.white70)),
      ]),
    );
  }

  Widget _buildPlayer(Color color, double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),

          // ── Animated disc ───────────────────────────────────────────────
          RotationTransition(
            turns: _discController,
            child: Container(
              width: 220, height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    color.withValues(alpha: 0.3),
                    const Color(0xFF1A1A2E),
                    const Color(0xFF0A0A0F),
                  ],
                  stops: const [0.0, 0.6, 1.0],
                ),
                border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.3),
                    blurRadius: 40,
                    spreadRadius: 10,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(Icons.music_note_rounded, color: color, size: 80),
                  // Center hole
                  Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0A0A0F),
                      border: Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const Spacer(),

          // ── Song info ──────────────────────────────────────────────────
          Text(
            _file.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            '${_file.extension.toUpperCase()} · ${FileUtils.formatFileSize(_file.sizeBytes)}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
          ),

          const Spacer(),

          // ── Progress bar ───────────────────────────────────────────────
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: color,
              inactiveTrackColor: Colors.white12,
              thumbColor: color,
              overlayColor: color.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: progress.clamp(0.0, 1.0),
              onChanged: _seekTo,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmtDuration(_position),
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
                Text(_fmtDuration(_duration),
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // ── Controls ────────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Volume
              IconButton(
                icon: Icon(
                  _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  color: Colors.white54,
                ),
                onPressed: () {
                  setState(() => _volume = _volume == 0 ? 1.0 : 0.0);
                  _player.setVolume(_volume);
                },
              ),
              const Spacer(),
              // Rewind 10s
              IconButton(
                icon: const Icon(Icons.replay_10_rounded, color: Colors.white70, size: 32),
                onPressed: () => _player.seek(Duration(
                    milliseconds: (_position.inMilliseconds - 10000).clamp(0, _duration.inMilliseconds))),
              ),
              const SizedBox(width: 16),
              // Play/Pause
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 68, height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [color, color.withValues(alpha: 0.7)],
                    ),
                    boxShadow: [
                      BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 20, spreadRadius: 2),
                    ],
                  ),
                  child: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Forward 10s
              IconButton(
                icon: const Icon(Icons.forward_10_rounded, color: Colors.white70, size: 32),
                onPressed: () => _player.seek(Duration(
                    milliseconds: (_position.inMilliseconds + 10000).clamp(0, _duration.inMilliseconds))),
              ),
              const Spacer(),
              // Download
              IconButton(
                icon: const Icon(Icons.download_rounded, color: Colors.white54),
                onPressed: () => ref.read(driveProvider.notifier).downloadFile(_file, onProgress: (_) {}),
              ),
            ],
          ),

          const Spacer(flex: 2),
        ],
      ),
    );
  }
}
