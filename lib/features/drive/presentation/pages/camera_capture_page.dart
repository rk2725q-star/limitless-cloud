import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../../core/theme/app_theme.dart';
import '../providers/drive_provider.dart';

// ── Resolution definitions ────────────────────────────────────────────────────
//
//  ResolutionPreset mapping (Flutter camera package):
//    high      → 720p  (HD)
//    veryHigh  → 1080p (FHD)
//    ultraHigh → 1440p on most devices (2K), falls to 4K on flagships
//    max       → highest supported — 4K/UHD on flagship hardware
//
//  The camera package gracefully falls back to the next lower preset when the
//  device doesn't support the requested one, so requesting "max" on an FHD-only
//  device still works (it just gives FHD).

class _ResOption {
  final String label;
  final String sublabel; // e.g. "1080p" shown in mini badge
  final ResolutionPreset preset;
  const _ResOption(this.label, this.sublabel, this.preset);
}

const List<_ResOption> _resOptions = [
  _ResOption('HD',  '720p',  ResolutionPreset.high),
  _ResOption('FHD', '1080p', ResolutionPreset.veryHigh),
  _ResOption('2K',  '1440p', ResolutionPreset.ultraHigh),
  _ResOption('4K',  '2160p', ResolutionPreset.max),
];

// Default: FHD
const int _defaultResIndex = 1; // FHD

// ── Entry point ────────────────────────────────────────────────────────────────

/// Open the in-app camera.  On confirm, auto-uploads to Telegram then
/// deletes the local copy — freeing device storage immediately.
Future<void> openCameraCapture(
  BuildContext context, {
  String? folderId,
  String folderPath = '/',
}) async {
  // Camera + microphone permission
  final camStatus = await Permission.camera.request();
  await Permission.microphone.request(); // mic denied → video without audio, still OK
  if (!camStatus.isGranted) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera permission denied. Enable it in Settings.'),
          backgroundColor: Colors.red,
        ),
      );
    }
    return;
  }

  List<CameraDescription> cameras;
  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = [];
  }

  if (cameras.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No camera available on this device.')),
      );
    }
    return;
  }

  if (!context.mounted) return;

  await Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CameraCapturePage(
        cameras: cameras,
        folderId: folderId,
        folderPath: folderPath,
      ),
    ),
  );
}

// ── Camera Page ────────────────────────────────────────────────────────────────

class CameraCapturePage extends ConsumerStatefulWidget {
  final List<CameraDescription> cameras;
  final String? folderId;
  final String folderPath;

  const CameraCapturePage({
    super.key,
    required this.cameras,
    this.folderId,
    this.folderPath = '/',
  });

  @override
  ConsumerState<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends ConsumerState<CameraCapturePage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  int _cameraIndex = 0;
  int _resIndex    = _defaultResIndex;   // index into _resOptions
  bool _isVideo    = false;
  bool _isRecording = false;
  bool _isBusy     = false;
  bool _isChangingRes = false;           // shows brief "switching…" overlay
  FlashMode _flashMode = FlashMode.auto;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;

  // Zoom
  double _minZoom = 1.0;
  double _maxZoom = 8.0;
  double _currentZoom = 1.0;
  double _baseZoom    = 1.0;

  // Preview state
  File? _previewFile;
  bool _previewIsVideo = false;

