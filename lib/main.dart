import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'features/drive/data/offline_cache_service.dart';
import 'core/services/upload_background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Global error handlers ─────────────────────────────────────────────────
  // Catches unhandled Flutter framework errors (widget build, layout, etc.)
  // Without this, Samsung counts these as "crashes" in battery stats.
  FlutterError.onError = (FlutterErrorDetails details) {
    // Log in debug, silently swallow in release to prevent "crash" count
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  // Catches unhandled async errors in the root zone (Dart runtime errors)
  await runZonedGuarded(() async {
    // Init offline cache DB + directory
    await OfflineCacheService.instance.init();

    // Init progress notification service (battery-friendly — no persistent idle notification)
    await UploadBackgroundService.init();

    // Lock to portrait
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Status bar / nav bar styling
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF0A0A0F),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    runApp(
      const ProviderScope(
        child: LimitlessCloudApp(),
      ),
    );
  }, (error, stack) {
    // Async zone errors — log in debug only, never crash the process
    if (kDebugMode) {
      debugPrint('Zone error: $error\n$stack');
    }
  });
}
