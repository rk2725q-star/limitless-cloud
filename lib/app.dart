import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_routes.dart';
import 'core/services/auto_backup_service.dart';
import 'core/services/offline_sync_service.dart';
import 'core/services/tdlib_service.dart';

class LimitlessCloudApp extends ConsumerStatefulWidget {
  const LimitlessCloudApp({super.key});

  @override
  ConsumerState<LimitlessCloudApp> createState() => _LimitlessCloudAppState();
}

class _LimitlessCloudAppState extends ConsumerState<LimitlessCloudApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    OfflineSyncService.instance.init(ref);
    AutoBackupService.instance.init(ref);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OfflineSyncService.instance.dispose();
    AutoBackupService.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Intelligently check once if today's daily backup is still pending
      AutoBackupService.instance.checkAndRunDailyBackup();
    } else if (state == AppLifecycleState.detached) {
      AutoBackupService.instance.dispose();
      TdlibService.instance.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Limitless Cloud',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.generateRoute,
    );
  }
}
