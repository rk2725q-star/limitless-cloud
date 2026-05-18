import 'package:flutter/material.dart';
import '../../features/auth/presentation/pages/splash_page.dart';
import '../../features/auth/presentation/pages/phone_input_page.dart';
import '../../features/auth/presentation/pages/otp_page.dart';
import '../../features/auth/presentation/pages/two_factor_page.dart';
import '../../features/drive/presentation/pages/home_page.dart';
import '../../features/drive/presentation/pages/folder_page.dart';
import '../../features/drive/presentation/pages/search_page.dart';
import '../../features/drive/presentation/pages/file_detail_page.dart';
import '../../features/drive/presentation/pages/music_player_page.dart';
import '../../features/drive/presentation/pages/image_viewer_page.dart';
import '../../features/drive/presentation/pages/video_player_page.dart';
import '../../features/drive/presentation/pages/document_viewer_page.dart';
import '../../features/drive/presentation/pages/download_manager_page.dart';
import '../../features/settings/presentation/pages/settings_page.dart';

class AppRoutes {
  static const String splash          = '/';
  static const String phoneInput      = '/phone-input';
  static const String otp             = '/otp';
  static const String twoFactor       = '/two-factor';
  static const String home            = '/home';
  static const String folder          = '/folder';
  static const String search          = '/search';
  static const String fileDetail      = '/file-detail';
  static const String musicPlayer     = '/music-player';
  static const String imageViewer     = '/image-viewer';
  static const String videoPlayer     = '/video-player';
  static const String documentViewer  = '/document-viewer';
  static const String downloadManager = '/download-manager';
  static const String settings        = '/settings';

  static Route<dynamic> generateRoute(RouteSettings settings_) {
    switch (settings_.name) {
      case splash:
        return _fadeRoute(const SplashPage(), settings_);
      case phoneInput:
        return _slideRoute(const PhoneInputPage(), settings_);
      case otp:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _slideRoute(OtpPage(args: args ?? {}), settings_);
      case twoFactor:
        return _slideRoute(const TwoFactorPage(), settings_);
      case home:
        return _fadeRoute(const HomePage(), settings_);
      case folder:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _slideRoute(FolderPage(args: args ?? {}), settings_);
      case search:
        return _slideRoute(const SearchPage(), settings_);
      case fileDetail:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _slideRoute(FileDetailPage(args: args ?? {}), settings_);
      case musicPlayer:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _slideRoute(MusicPlayerPage(args: args ?? {}), settings_);
      case imageViewer:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _fadeRoute(ImageViewerPage(args: args ?? {}), settings_);
      case videoPlayer:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _fadeRoute(VideoPlayerPage(args: args ?? {}), settings_);
      case documentViewer:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _slideRoute(DocumentViewerPage(args: args ?? {}), settings_);
      case downloadManager:
        final args = settings_.arguments as Map<String, dynamic>?;
        return _slideRoute(DownloadManagerPage(args: args), settings_);
      case AppRoutes.settings:
        return _slideRoute(const SettingsPage(), settings_);
      default:
        return _fadeRoute(const SplashPage(), settings_);
    }
  }

  static PageRoute _fadeRoute(Widget page, RouteSettings settings) {
    return PageRouteBuilder(
      settings: settings,
      pageBuilder: (ctx, anim, secAnim) => page,
      transitionsBuilder: (ctx, animation, secAnim, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 300),
    );
  }

  static PageRoute _slideRoute(Widget page, RouteSettings settings) {
    return PageRouteBuilder(
      settings: settings,
      pageBuilder: (ctx, anim, secAnim) => page,
      transitionsBuilder: (ctx, animation, secAnim, child) {
        const begin = Offset(1.0, 0.0);
        const end = Offset.zero;
        final tween = Tween(begin: begin, end: end).chain(
          CurveTween(curve: Curves.easeOutCubic),
        );
        return SlideTransition(
          position: animation.drive(tween),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 320),
    );
  }
}
