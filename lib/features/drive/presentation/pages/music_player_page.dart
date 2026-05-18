// music_player_page.dart
// The built-in audio player has been replaced by the device's native music app.
// This stub exists only so that any leftover route references don't crash.
// FileDetailPage now handles opening via OpenFilex (system "Open With" chooser).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';

class MusicPlayerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const MusicPlayerPage({super.key, required this.args});

  @override
  ConsumerState<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends ConsumerState<MusicPlayerPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
