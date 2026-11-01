import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart' hide InputImage;
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../../core/services/offline_sync_service.dart';
import '../../../../core/theme/app_theme.dart';

// ── Resolution definitions ────────────────────────────────────────────────────

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

const int _defaultResIndex = 1; // FHD default

// ── Aspect Ratio definitions ──────────────────────────────────────────────────

enum CameraAspectRatio {
  ratio1x1('1:1', 'Square', 1.0),
  ratio4x3('4:3', 'Standard', 3 / 4),
  ratio16x9('16:9', '9:16', 9 / 16),
  ratioFull('Full', 'Screen', null);

  final String label;
  final String sublabel;
  final double? ratio; // width / height in portrait orientation
  const CameraAspectRatio(this.label, this.sublabel, this.ratio);
}

// ── Camera Modes ──────────────────────────────────────────────────────────────

enum CameraMode {
  photo('📷 Photo'),
  portrait('👤 Portrait'),
  video('🎬 Video');

  final String label;
  const CameraMode(this.label);
}

// ── Depth of Field (f-stop) definitions ───────────────────────────────────────

class _FStopOption {
  final String label;
  final String desc;
  final double blurRadius;
  const _FStopOption(this.label, this.desc, this.blurRadius);
}

const List<_FStopOption> _fStopOptions = [
  _FStopOption('f/1.4', 'Max Bokeh', 26.0),
  _FStopOption('f/2.0', 'Strong', 18.0),
  _FStopOption('f/2.8', 'Standard', 12.0),
  _FStopOption('f/4.0', 'Subtle', 7.0),
  _FStopOption('f/8.0', 'Deep Focus', 3.0),
];

const int _defaultFStopIndex = 2; // f/2.8 default

// ── Background Isolate Processing Parameters ──────────────────────────────────

// ── Background Isolate Processing Parameters ──────────────────────────────────

class _NormalizeParams {
  final String filePath;
  final double targetRatio;
  final bool isFrontCamera;

  const _NormalizeParams({
    required this.filePath,
    required this.targetRatio,
    required this.isFrontCamera,
  });
}

/// Normalizes the captured JPEG with the minimal possible processing:
/// - Bakes EXIF orientation (only if camera stored pixels sideways)
/// - Flips horizontally (front camera only)
/// - Crops to selected aspect ratio (only if needed)
///
/// CRITICAL: If NO transformation is actually required (back camera, EXIF
/// already upright, and aspect ratio matches), we return WITHOUT re-encoding.
/// Skipping the Dart JPEG encoder preserves 100% of the native Android hardware
/// JPEG quality and eliminates the "dot dot" DCT block artifacts caused by
/// generation loss in the pure-Dart `image` package encoder.
Future<void> _normalizeImageInIsolate(_NormalizeParams params) async {
  try {
    final file = File(params.filePath);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;

    // ── Step 1: Bake EXIF orientation ──────────────────────────────────────────
    // Track whether bakeOrientation actually rotated the pixels.
    // If EXIF says "already upright" (orientation = 1), it's a no-op.
    final int preBakeW = decoded.width;
    final int preBakeH = decoded.height;
    var oriented = img.bakeOrientation(decoded);
    final bool wasRotated =
        oriented.width != preBakeW || oriented.height != preBakeH;

    // ── Step 2: Flip front camera ──────────────────────────────────────────────
    if (params.isFrontCamera) {
      oriented = img.flipHorizontal(oriented);
    }

    // ── Step 3: Check if aspect ratio crop is needed ───────────────────────────
    final double imgRatio = oriented.width / oriented.height;
    final bool needsCrop = (imgRatio - params.targetRatio).abs() >= 0.015;

    // ── Fast path: nothing changed → keep native hardware JPEG as-is ──────────
    // Avoids the Dart JPEG encoder entirely, which would introduce "dot dot"
    // DCT block artifacts even at quality:100 due to different quantization.
    if (!params.isFrontCamera && !wasRotated && !needsCrop) {
      return; // Original hardware JPEG is perfect — no re-encode needed
    }

    // ── Slow path: apply crop if needed ────────────────────────────────────────
    if (needsCrop) {
      int cropW = oriented.width;
      int cropH = oriented.height;
      int cropX = 0;
      int cropY = 0;

      if (imgRatio > params.targetRatio) {
        cropW = (oriented.height * params.targetRatio).round().clamp(1, oriented.width);
        cropX = ((oriented.width - cropW) / 2).round();
      } else {
        cropH = (oriented.width / params.targetRatio).round().clamp(1, oriented.height);
        cropY = ((oriented.height - cropH) / 2).round();
      }
      oriented = img.copyCrop(oriented, x: cropX, y: cropY, width: cropW, height: cropH);
    }

    // Encode only when a transformation was genuinely applied.
    // quality:100 → minimum quantization loss in the Dart encoder.
    final encoded = img.encodeJpg(oriented, quality: 100);
    await file.writeAsBytes(encoded);
  } catch (e) {
    debugPrint('Image normalize isolate error: $e');
  }
}

class _FaceRect {
  final double left;
  final double top;
  final double width;
  final double height;

  const _FaceRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

class _BokehParams {
  final String filePath;
  final double blurRadius;
  final List<double>? segmentationMask;
  final int maskWidth;
  final int maskHeight;
  final List<_FaceRect> faces;
  final double? focusNormX;
  final double? focusNormY;

