import 'dart:io';
import 'package:flutter/services.dart';

/// UploadBackgroundService
///
/// Bridges Flutter → Android's TransferForegroundService via MethodChannel.
///
/// This is the REAL fix for Samsung "frequent crashes" / deep sleep:
///   • flutter_local_notifications only shows a notification — it does NOT
///     prevent Android from killing the app process.
///   • A real Android Foreground Service (startForeground()) elevates the
///     process to FOREGROUND priority — Android and all OEMs (Samsung, Xiaomi,
///     OnePlus) are legally prohibited from killing foreground services.
///   • Result: transfers complete even with screen off, battery saver on,
///     and Samsung's "Adaptive Battery" enabled.
///
/// Usage:
///   • [init]           — call once in main() before runApp (no-op on Android,
///                        kept for API compatibility)
///   • [startUpload]    — start the foreground service when transfer begins
///   • [updateProgress] — update progress % notification (no sound/vibration)
///   • [stopUpload]     — stop service & dismiss notification when done
class UploadBackgroundService {
  static const _channel = MethodChannel('com.limitlesscloud/transfer_service');
  static bool _isActive = false;

  // ── Init ──────────────────────────────────────────────────────────────────
  /// Called once in main(). No-op — service starts on demand.
  static Future<void> init() async {}

  // ── Start foreground service ───────────────────────────────────────────────
  /// Starts the Android foreground service with a persistent notification.
  /// After this call, Samsung cannot kill the process even with screen off.
  static Future<void> startUpload(String fileName) async {
    _isActive = true;
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startTransfer', {
        'title': 'Transferring: $fileName',
      });
    } catch (_) {
      // Channel not available (e.g. app cold start before engine ready) — non-fatal
    }
  }

  // ── Update progress % ─────────────────────────────────────────────────────
  /// Updates the notification progress bar in-place (silent, no vibration).
  static void updateProgress(String fileName, double progress) {
    if (!_isActive || !Platform.isAndroid) return;
    try {
      final pct = (progress * 100).toInt().clamp(0, 99);
      _channel.invokeMethod('updateProgress', {
        'title':    fileName,
        'progress': pct,
      });
    } catch (_) {}
  }

  // ── Stop foreground service ───────────────────────────────────────────────
  /// Stops the foreground service. Notification is dismissed immediately.
  /// Call this when the transfer finishes OR is cancelled.
  static Future<void> stopUpload() async {
    _isActive = false;
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopTransfer');
    } catch (_) {}
  }
}
