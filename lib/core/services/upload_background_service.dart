import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// UploadBackgroundService
///
/// Shows a progress notification during active uploads/downloads.
/// The notification is ONLY shown while a transfer is actively running.
/// It is NOT persistent (ongoing) when idle — this prevents Samsung's
/// battery optimizer from flagging the app as misbehaving.
///
/// Samsung "frequent crashes" / deep sleep fix:
///   - Notification is only shown during actual transfer
///   - Not `ongoing` when idle (Samsung flags persistent idle notifications)
///   - No foreground service (not needed — Dart async runs fine in background
///     while the notification keeps process priority elevated during transfer)
class UploadBackgroundService {
  static final _notifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'limitless_transfer';
  static const _notifId   = 42;
  static bool _initialised = false;
  static bool _isActive    = false; // track if a transfer is running

  static const _androidChannel = AndroidNotificationChannel(
    _channelId,
    'Transfers',
    description: 'Upload/download progress',
    importance: Importance.low,
    enableVibration: false,
    playSound: false,
    showBadge: false,
  );

  // ── Init ──────────────────────────────────────────────────────────────────
  static Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    try {
      await _notifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );

      if (Platform.isAndroid) {
        final androidPlugin = _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(_androidChannel);
        // Request POST_NOTIFICATIONS permission (Android 13+) — non-blocking
        await androidPlugin?.requestNotificationsPermission();
      }
    } catch (_) {
      // Notification init failure is non-fatal
    }
  }

  // ── Start transfer notification ───────────────────────────────────────────
  static Future<void> startUpload(String fileName) async {
    _isActive = true;
    try {
      await _showNotification('Transferring: $fileName', 0, ongoing: true);
    } catch (_) {}
  }

  // ── Update progress % ─────────────────────────────────────────────────────
  static void updateProgress(String fileName, double progress) {
    if (!_isActive) return;
    try {
      final pct = (progress * 100).toInt().clamp(0, 99);
      _showNotification(fileName, pct, ongoing: true);
    } catch (_) {}
  }

  // ── Stop: dismiss notification cleanly ───────────────────────────────────
  static Future<void> stopUpload() async {
    _isActive = false;
    try {
      await _notifications.cancel(_notifId);
    } catch (_) {}
  }

  // ── Internal ──────────────────────────────────────────────────────────────
  static Future<void> _showNotification(
      String title, int pct, {required bool ongoing}) async {
    await _notifications.show(
      _notifId,
      'Limitless Cloud',
      pct == 0 ? title : '$title  —  $pct%',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Transfers',
          channelDescription: 'Upload/download progress',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          showProgress: pct > 0,
          maxProgress: 100,
          progress: pct,
          // ongoing=true ONLY during active transfer — prevents Samsung from
          // flagging the app as consuming battery unnecessarily when idle
          ongoing: ongoing,
          autoCancel: !ongoing,
          silent: true,
          playSound: false,
          enableVibration: false,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }
}
