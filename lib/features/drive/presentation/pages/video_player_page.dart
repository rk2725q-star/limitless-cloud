// video_player_page.dart
// The built-in video player has been replaced by the device's native video app.
// This stub exists only so that any leftover route references don't crash.
// FileDetailPage now handles opening via OpenFilex (system "Open With" chooser).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';

class VideoPlayerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const VideoPlayerPage({super.key, required this.args});

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Redirect to FileDetailPage which opens with native app
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.fileDetail,
        arguments: widget.args,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }
}
