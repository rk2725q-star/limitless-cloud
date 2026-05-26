import 'dart:io';
import 'package:flutter/services.dart';

/// UploadBackgroundService
///
/// Bridges Flutter → Android TransferForegroundService via MethodChannel.
///
/// Multi-transfer safety:
///   Uses an atomic counter (_activeCount) instead of a boolean.
///   Service starts when count goes 0 → 1 (first transfer begins).
///   Service stops ONLY when count drops back to 0 (last transfer ends).
///   Multiple concurrent uploads/downloads are all protected by the same
///   foreground service — it never stops prematurely.
///
/// Battery optimisation:
///   Progress notification updates are throttled to max once per 800ms per
///   file. Calling notificationManager.notify() too frequently causes
///   unnecessary CPU wakeups. 800ms gives smooth-looking UI with minimal drain.
class UploadBackgroundService {
  static const _channel = MethodChannel('com.limitlesscloud/transfer_service');

  /// Number of active transfers. Service runs while > 0.
  static int _activeCount = 0;

  /// Per-file timestamp of last notification update — used for throttling.
  static final Map<String, DateTime> _lastUpdate = {};

  /// Minimum interval between notification updates per file (battery saver).
  static const _kUpdateInterval = Duration(milliseconds: 800);

  // ── Init ──────────────────────────────────────────────────────────────────
  /// Called once in main(). No-op — service starts on demand.
  static Future<void> init() async {}

  // ── Start ─────────────────────────────────────────────────────────────────
  /// Called when a transfer begins.
  /// Increments active counter. Starts foreground service only on 0 → 1.
  static Future<void> startUpload(String fileName) async {
    _activeCount++;
    if (!Platform.isAndroid) return;

    if (_activeCount == 1) {
      // First transfer — start the foreground service now.
      try {
        await _channel.invokeMethod('startTransfer', {
          'title': 'Transferring: $fileName',
        });
      } catch (_) {}
    }
    // If count > 1: service already running and protecting all transfers.
    // No need to restart — just let the counter reflect the new task.
  }

  // ── Update progress ───────────────────────────────────────────────────────
  /// Updates the notification progress bar.
  /// Throttled to once per 800ms per filename to reduce CPU wakeups.
  static void updateProgress(String fileName, double progress) {
    if (_activeCount == 0 || !Platform.isAndroid) return;

    final now = DateTime.now();
    final last = _lastUpdate[fileName];
    if (last != null && now.difference(last) < _kUpdateInterval) return;
    _lastUpdate[fileName] = now;

    try {
      final pct = (progress * 100).toInt().clamp(0, 99);
      _channel.invokeMethod('updateProgress', {
        'title':    fileName,
        'progress': pct,
      });
    } catch (_) {}
  }

  // ── Stop ──────────────────────────────────────────────────────────────────
  /// Called when a transfer ends (success, cancel, or error).
  /// Decrements counter. Stops foreground service ONLY when all transfers
  /// are done (counter reaches 0).
  static Future<void> stopUpload() async {
    if (_activeCount > 0) _activeCount--;

    if (_activeCount == 0) {
      // All transfers done — clean up and stop service.
      _lastUpdate.clear();
      if (!Platform.isAndroid) return;
      try {
        await _channel.invokeMethod('stopTransfer');
      } catch (_) {}
    }
    // If count > 0: other transfers still running — keep service alive.
  }
}