  _ResOption get _res => _resOptions[_resIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCamera(widget.cameras[0]);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(widget.cameras[_cameraIndex]);
    }
  }

  // ── Camera init ──────────────────────────────────────────────────────────────

  Future<void> _initCamera(CameraDescription desc, {bool showSwitching = false}) async {
    if (showSwitching && mounted) setState(() => _isChangingRes = true);

    final prev = _controller;
    if (prev != null) {
      await prev.dispose();
      _controller = null;
    }

    final ctrl = CameraController(
      desc,
      _res.preset,          // ← uses selected resolution
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = ctrl;

    try {
      await ctrl.initialize();
      await ctrl.setFlashMode(_flashMode);
      _minZoom = await ctrl.getMinZoomLevel();
      _maxZoom = await ctrl.getMaxZoomLevel();
      _currentZoom = _minZoom.clamp(1.0, _maxZoom);
      _baseZoom    = _currentZoom;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e')),
        );
      }
    }
    if (mounted) setState(() => _isChangingRes = false);
  }

  // ── Resolution change ────────────────────────────────────────────────────────

  Future<void> _changeResolution(int idx) async {
    if (idx == _resIndex) return;
    if (_isRecording) return; // can't switch while recording
    _resIndex = idx;
    await _initCamera(widget.cameras[_cameraIndex], showSwitching: true);
  }

  // ── Camera flip ──────────────────────────────────────────────────────────────

  Future<void> _flipCamera() async {
    if (widget.cameras.length < 2 || _isRecording) return;
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    await _initCamera(widget.cameras[_cameraIndex], showSwitching: true);
  }

  // ── Flash ────────────────────────────────────────────────────────────────────

  Future<void> _cycleFlash() async {
    if (_isVideo && _isRecording) return;
    final modes = [FlashMode.auto, FlashMode.always, FlashMode.off, FlashMode.torch];
    final idx = modes.indexOf(_flashMode);
    _flashMode = modes[(idx + 1) % modes.length];
    try { await _controller?.setFlashMode(_flashMode); } catch (_) {}
    if (mounted) setState(() {});
  }

  IconData get _flashIcon {
    switch (_flashMode) {
      case FlashMode.always: return Icons.flash_on_rounded;
      case FlashMode.off:    return Icons.flash_off_rounded;
      case FlashMode.torch:  return Icons.highlight_rounded;
      default:               return Icons.flash_auto_rounded;
    }
  }

  // ── Zoom ─────────────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails _) {
    _baseZoom = _currentZoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    _currentZoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);
    try { await ctrl.setZoomLevel(_currentZoom); } catch (_) {}
    if (mounted) setState(() {});
  }

  // ── Capture ──────────────────────────────────────────────────────────────────

  Future<void> _capturePhoto() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isBusy || _isChangingRes) return;
    setState(() => _isBusy = true);
    try {
      final xfile = await ctrl.takePicture();
      if (mounted) {
        setState(() {
          _previewFile    = File(xfile.path);
          _previewIsVideo = false;
          _isBusy         = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  Future<void> _startVideo() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isBusy || _isChangingRes) return;
    try {
      await ctrl.startVideoRecording();
      _recordDuration = Duration.zero;
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordDuration += const Duration(seconds: 1));
      });
      if (mounted) setState(() => _isRecording = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recording failed: $e')),
        );
      }
    }
  }

  Future<void> _stopVideo() async {
    final ctrl = _controller;
    if (ctrl == null || !_isRecording) return;
    _recordTimer?.cancel();
    setState(() => _isBusy = true);
    try {
      final xfile = await ctrl.stopVideoRecording();
      if (mounted) {
        setState(() {
          _isRecording    = false;
          _previewFile    = File(xfile.path);
          _previewIsVideo = true;
          _isBusy         = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isRecording = false; _isBusy = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stop recording failed: $e')),
        );
      }
    }
  }

  // ── Confirm / Retake ─────────────────────────────────────────────────────────

  void _retake() {
    try { _previewFile?.deleteSync(); } catch (_) {}
    setState(() { _previewFile = null; });
  }

  Future<void> _confirmAndUpload() async {
    final file = _previewFile;
    if (file == null) return;

    final tmpDir  = await getTemporaryDirectory();
    final now     = DateTime.now();
    final y       = now.year.toString().padLeft(4, '0');
    final m       = now.month.toString().padLeft(2, '0');
    final d       = now.day.toString().padLeft(2, '0');
    final hr      = now.hour.toString().padLeft(2, '0');
    final min     = now.minute.toString().padLeft(2, '0');
    final sec     = now.second.toString().padLeft(2, '0');
    final dateStr = '$y$m${d}_$hr$min$sec';
    final resLabel = _res.label; // e.g. "FHD"
    final fileName = _previewIsVideo
        ? 'VID_${dateStr}_$resLabel.mp4'
        : 'IMG_${dateStr}_$resLabel.jpg';
    final destPath = p.join(tmpDir.path, fileName);

    File dest;
    try {
      dest = await file.copy(destPath);
      await file.delete();
    } catch (_) {
      dest = file;
    }

    if (!mounted) return;
    Navigator.of(context).pop();

    await ref.read(driveProvider.notifier).uploadCapturedFile(
      file: dest,
      fileName: fileName,
      folderId: widget.folderId,
      folderPath: widget.folderPath,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ctrl == null || !ctrl.value.isInitialized)
            const Center(child: CircularProgressIndicator(color: Colors.white))
          else if (_previewFile != null)
            _PreviewView(
              file: _previewFile!,
              isVideo: _previewIsVideo,
              resLabel: _res.label,
              onRetake: _retake,
              onConfirm: _confirmAndUpload,
            )
          else ...[
            // ── Fullscreen viewfinder with pinch-zoom ──────────────────────
            GestureDetector(
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              child: SizedBox.expand(
                child: CameraPreview(ctrl),
              ),
            ),

            // ── Resolution switching overlay ───────────────────────────────
            if (_isChangingRes)
              Container(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 16),
                      Text(
                        'Switching to ${_res.label} (${_res.sublabel})…',
                        style: const TextStyle(color: Colors.white70, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Top bar ────────────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      _IconBtn(icon: Icons.close_rounded, onTap: () => Navigator.of(context).pop()),
                      const Spacer(),
                      if (_isRecording)
                        _RecordingBadge(duration: _recordDuration)
                      else ...[
                        _IconBtn(icon: _flashIcon, onTap: _cycleFlash),
                        const SizedBox(width: 10),
                        if (widget.cameras.length > 1)
                          _IconBtn(icon: Icons.flip_camera_android_rounded, onTap: _flipCamera),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            // ── Zoom level badge (left side) ───────────────────────────────
            Positioned(
              left: 16,
              bottom: 240,
              child: _ZoomBadge(zoom: _currentZoom),
            ),

            // ── Bottom controls ────────────────────────────────────────────
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: SafeArea(
                child: _BottomControls(
                  isVideo: _isVideo,
                  isRecording: _isRecording,
                  isBusy: _isBusy || _isChangingRes,
                  resOptions: _resOptions,
                  selectedResIndex: _resIndex,
                  onResChange: _changeResolution,
                  onToggleMode: _isRecording ? null : () => setState(() => _isVideo = !_isVideo),
                  onShutter: _isVideo
                      ? (_isRecording ? _stopVideo : _startVideo)
                      : _capturePhoto,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Bottom Controls ───────────────────────────────────────────────────────────

class _BottomControls extends StatelessWidget {
  final bool isVideo;
  final bool isRecording;
  final bool isBusy;
  final List<_ResOption> resOptions;
  final int selectedResIndex;
  final ValueChanged<int> onResChange;
  final VoidCallback? onToggleMode;
  final VoidCallback onShutter;

  const _BottomControls({
    required this.isVideo,
    required this.isRecording,
    required this.isBusy,
    required this.resOptions,
    required this.selectedResIndex,
    required this.onResChange,
    required this.onToggleMode,
    required this.onShutter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Frosted dark gradient
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xDD000000), Color(0x00000000)],
          stops: [0.0, 1.0],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Resolution selector ─────────────────────────────────────────
          if (!isRecording) ...[
            _ResolutionBar(
              options: resOptions,
              selectedIndex: selectedResIndex,
              onSelect: onResChange,
            ),
            const SizedBox(height: 18),
          ],

          // ── Mode toggle ─────────────────────────────────────────────────
          if (!isRecording && onToggleMode != null) ...[
            _ModeToggle(isVideo: isVideo, onToggle: onToggleMode!),
            const SizedBox(height: 24),
          ] else ...[
            const SizedBox(height: 8),
          ],

          // ── Shutter row ─────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ShutterButton(
                isVideo: isVideo,
                isRecording: isRecording,
                isBusy: isBusy,
                onTap: onShutter,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Resolution Bar ────────────────────────────────────────────────────────────

class _ResolutionBar extends StatelessWidget {
  final List<_ResOption> options;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _ResolutionBar({
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(options.length, (i) {
        final opt      = options[i];
        final selected = i == selectedIndex;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GestureDetector(
            onTap: () => onSelect(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.3),
                  width: 1.2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    opt.label,
                    style: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    opt.sublabel,
                    style: TextStyle(
                      color: selected
                          ? Colors.black54
                          : Colors.white.withValues(alpha: 0.5),
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ── Preview / Confirm View ─────────────────────────────────────────────────────

class _PreviewView extends StatelessWidget {
  final File file;
  final bool isVideo;
  final String resLabel;
  final VoidCallback onRetake;
  final VoidCallback onConfirm;

  const _PreviewView({
    required this.file,
    required this.isVideo,
    required this.resLabel,
    required this.onRetake,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Preview content
        isVideo
            ? _VideoThumbnail(file: file, resLabel: resLabel)
            : Image.file(file, fit: BoxFit.contain),

        // Top bar
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _IconBtn(icon: Icons.arrow_back_rounded, onTap: onRetake),
                  const Spacer(),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isVideo ? '🎬 Video captured' : '📸 Photo captured',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        resLabel,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                  const Spacer(),
                  const SizedBox(width: 40),
                ],
              ),
            ),
          ),
        ),

        // Bottom action row
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xCC000000), Color(0x00000000)],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onRetake,
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                      label: const Text('Retake', style: TextStyle(color: Colors.white)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white54),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: onConfirm,
                      icon: const Icon(Icons.cloud_upload_rounded),
                      label: const Text('Upload to Cloud'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Video thumbnail placeholder ───────────────────────────────────────────────

class _VideoThumbnail extends StatelessWidget {
  final File file;
  final String resLabel;
  const _VideoThumbnail({required this.file, required this.resLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_rounded, color: Colors.white60, size: 72),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                resLabel,
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 1),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              p.basename(file.path),
              style: const TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small reusable widgets ────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42, height: 42,
        decoration: BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  final double zoom;
  const _ZoomBadge({required this.zoom});

  @override
  Widget build(BuildContext context) {
    if (zoom <= 1.05) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        '${zoom.toStringAsFixed(1)}×',
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _RecordingBadge extends StatelessWidget {
  final Duration duration;
  const _RecordingBadge({required this.duration});

  String get _label {
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '● $m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.red.shade700.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(_label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final bool isVideo;
  final VoidCallback onToggle;
  const _ModeToggle({required this.isVideo, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeChip(label: '📷 Photo', selected: !isVideo),
            _ModeChip(label: '🎬 Video', selected: isVideo),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  const _ModeChip({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(26),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.black : Colors.white70,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isVideo;
  final bool isRecording;
  final bool isBusy;
  final VoidCallback onTap;

  const _ShutterButton({
    required this.isVideo,
    required this.isRecording,
    required this.isBusy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final outerColor = isRecording
        ? Colors.red
        : (isVideo ? Colors.red : Colors.white);

    return GestureDetector(
      onTap: isBusy ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isRecording
              ? Colors.red.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.12),
          border: Border.all(color: outerColor, width: 4),
        ),
        child: isBusy
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Center(
                child: isRecording
                    // Stop square
                    ? Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(5)),
                      )
                    : Container(
                        // Photo = large white circle / Video = small red circle
                        width:  isVideo ? 24 : 56,
                        height: isVideo ? 24 : 56,
                        decoration: BoxDecoration(
                          color: outerColor,
                          shape: isVideo ? BoxShape.rectangle : BoxShape.circle,
                          borderRadius: isVideo ? BorderRadius.circular(5) : null,
                        ),
                      ),
              ),
      ),
    );
  }
}
