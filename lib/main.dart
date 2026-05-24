import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'features/drive/data/offline_cache_service.dart';
import 'core/services/upload_background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init offline cache DB + directory.
  await OfflineCacheService.instance.init();

  // Init background upload service (keeps uploads alive when app is closed)
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
}
