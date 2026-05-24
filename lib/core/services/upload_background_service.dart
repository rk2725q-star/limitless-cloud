import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// UploadBackgroundService
///
/// Shows a persistent foreground-style progress notification so Android keeps
/// the app process alive during uploads and downloads even when the user
/// minimises the app.
///
/// NOTE: We intentionally do NOT use flutter_background_service (separate
/// isolate) because it is complex, requires extra manifest wiring, and causes
/// launch crashes on many devices.  A persistent notification from
/// flutter_local_notifications is sufficient to signal Android's process-
/// priority system that this app has ongoing work and must not be killed.
///
/// Usage:
///   • [init]           — call once in main() before runApp
///   • [startUpload]    — call when an upload/download begins
///   • [updateProgress] — update the notification % as bytes transfer
///   • [stopUpload]     — call when all transfers finish
class UploadBackgroundService {
  static final _notifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'limitless_transfer';
  static const _notifId   = 42;
  static bool _initialised = false;

  static const _androidChannel = AndroidNotificationChannel(
    _channelId,
    'Transfers',
    description: 'Shows upload/download progress in the background',
    importance: Importance.low,
    enableVibration: false,
    playSound: false,
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
      // Notification init failure is non-fatal — app still works, just without
      // the background progress notification
    }
  }

  // ── Start foreground notification ─────────────────────────────────────────
  static Future<void> startUpload(String fileName) async {
    try {
      await _showNotification('Starting: $fileName', 0);
    } catch (_) {}
  }

  // ── Update progress % ─────────────────────────────────────────────────────
  static void updateProgress(String fileName, double progress) {
    try {
      final pct = (progress * 100).toInt().clamp(0, 99);
      _showNotification(fileName, pct);
    } catch (_) {}
  }

  // ── Dismiss notification when done ───────────────────────────────────────
  static Future<void> stopUpload() async {
    try {
      await _notifications.cancel(_notifId);
    } catch (_) {}
  }

  // ── Internal ──────────────────────────────────────────────────────────────
  static Future<void> _showNotification(String title, int pct) async {
    await _notifications.show(
      _notifId,
      'Limitless Cloud',
      pct == 0
          ? title
          : '$title  —  $pct%',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Transfers',
          channelDescription: 'Upload/download progress',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: pct,
          ongoing: true,       // persistent — not swipeable while transfer runs
          autoCancel: false,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }
}
