import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// UploadBackgroundService
///
/// Manages a foreground Android service so uploads continue even when the user
/// closes (or backgrounds) the app.
///
/// Usage:
///   • Call [UploadBackgroundService.init] once at app startup in main().
///   • Call [UploadBackgroundService.startUpload] when an upload begins.
///   • Call [UploadBackgroundService.updateProgress] to update the notification %.
///   • Call [UploadBackgroundService.stopUpload] when all uploads finish.
class UploadBackgroundService {
  static final _notifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'limitless_upload';
  static const _notifId   = 42;

  static const _androidChannel = AndroidNotificationChannel(
    _channelId,
    'Uploads',
    description: 'Shows upload progress while app is in background',
    importance: Importance.low,
    enableVibration: false,
    playSound: false,
  );

  // ── Init (call once in main) ──────────────────────────────────────────────
  static Future<void> init() async {
    // 1. Local notifications
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_androidChannel);

    // 2. Background service
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        isForegroundMode: true,
        autoStart: false,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'Limitless Cloud',
        initialNotificationContent: 'Upload in progress…',
        foregroundServiceNotificationId: _notifId,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onServiceStart,
        onBackground: _iosBackground,
      ),
    );
  }

  // ── Start foreground service when upload begins ───────────────────────────
  static Future<void> startUpload(String fileName) async {
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (!running) {
      await service.startService();
    }
    _showNotification('Uploading "$fileName"', 0);
  }

  // ── Update % in notification ───────────────────────────────────────────────
  static void updateProgress(String fileName, double progress) {
    final pct = (progress * 100).toInt().clamp(0, 100);
    _showNotification('Uploading "$fileName"', pct);
  }

  // ── Stop service once all uploads are done ────────────────────────────────
  static Future<void> stopUpload() async {
    _notifications.cancel(_notifId);
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  static void _showNotification(String title, int pct) {
    _notifications.show(
      _notifId,
      title,
      pct == 100 ? 'Upload complete ✓' : '$pct% uploaded',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Uploads',
          channelDescription: 'Shows upload progress',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: pct,
          ongoing: pct < 100,
          autoCancel: pct == 100,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  @pragma('vm:entry-point')
  static void _onServiceStart(ServiceInstance service) async {
    // Keep alive — the upload futures run in the main isolate so this service
    // just holds the foreground notification open.
    service.on('stopService').listen((_) => service.stopSelf());
  }

  @pragma('vm:entry-point')
  static Future<bool> _iosBackground(ServiceInstance service) async => true;
}