  const _BokehParams({
    required this.filePath,
    required this.blurRadius,
    this.segmentationMask,
    this.maskWidth = 0,
    this.maskHeight = 0,
    this.faces = const [],
    this.focusNormX,
    this.focusNormY,
  });
}

/// Applies realistic DSLR optical background bokeh blur to the upright image.
/// Architecture changes vs previous version:
///  - Mask built at FULL image resolution → no blocky upscaling artifacts
///  - 3-pass box blur instead of single gaussianBlur → eliminates ring/halo artifacts
///  - Smooth Hermite blend across [0.0 .. 1.0] without hard thresholds
///  - quality:100 JPEG to avoid double-compression stippling
Future<void> _applyBokehInIsolate(_BokehParams params) async {
  try {
    final file = File(params.filePath);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    // bakeOrientation: ensures pixels are physically upright regardless of
    // whether _normalizeImageInIsolate already ran or took the fast-path skip.
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;
    final oriented = img.bakeOrientation(decoded);

    final int w = oriented.width;
    final int h = oriented.height;

    // ── 1. Background blur ────────────────────────────────────────────────────
    // Downscale to 480px work width — narrower = more accumulated blur per pass.
    // This is the standard phone-camera bokeh trick: blur cheap at low-res, upscale.
    // blurRadius [3..26] → passes [6..30]: strong enough to be clearly visible.
    final int blurPasses = (params.blurRadius * 1.2).round().clamp(6, 30);
    const int blurWorkW = 480;
    final int blurWorkH = ((blurWorkW * h) / w).round().clamp(1, 9999);
    final bgSmall = img.copyResize(oriented,
        width: blurWorkW, height: blurWorkH,
        interpolation: img.Interpolation.linear);

    img.Image blurredSmall = bgSmall;
    for (int i = 0; i < blurPasses; i++) {
      blurredSmall = img.smooth(blurredSmall, weight: 1);
    }
    // Scale blurred background back to full resolution
    final blurredBg = img.copyResize(blurredSmall,
        width: w, height: h,
        interpolation: img.Interpolation.linear);

    // ── 2. Build foreground alpha mask at FULL image resolution ───────────────
    // Using full-res avoids the chief cause of "blocky / dot-dot" edges that
    // appeared when a 270px mask was upscaled 15× to 4K.
    final maskData = List<double>.filled(w * h, 0.0);

    final bool hasNeuralMask = params.segmentationMask != null &&
        params.segmentationMask!.isNotEmpty &&
        params.maskWidth > 0 &&
        params.maskHeight > 0;
    final int rawMaskW = params.maskWidth;
    final int rawMaskH = params.maskHeight;
    final bool hasFaces = params.faces.isNotEmpty;

    if (hasFaces || hasNeuralMask) {
      for (int py = 0; py < h; py++) {
        final double normY = py / h;
        for (int px = 0; px < w; px++) {
          final double normX = px / w;
          final double imgX = normX * w;
          final double imgY = normY * h;

          double alpha = 0.0;

          // A. Sample neural segmentation mask with bilinear interpolation
          if (hasNeuralMask) {
            final double mxF = normX * (rawMaskW - 1);
            final double myF = normY * (rawMaskH - 1);
            final int mx0 = mxF.floor().clamp(0, rawMaskW - 1);
            final int my0 = myF.floor().clamp(0, rawMaskH - 1);
            final int mx1 = (mx0 + 1).clamp(0, rawMaskW - 1);
            final int my1 = (my0 + 1).clamp(0, rawMaskH - 1);
            final double fx = mxF - mx0;
            final double fy = myF - my0;
            final double c00 = params.segmentationMask![my0 * rawMaskW + mx0];
            final double c10 = params.segmentationMask![my0 * rawMaskW + mx1];
            final double c01 = params.segmentationMask![my1 * rawMaskW + mx0];
            final double c11 = params.segmentationMask![my1 * rawMaskW + mx1];
            final double conf =
                c00 * (1 - fx) * (1 - fy) +
                c10 * fx * (1 - fy) +
                c01 * (1 - fx) * fy +
                c11 * fx * fy;

            // Smooth sigmoid ramp: 0 below 0.35, full at 0.65
            if (conf >= 0.65) {
              alpha = 1.0;
            } else if (conf > 0.35) {
              final t = (conf - 0.35) / 0.30;
              alpha = t * t * (3.0 - 2.0 * t); // Hermite smoothstep
            }
          }

          // B. Face anchors — guarantee face/head/hair region is 100% sharp
          for (final face in params.faces) {
            final double headCx = face.left + face.width * 0.5;
            final double headCy = face.top + face.height * 0.40;
            // Slightly generous horizontal radius to catch ears and hair sides
            final double headRx = face.width * 0.80;
            final double headRy = face.height * 0.85;

            final double dx = (imgX - headCx) / headRx;
            final double dy = (imgY - headCy) / headRy;
            final double distHead = dx * dx + dy * dy;

            double headAlpha = 0.0;
            if (distHead <= 1.0) {
              headAlpha = 1.0;
            } else if (distHead < 1.5) {
              final double t = (1.5 - distHead) / 0.5;
              headAlpha = t * t * (3.0 - 2.0 * t);
            }
            if (headAlpha > alpha) alpha = headAlpha;

            // Torso anchor: expands outward from chin downward to include body
            if (imgY > face.top + face.height * 0.55) {
              final double dyTorso = imgY - (face.top + face.height * 0.55);
              // Widen by 0.3px per px down to cover shoulders/arms naturally
              final double halfW = (face.width * 0.70) + (dyTorso * 0.28);
              final double edgeDist = halfW - (imgX - headCx).abs();
              if (edgeDist >= 0) {
                // Soft feather within last 20px of torso edge
                final double torsoAlpha = (edgeDist / 20.0).clamp(0.0, 1.0);
                // Hermite smooth
                final double ta = torsoAlpha * torsoAlpha * (3.0 - 2.0 * torsoAlpha);
                if (ta > alpha) alpha = ta;
              }
            }
          }

          maskData[py * w + px] = alpha.clamp(0.0, 1.0);
        }
      }

      // ── Feather the mask with a lightweight 2-pass box blur ──────────────────
      // This softens the hard segmentation boundary without blurring it large enough
      // to create the "dot dot" stippling that occurred with gaussianBlur on a tiny mask.
      // We operate on a 1/4-resolution version of the mask for speed.
      const int fmW = 480; // feather-mask work width
      final int fmH = ((fmW * h) / w).round();
      var fmImg = img.Image(width: fmW, height: fmH, numChannels: 1);
      for (int fy = 0; fy < fmH; fy++) {
        final double srcY = (fy / fmH) * h;
        for (int fx = 0; fx < fmW; fx++) {
          final double srcX = (fx / fmW) * w;
          final int si = srcY.round().clamp(0, h - 1) * w + srcX.round().clamp(0, w - 1);
          final int v = (maskData[si] * 255).round().clamp(0, 255);
          fmImg.setPixelRgb(fx, fy, v, v, v);
        }
      }
      // Two gentle smoothing passes — feathers the edge ~6px at 480px scale
      fmImg = img.smooth(fmImg, weight: 1);
      fmImg = img.smooth(fmImg, weight: 1);
      // Copy feathered values back into maskData at full res
      for (int py = 0; py < h; py++) {
        final double fySrc = (py / h) * fmH;
        for (int px = 0; px < w; px++) {
          final double fxSrc = (px / w) * fmW;
          final double v = fmImg.getPixel(
                fxSrc.round().clamp(0, fmW - 1),
                fySrc.round().clamp(0, fmH - 1)).r /
              255.0;
          maskData[py * w + px] = v;
        }
      }
    } else {
      // ── Fallback: radial focus mask around tap/centre point ──────────────────
      final double cx = (params.focusNormX ?? 0.5) * w;
      final double cy = (params.focusNormY ?? 0.5) * h;
      final double rx = w * 0.36;
      final double ry = h * 0.42;

      for (int py = 0; py < h; py++) {
        final double dy = (py - cy) / ry;
        final double dySq = dy * dy;
        for (int px = 0; px < w; px++) {
          final double dx = (px - cx) / rx;
          final double distSq = dx * dx + dySq;
          double alpha = 0.0;
          if (distSq <= 1.0) {
            alpha = 1.0;
          } else if (distSq < 1.5) {
            final double t = (1.5 - distSq) / 0.5;
            alpha = t * t * (3.0 - 2.0 * t);
          }
          maskData[py * w + px] = alpha;
        }
      }
    }

    // ── 3. Composite: blend original (sharp subject) over blurred background ──
    // Smooth Hermite blend across the full [0..1] mask range — no hard thresholds.
    final blended = img.Image(width: w, height: h);
    for (int py = 0; py < h; py++) {
      for (int px = 0; px < w; px++) {
        final double rawA = maskData[py * w + px];
        // Apply smoothstep to the already-feathered mask for extra smooth edges
        final double a = rawA * rawA * (3.0 - 2.0 * rawA);

        if (a >= 0.999) {
          // Pixel is deep in foreground: use original sensor image (zero touch)
          blended.setPixel(px, py, oriented.getPixel(px, py));
        } else if (a <= 0.001) {
          // Pixel is deep in background: use blurred image
          blended.setPixel(px, py, blurredBg.getPixel(px, py));
        } else {
          // Smooth linear blend in the transition zone
          final fp = oriented.getPixel(px, py);
          final bp = blurredBg.getPixel(px, py);
          final int r = (fp.r * a + bp.r * (1.0 - a)).round().clamp(0, 255);
          final int g = (fp.g * a + bp.g * (1.0 - a)).round().clamp(0, 255);
          final int b = (fp.b * a + bp.b * (1.0 - a)).round().clamp(0, 255);
          blended.setPixelRgb(px, py, r, g, b);
        }
      }
    }

    // Quality 100 to avoid JPEG double-compression artifacts (stippling)
    final encoded = img.encodeJpg(blended, quality: 100);
    await file.writeAsBytes(encoded);
  } catch (e) {
    debugPrint('Portrait bokeh isolate error: $e');
  }
}

// ── Entry point ────────────────────────────────────────────────────────────────

Future<void> openCameraCapture(
  BuildContext context, {
  String? folderId,
  String folderPath = '/',
}) async {
  final camStatus = await Permission.camera.request();
  await Permission.microphone.request();
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
  int _resIndex    = _defaultResIndex;
  CameraMode _mode = CameraMode.photo;
  int _fStopIndex  = _defaultFStopIndex;
  CameraAspectRatio _aspectRatio = CameraAspectRatio.ratio4x3;
  int _timerDuration = 0; // 0 (off), 3, 5, 10
  int _countdown = 0;
  Timer? _countdownTimer;
  bool get _isCountingDown => _countdown > 0;

  bool _isRecording = false;
  bool _isBusy     = false;
  bool _isChangingRes = false;
  bool _showShutterFlash = false;
  FlashMode _flashMode = FlashMode.auto;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;

  // Dropdown menus
  bool _showAspectMenu = false;
  bool _showTimerMenu  = false;

  // Focus & exposure
  Offset? _focusPoint;
  bool _showFocusIndicator = false;
  bool _isDraggingExposure = false;
  Timer? _focusTimer;
  double _minExposure = -2.0;
  double _maxExposure = 2.0;
  double _exposureStep = 0.1;
  double _currentExposure = 0.0;

  // Zoom
  double _minZoom = 1.0;
  double _maxZoom = 8.0;
  double _currentZoom = 1.0;
  double _baseZoom    = 1.0;

  // Preview state
  File? _previewFile;
  bool _previewIsVideo = false;

  _ResOption get _res => _resOptions[_resIndex];
  _FStopOption get _fStop => _fStopOptions[_fStopIndex];

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
    _countdownTimer?.cancel();
    _recordTimer?.cancel();
    _focusTimer?.cancel();
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

  // ── Camera Init ──────────────────────────────────────────────────────────────

  Future<void> _initCamera(CameraDescription desc, {bool showSwitching = false}) async {
    if (showSwitching && mounted) setState(() => _isChangingRes = true);

    final prev = _controller;
    if (prev != null) {
      await prev.dispose();
      _controller = null;
    }

    final ctrl = CameraController(
      desc,
      _res.preset,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = ctrl;

    try {
      await ctrl.initialize();
      await ctrl.setFlashMode(_flashMode);
      try { await ctrl.setFocusMode(FocusMode.auto); } catch (_) {}
      try { await ctrl.setExposureMode(ExposureMode.auto); } catch (_) {}
      _minZoom = await ctrl.getMinZoomLevel();
      _maxZoom = await ctrl.getMaxZoomLevel();
      _currentZoom = _minZoom.clamp(1.0, _maxZoom);
      _baseZoom    = _currentZoom;

      try {
        _minExposure = await ctrl.getMinExposureOffset();
        _maxExposure = await ctrl.getMaxExposureOffset();
        _exposureStep = await ctrl.getExposureOffsetStepSize();
        if (_minExposure >= _maxExposure) {
          _minExposure = -2.0;
          _maxExposure = 2.0;
        }
      } catch (_) {
        _minExposure = -2.0;
        _maxExposure = 2.0;
        _exposureStep = 0.1;
      }
      _currentExposure = 0.0;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e')),
        );
      }
    }
    if (mounted) setState(() => _isChangingRes = false);
  }

  // ── Resolution Change ────────────────────────────────────────────────────────

  Future<void> _changeResolution(int idx) async {
    if (idx == _resIndex) return;
    if (_isRecording) return;
    _resIndex = idx;
    await _initCamera(widget.cameras[_cameraIndex], showSwitching: true);
  }

  // ── Camera Flip ──────────────────────────────────────────────────────────────

  Future<void> _flipCamera() async {
    if (widget.cameras.length < 2 || _isRecording) return;
    _cancelCountdown();
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    await _initCamera(widget.cameras[_cameraIndex], showSwitching: true);
  }

  // ── Flash ────────────────────────────────────────────────────────────────────

  Future<void> _cycleFlash() async {
    if (_mode == CameraMode.video && _isRecording) return;
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

  // ── Tap to Focus & Exposure Slider ───────────────────────────────────────────

  void _onTapToFocus(TapDownDetails details, double frameW, double frameH) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    final tapPos = details.localPosition;
    final double px = (tapPos.dx / frameW).clamp(0.0, 1.0);
    final double py = (tapPos.dy / frameH).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = tapPos;
      _showFocusIndicator = true;
      _showAspectMenu = false;
      _showTimerMenu = false;
    });

    _resetFocusTimer();
    HapticFeedback.selectionClick();

    try {
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setFocusPoint(Offset(px, py));
    } catch (_) {}

    try {
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setExposurePoint(Offset(px, py));
    } catch (_) {}
  }

  void _resetFocusTimer({int millis = 4000}) {
    _focusTimer?.cancel();
    _focusTimer = Timer(Duration(milliseconds: millis), () {
      if (mounted && !_isDraggingExposure) {
        setState(() => _showFocusIndicator = false);
      }
    });
  }

  void _onExposureDelta(double deltaDy) async {
    if (!_showFocusIndicator) return;
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    final double range = _maxExposure - _minExposure;
    if (range <= 0) return;

    // 140 pixels of drag travels the entire exposure range (-2.0 to +2.0)
    // Very responsive and easy to slide up or down with thumb
    final double change = deltaDy * (range / 140.0);
    double next = (_currentExposure + change).clamp(_minExposure, _maxExposure);
    if (_exposureStep > 0.001) {
      next = ((next / _exposureStep).round() * _exposureStep).clamp(_minExposure, _maxExposure);
    }

    if ((next - _currentExposure).abs() > 0.005) {
      setState(() {
        _currentExposure = next;
      });
      try {
        await ctrl.setExposureOffset(_currentExposure);
      } catch (_) {}
    }
  }

  // ── Zoom & Exposure Drag Handlers ──────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    if (details.pointerCount > 1) {
      _baseZoom = _currentZoom;
    } else {
      _focusTimer?.cancel();
    }
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails details) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    if (details.pointerCount > 1) {
      // 2-finger pinch to zoom
      _currentZoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);
      try { await ctrl.setZoomLevel(_currentZoom); } catch (_) {}
      if (mounted) setState(() {});
    } else if (_showFocusIndicator && details.focalPointDelta.dy.abs() > 0.2) {
      // 1-finger vertical drag on viewfinder when focus reticle is active
      _onExposureDelta(-details.focalPointDelta.dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (_showFocusIndicator && !_isDraggingExposure) {
      _resetFocusTimer(millis: 3500);
    }
  }

  // ── Timer & Shutter ──────────────────────────────────────────────────────────

  void _onShutterTap() {
    if (_mode == CameraMode.video) {
      if (_isRecording) {
        _stopVideo();
      } else {
        _startVideo();
      }
      return;
    }

    if (_isCountingDown) {
      _cancelCountdown();
      return;
    }

    if (_timerDuration > 0) {
      _startCountdown();
    } else {
      _capturePhoto();
    }
  }

  void _startCountdown() {
    setState(() {
      _countdown = _timerDuration;
      _showAspectMenu = false;
      _showTimerMenu = false;
    });
    HapticFeedback.heavyImpact();

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown <= 1) {
        timer.cancel();
        if (mounted) {
          setState(() => _countdown = 0);
          _capturePhoto();
        }
      } else {
        if (mounted) {
          setState(() => _countdown -= 1);
          HapticFeedback.heavyImpact();
        }
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    if (mounted) {
      setState(() => _countdown = 0);
      HapticFeedback.mediumImpact();
    }
  }

  // ── Photo Capture with Computational Enhancement ─────────────────────────────

  Future<void> _capturePhoto() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isBusy || _isChangingRes) return;

    final size = MediaQuery.sizeOf(context);
    final double screenAspect = size.width / size.height;
    final double targetRatio = _aspectRatio.ratio ?? screenAspect;

    setState(() {
      _isBusy = true;
      _showShutterFlash = true;
    });

    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _showShutterFlash = false);
    });

    HapticFeedback.mediumImpact();

    try {
      final xfile = await ctrl.takePicture();

      final isPortrait = _mode == CameraMode.portrait;

      final bool isFrontCamera =
          widget.cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

      // ── Step 1: Native Android Hardware Processing ────────────────────────────
      // Uses the device's native hardware pipeline (Skia + libjpeg-turbo with ARM NEON SIMD):
      // - Un-mirrors front camera selfie photos (left hand in preview = left hand in saved photo)
      // - Normalizes physical EXIF rotation
      // - Crops to chosen aspect ratio (1:1, 4:3, 16:9) without generation loss
      // - Encodes with 100% native hardware libjpeg-turbo (eliminates "dot dot" compression noise)
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.limitlesscloud/camera_service');
          await channel.invokeMethod('processImage', {
            'filePath': xfile.path,
            'isFrontCamera': isFrontCamera,
            'mirrorFrontCamera': true,
            'targetRatio': targetRatio,
            'quality': 100,
          });
        } catch (e) {
          debugPrint('Native image processing fallback error: $e');
          await compute(
            _normalizeImageInIsolate,
            _NormalizeParams(
              filePath: xfile.path,
              targetRatio: targetRatio,
              isFrontCamera: isFrontCamera,
            ),
          );
        }
      } else {
        await compute(
          _normalizeImageInIsolate,
          _NormalizeParams(
            filePath: xfile.path,
            targetRatio: targetRatio,
            isFrontCamera: isFrontCamera,
          ),
        );
      }

      // ── Step 2: Portrait Mode Depth of Field Processing ───────────────────────
      if (isPortrait && _fStop.blurRadius >= 2.0) {
        final inputImage = InputImage.fromFilePath(xfile.path);

        // A. Fast face detection to anchor human head, eyes, glasses, and hair
        List<_FaceRect> faces = [];
        try {
          final faceDetector = FaceDetector(
            options: FaceDetectorOptions(
              performanceMode: FaceDetectorMode.fast,
              enableLandmarks: false,
              enableContours: false,
              enableClassification: false,
            ),
          );
          final detected = await faceDetector.processImage(inputImage);
          faces = detected.map((f) => _FaceRect(
            left: f.boundingBox.left.toDouble(),
            top: f.boundingBox.top.toDouble(),
            width: f.boundingBox.width.toDouble(),
            height: f.boundingBox.height.toDouble(),
          )).toList();
          await faceDetector.close();
        } catch (e) {
          debugPrint('Portrait face detection error: $e');
        }

        // B. Raw 256x256 silhouette segmentation (65,536 floats - ultra fast)
        List<double>? segmentationMask;
        int maskWidth = 0;
        int maskHeight = 0;

        try {
          final segmenter = SelfieSegmenter(
            mode: SegmenterMode.single,
            enableRawSizeMask: true,
          );
          final mask = await segmenter.processImage(inputImage);
          if (mask != null && mask.confidences.isNotEmpty) {
            segmentationMask = mask.confidences;
            maskWidth = mask.width;
            maskHeight = mask.height;
          }
          await segmenter.close();
        } catch (e) {
          debugPrint('Portrait segmentation error: $e');
        }

        // C. Apply optical DSLR bokeh blur natively on Android (or fallback isolate)
        bool nativeBokehSucceeded = false;
        if (Platform.isAndroid) {
          try {
            const channel = MethodChannel('com.limitlesscloud/camera_service');
            final outcome = await channel.invokeMethod<Map>('applyPortraitBokeh', {
              'filePath': xfile.path,
              'blurRadius': _fStop.blurRadius,
              'segmentationMask': segmentationMask,
              'maskWidth': maskWidth,
              'maskHeight': maskHeight,
              'faces': faces.map((f) => {
                'left': f.left,
                'top': f.top,
                'width': f.width,
                'height': f.height,
              }).toList(),
              'focusNormX': _focusPoint != null ? (_focusPoint!.dx / size.width).clamp(0.0, 1.0) : 0.5,
              'focusNormY': _focusPoint != null ? (_focusPoint!.dy / size.height).clamp(0.0, 1.0) : 0.5,
              'quality': 100,
            });
            if (outcome != null && outcome['success'] == true) {
              nativeBokehSucceeded = true;
            }
          } catch (e) {
            debugPrint('Native portrait bokeh fallback error: $e');
          }
        }

        if (!nativeBokehSucceeded) {
          await compute(
            _applyBokehInIsolate,
            _BokehParams(
              filePath: xfile.path,
              blurRadius: _fStop.blurRadius,
              segmentationMask: segmentationMask,
              maskWidth: maskWidth,
              maskHeight: maskHeight,
              faces: faces,
              focusNormX: _focusPoint != null ? (_focusPoint!.dx / size.width).clamp(0.0, 1.0) : 0.5,
              focusNormY: _focusPoint != null ? (_focusPoint!.dy / size.height).clamp(0.0, 1.0) : 0.5,
            ),
          );
        }
      }

      if (mounted) {
        setState(() {
          _previewFile    = File(xfile.path);
          _previewIsVideo = false;
          _isBusy         = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _showShutterFlash = false;
        });
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
    if (_isBusy) return;
    setState(() => _isBusy = true);

    final file = _previewFile;
    if (file == null) {
      if (mounted) setState(() => _isBusy = false);
      return;
    }

    final tmpDir  = await getTemporaryDirectory();
    final now     = DateTime.now();
    final y       = now.year.toString().padLeft(4, '0');
    final m       = now.month.toString().padLeft(2, '0');
    final d       = now.day.toString().padLeft(2, '0');
    final hr      = now.hour.toString().padLeft(2, '0');
    final min     = now.minute.toString().padLeft(2, '0');
    final sec     = now.second.toString().padLeft(2, '0');
    final dateStr = '$y$m${d}_$hr$min$sec';
    final resLabel = _res.label;
    final ratioStr = _aspectRatio.label.replaceAll(':', 'x');

    String fileName;
    if (_previewIsVideo) {
      fileName = 'VID_${dateStr}_$resLabel.mp4';
    } else if (_mode == CameraMode.portrait) {
      fileName = 'PORTRAIT_${dateStr}_${ratioStr}_${_fStop.label.replaceAll('/', '')}_$resLabel.jpg';
    } else {
      fileName = 'IMG_${dateStr}_${ratioStr}_$resLabel.jpg';
    }

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

    await OfflineSyncService.instance.saveCapturedFile(
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
              isBusy: _isBusy,
              resLabel: _mode == CameraMode.portrait
                  ? '👤 Portrait • ${_fStop.label} • ${_res.label}'
                  : '📸 Photo • ${_aspectRatio.label} • ${_res.label}',
              onRetake: _retake,
              onConfirm: _confirmAndUpload,
            )
          else ...[
            // ── Viewfinder with Aspect Ratio Framing ───────────────────────
            LayoutBuilder(
              builder: (context, constraints) {
                final double maxW = constraints.maxWidth;
                final double maxH = constraints.maxHeight;
                final double screenAspect = maxW / maxH;
                final double frameAspect = _aspectRatio.ratio ?? screenAspect;

                double frameW = maxW;
                double frameH = frameW / frameAspect;

                if (frameH > maxH) {
                  frameH = maxH;
                  frameW = frameH * frameAspect;
                }

                final double camAspect = ctrl.value.aspectRatio;
                final double camPortraitAspect =
                    camAspect > 0 ? (1.0 / camAspect) : (9 / 16);

                return Container(
                  color: Colors.black,
                  width: maxW,
                  height: maxH,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Viewfinder box
                      SizedBox(
                        width: frameW,
                        height: frameH,
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: 100,
                                  height: 100 / camPortraitAspect,
                                  child: CameraPreview(ctrl),
                                ),
                              ),
                              // Gesture detector for focus, exposure drag, and zoom
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: _onScaleStart,
                                onScaleUpdate: _onScaleUpdate,
                                onScaleEnd: _onScaleEnd,
                                onTapDown: (d) =>
                                    _onTapToFocus(d, frameW, frameH),
                              ),
                              // Focus reticle + Vertical brightness slider
                              if (_showFocusIndicator && _focusPoint != null)
                                Positioned(
                                  left: (_focusPoint!.dx - 32).clamp(10.0, frameW - 130.0),
                                  top: (_focusPoint!.dy - 60).clamp(20.0, frameH - 140.0),
                                  child: _FocusAndExposureWidget(
                                    currentExposure: _currentExposure,
                                    minExposure: _minExposure,
                                    maxExposure: _maxExposure,
                                    onExposureDelta: _onExposureDelta,
                                    onDragStart: () {
                                      _isDraggingExposure = true;
                                      _focusTimer?.cancel();
                                    },
                                    onDragEnd: () {
                                      _isDraggingExposure = false;
                                      _resetFocusTimer(millis: 3500);
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),

                      // Outer frame border indicator when letterboxed
                      if (_aspectRatio != CameraAspectRatio.ratioFull)
                        IgnorePointer(
                          child: Container(
                            width: frameW,
                            height: frameH,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
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

            // ── Shutter Flash White Overlay ────────────────────────────────
            if (_showShutterFlash)
              IgnorePointer(
                child: Container(color: Colors.white.withValues(alpha: 0.75)),
              ),

            // ── Countdown Overlay ──────────────────────────────────────────
            if (_isCountingDown)
              Positioned.fill(
                child: Container(
                  color: Colors.black38,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, anim) => ScaleTransition(
                            scale: anim,
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: Text(
                            '$_countdown',
                            key: ValueKey<int>(_countdown),
                            style: const TextStyle(
                              fontSize: 120,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 28),
                                Shadow(color: Color(0xFFFFD54F), blurRadius: 36),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        GestureDetector(
                          onTap: _cancelCountdown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 22, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white38),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.close_rounded,
                                    color: Colors.white, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'Cancel',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── Top Bar ────────────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          _IconBtn(
                            icon: Icons.close_rounded,
                            onTap: () {
                              _cancelCountdown();
                              Navigator.of(context).pop();
                            },
                          ),
                          const Spacer(),
                          if (_isRecording)
                            _RecordingBadge(duration: _recordDuration)
                          else ...[
                            if (_mode != CameraMode.video) ...[
                              // Aspect Ratio Pill
                              _PillBtn(
                                label: _aspectRatio.label,
                                icon: Icons.aspect_ratio_rounded,
                                isActive: _showAspectMenu,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() {
                                    _showAspectMenu = !_showAspectMenu;
                                    _showTimerMenu = false;
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              // Timer Pill
                              _PillBtn(
                                label: _timerDuration == 0
                                    ? 'Off'
                                    : '${_timerDuration}s',
                                icon: Icons.timer_outlined,
                                isActive:
                                    _showTimerMenu || _timerDuration > 0,
                                activeColor: _timerDuration > 0
                                    ? const Color(0xFFFFD54F)
                                    : Colors.white,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() {
                                    _showTimerMenu = !_showTimerMenu;
                                    _showAspectMenu = false;
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                            ],
                            _IconBtn(icon: _flashIcon, onTap: _cycleFlash),
                          ],
                        ],
                      ),

                      // Aspect Ratio Dropdown Menu
                      if (_showAspectMenu && !_isRecording && _mode != CameraMode.video) ...[
                        const SizedBox(height: 12),
                        _AspectSelectorBar(
                          currentRatio: _aspectRatio,
                          onSelect: (ratio) {
                            HapticFeedback.selectionClick();
                            setState(() {
                              _aspectRatio = ratio;
                              _showAspectMenu = false;
                            });
                          },
                        ),
                      ],

                      // Timer Dropdown Menu
                      if (_showTimerMenu && !_isRecording && _mode != CameraMode.video) ...[
                        const SizedBox(height: 12),
                        _TimerSelectorBar(
                          currentDuration: _timerDuration,
                          onSelect: (sec) {
                            HapticFeedback.selectionClick();
                            setState(() {
                              _timerDuration = sec;
                              _showTimerMenu = false;
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            // ── Zoom level badge (left side) ───────────────────────────────
            Positioned(
              left: 16,
              bottom: 250,
              child: _ZoomBadge(zoom: _currentZoom),
            ),

            // ── Bottom controls ────────────────────────────────────────────
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: SafeArea(
                child: _BottomControls(
                  mode: _mode,
                  isRecording: _isRecording,
                  isBusy: _isBusy || _isChangingRes,
                  isCountingDown: _isCountingDown,
                  countdown: _countdown,
                  canFlip: widget.cameras.length > 1,
                  onFlip: _flipCamera,
                  resOptions: _resOptions,
                  selectedResIndex: _resIndex,
                  fStopOptions: _fStopOptions,
                  selectedFStopIndex: _fStopIndex,
                  onResChange: _changeResolution,
                  onFStopChange: (idx) {
                    HapticFeedback.selectionClick();
                    setState(() => _fStopIndex = idx);
                  },
                  onModeChange: (newMode) {
                    if (_isRecording || _isCountingDown) return;
                    _cancelCountdown();
                    HapticFeedback.selectionClick();
                    setState(() {
                      _mode = newMode;
                      _showAspectMenu = false;
                      _showTimerMenu = false;
                    });
                  },
                  onShutter: _onShutterTap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Focus Reticle + Brightness Slider ─────────────────────────────────────────

class _FocusAndExposureWidget extends StatefulWidget {
  final double currentExposure;
  final double minExposure;
  final double maxExposure;
  final ValueChanged<double> onExposureDelta;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  const _FocusAndExposureWidget({
    required this.currentExposure,
    required this.minExposure,
    required this.maxExposure,
    required this.onExposureDelta,
    this.onDragStart,
    this.onDragEnd,
  });

  @override
  State<_FocusAndExposureWidget> createState() => _FocusAndExposureWidgetState();
}

class _FocusAndExposureWidgetState extends State<_FocusAndExposureWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double range = widget.maxExposure - widget.minExposure;
    final double fraction = range > 0
        ? ((widget.currentExposure - widget.minExposure) / range).clamp(0.0, 1.0)
        : 0.5;

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final scale = Tween<double>(begin: 1.35, end: 1.0).transform(
          CurvedAnimation(parent: _anim, curve: Curves.easeOutBack).value,
        );

        return Transform.scale(
          scale: scale,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Reticle square
              SizedBox(
                width: 64,
                height: 64,
                child: CustomPaint(
                  size: const Size(60, 60),
                  painter: _FocusBracketPainter(),
                ),
              ),
              const SizedBox(width: 6),

              // Vertical brightness slider with direct high-priority touch detector
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) {
                  HapticFeedback.selectionClick();
                  widget.onDragStart?.call();
                },
                onVerticalDragUpdate: (details) {
                  widget.onExposureDelta(-details.delta.dy);
                },
                onVerticalDragEnd: (_) => widget.onDragEnd?.call(),
                onVerticalDragCancel: () => widget.onDragEnd?.call(),
                child: Container(
                  width: 56,
                  height: 120,
                  alignment: Alignment.center,
                  color: Colors.transparent, // Catches touches across entire 56x120 area
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Vertical track capsule line
                      Container(
                        width: 3,
                        height: 90,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      // Sun indicator moving up/down (fraction 1.0 = top, 0.0 = bottom)
                      Positioned(
                        top: (1.0 - fraction) * 64 + 6,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFFFFD54F),
                              width: 1.8,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFFFD54F).withValues(alpha: 0.45),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.wb_sunny_rounded,
                            color: Color(0xFFFFD54F),
                            size: 19,
                          ),
                        ),
                      ),
                      // Exposure numerical offset badge
                      if (widget.currentExposure.abs() > 0.05)
                        Positioned(
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${widget.currentExposure >= 0 ? '+' : ''}${widget.currentExposure.toStringAsFixed(1)}',
                              style: const TextStyle(
                                color: Color(0xFFFFD54F),
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FocusBracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;
    const len = 14.0;

    // Top-Left
    canvas.drawLine(const Offset(0, len), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(len, 0), paint);

    // Top-Right
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);

    // Bottom-Left
    canvas.drawLine(Offset(0, h - len), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);

    // Bottom-Right
    canvas.drawLine(Offset(w - len, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - len), paint);

    // Center dot
    final dotPaint = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(w / 2, h / 2), 2.2, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Top Selector Bars ─────────────────────────────────────────────────────────

class _AspectSelectorBar extends StatelessWidget {
  final CameraAspectRatio currentRatio;
  final ValueChanged<CameraAspectRatio> onSelect;

  const _AspectSelectorBar({
    required this.currentRatio,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: CameraAspectRatio.values.map((ratio) {
          final selected = ratio == currentRatio;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onSelect(ratio),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ratio.label,
                      style: TextStyle(
                        color: selected ? Colors.black : Colors.white,
                        fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      ratio.sublabel,
                      style: TextStyle(
                        color: selected ? Colors.black54 : Colors.white54,
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TimerSelectorBar extends StatelessWidget {
  final int currentDuration;
  final ValueChanged<int> onSelect;

  const _TimerSelectorBar({
    required this.currentDuration,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    const durations = [0, 3, 5, 10];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: durations.map((sec) {
          final selected = sec == currentDuration;
          final label = sec == 0 ? 'Off' : '${sec}s';
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onSelect(sec),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFFFFD54F) : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Bottom Controls ───────────────────────────────────────────────────────────

class _BottomControls extends StatelessWidget {
  final CameraMode mode;
  final bool isRecording;
  final bool isBusy;
  final bool isCountingDown;
  final int countdown;
  final bool canFlip;
  final VoidCallback onFlip;
  final List<_ResOption> resOptions;
  final int selectedResIndex;
  final List<_FStopOption> fStopOptions;
  final int selectedFStopIndex;
  final ValueChanged<int> onResChange;
  final ValueChanged<int> onFStopChange;
  final ValueChanged<CameraMode> onModeChange;
  final VoidCallback onShutter;

  const _BottomControls({
    required this.mode,
    required this.isRecording,
    required this.isBusy,
    required this.isCountingDown,
    required this.countdown,
    required this.canFlip,
    required this.onFlip,
    required this.resOptions,
    required this.selectedResIndex,
    required this.fStopOptions,
    required this.selectedFStopIndex,
    required this.onResChange,
    required this.onFStopChange,
    required this.onModeChange,
    required this.onShutter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xDD000000), Color(0x00000000)],
          stops: [0.0, 1.0],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Depth of Field Aperture Bar (Portrait Mode Only) ────────────
          if (mode == CameraMode.portrait && !isCountingDown) ...[
            _ApertureBar(
              options: fStopOptions,
              selectedIndex: selectedFStopIndex,
              onSelect: onFStopChange,
            ),
            const SizedBox(height: 14),
          ],

          // ── Resolution selector ─────────────────────────────────────────
          if (!isRecording && !isCountingDown && mode != CameraMode.portrait) ...[
            _ResolutionBar(
              options: resOptions,
              selectedIndex: selectedResIndex,
              onSelect: onResChange,
            ),
            const SizedBox(height: 14),
          ],

          // ── 3-Mode Selector: Photo | Portrait | Video ───────────────────
          if (!isRecording && !isCountingDown) ...[
            _ModeSelector(
              currentMode: mode,
              onSelectMode: onModeChange,
            ),
            const SizedBox(height: 22),
          ] else ...[
            const SizedBox(height: 8),
          ],

          // ── Shutter Row ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Left placeholder so Shutter Button is precisely centered
                const SizedBox(width: 56, height: 56),

                // Center: Shutter Button
                _ShutterButton(
                  mode: mode,
                  isRecording: isRecording,
                  isBusy: isBusy,
                  isCountingDown: isCountingDown,
                  countdown: countdown,
                  onTap: onShutter,
                ),

                // Right: Camera Switch (Front / Back) thumb button
                if (canFlip && !isRecording && !isCountingDown)
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onFlip();
                    },
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.35),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.flip_camera_android_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 56, height: 56),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Aperture / Depth of Field Bar (Portrait Mode) ─────────────────────────────

class _ApertureBar extends StatelessWidget {
  final List<_FStopOption> options;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _ApertureBar({
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(options.length, (i) {
          final opt = options[i];
          final selected = i == selectedIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: GestureDetector(
              onTap: () => onSelect(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFFFFD54F) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  opt.label,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white70,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ── 3-Mode Selector (Photo | Portrait | Video) ────────────────────────────────

class _ModeSelector extends StatelessWidget {
  final CameraMode currentMode;
  final ValueChanged<CameraMode> onSelectMode;

  const _ModeSelector({
    required this.currentMode,
    required this.onSelectMode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: CameraMode.values.map((m) {
          final selected = m == currentMode;
          return GestureDetector(
            onTap: () => onSelectMode(m),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                m.label,
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white70,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }).toList(),
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
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
  final bool isBusy;
  final String resLabel;
  final VoidCallback onRetake;
  final VoidCallback onConfirm;

  const _PreviewView({
    required this.file,
    required this.isVideo,
    this.isBusy = false,
    required this.resLabel,
    required this.onRetake,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Pinch-to-zoom interactive viewer for inspecting enhanced details
        isVideo
            ? _VideoThumbnail(file: file, resLabel: resLabel)
            : InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.5,
                child: Image.file(file, fit: BoxFit.contain),
              ),

        // Top bar
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _IconBtn(icon: Icons.arrow_back_rounded, onTap: isBusy ? () {} : onRetake),
                  const Spacer(),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isVideo ? '🎬 Video' : '📸 Original Photo',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700),
                      ),
                      Text(
                        resLabel,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
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

        // Bottom action bar
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                      onPressed: isBusy ? null : onRetake,
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
                      onPressed: isBusy ? null : onConfirm,
                      icon: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.cloud_upload_rounded),
                      label: Text(isBusy ? 'Saving…' : 'Upload to Cloud'),
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
                style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 1),
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

class _PillBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _PillBtn({
    required this.label,
    required this.icon,
    this.isActive = false,
    this.activeColor = Colors.white,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.black45,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isActive ? activeColor : Colors.white24,
            width: isActive ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isActive ? activeColor : Colors.white, size: 16),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isActive ? activeColor : Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
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

class _ShutterButton extends StatelessWidget {
  final CameraMode mode;
  final bool isRecording;
  final bool isBusy;
  final bool isCountingDown;
  final int countdown;
  final VoidCallback onTap;

  const _ShutterButton({
    required this.mode,
    required this.isRecording,
    required this.isBusy,
    required this.isCountingDown,
    required this.countdown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isVideo = mode == CameraMode.video;
    final bool isPortrait = mode == CameraMode.portrait;

    Color outerColor;
    if (isRecording) {
      outerColor = Colors.red;
    } else if (isCountingDown) {
      outerColor = const Color(0xFFFFD54F);
    } else if (isVideo) {
      outerColor = Colors.red;
    } else if (isPortrait) {
      outerColor = const Color(0xFFFFD54F); // Golden portrait shutter ring
    } else {
      outerColor = Colors.white;
    }

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
              : (isCountingDown
                  ? const Color(0xFFFFD54F).withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.12)),
          border: Border.all(color: outerColor, width: 4),
        ),
        child: isBusy
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Center(
                child: isCountingDown
                    ? Text(
                        '$countdown',
                        style: const TextStyle(
                          color: Color(0xFFFFD54F),
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                      )
                    : (isRecording
                        ? Container(
                            width: 24, height: 24,
                            decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(5)),
                          )
                        : Container(
                            width: isVideo ? 24 : 56,
                            height: isVideo ? 24 : 56,
                            decoration: BoxDecoration(
                              color: outerColor,
                              shape: isVideo ? BoxShape.rectangle : BoxShape.circle,
                              borderRadius: isVideo ? BorderRadius.circular(5) : null,
                            ),
                          )),
              ),
      ),
    );
  }
}
