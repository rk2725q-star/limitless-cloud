import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/tdlib_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/telegram_auth_service.dart';

class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    // Show splash for at least 2 seconds (branding moment)
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final authService = ref.read(telegramAuthServiceProvider);

    // ── Step 1: Check local session marker ─────────────────────────────────
    // This is a lightweight flag written to SharedPreferences on successful
    // login and cleared on explicit logout. It does NOT require network.
    final session = await authService.getSession();
    if (session.isEmpty) {
      // First launch or explicit logout — go to login
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.phoneInput);
      return;
    }

    // ── Step 2: Wait for TDLib to settle ───────────────────────────────────
    // TDLib is initialised 100ms after runApp() and then needs a few seconds
    // to negotiate with Telegram servers.  We poll up to 20 seconds.
    //
    // IMPORTANT: we only CLEAR the session if TDLib explicitly reports
    // authorizationStateWaitPhoneNumber — meaning the stored credentials
    // are truly invalid.  A timeout just means a slow connection; we still
    // trust the session marker and send the user home.
    String lastState = '';
    for (int i = 0; i < 40; i++) {          // 40 × 500ms = 20 s max
      lastState = TdlibService.instance.authState;

      if (lastState == 'authorizationStateReady') {
        // TDLib confirmed: session is valid → go home
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        return;
      }

      if (lastState == 'authorizationStateWaitPhoneNumber') {
        // TDLib explicitly rejected the stored session → clear and re-login
        await authService.clearStaleSession();
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(AppRoutes.phoneInput);
        return;
      }

      // Intermediate / closing states — keep waiting
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
    }

    // ── Step 3: Timeout — trust the session marker ─────────────────────────
    // TDLib didn't reach a definitive state within 20 s (very slow network or
    // first cold start on a slow device).  We do NOT clear the session —
    // that would log the user out for no reason.
    // Instead, send them to the home page; TDLib will finish connecting in
    // the background and syncFromTelegram() will pick up their files.
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.home);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLogo(),
              const SizedBox(height: 32),

              Text(
                AppConstants.appName,
                style: AppTheme.displayLarge.copyWith(
                  foreground: Paint()
                    ..shader = const LinearGradient(
                      colors: [Color(0xFF4F8CFF), Color(0xFF7C5CFF)],
                    ).createShader(const Rect.fromLTWH(0, 0, 300, 60)),
                ),
              )
                  .animate()
                  .fadeIn(delay: 600.ms, duration: 800.ms)
                  .slideY(begin: 0.3, end: 0),

              const SizedBox(height: 12),

              Text(
                AppConstants.appTagline,
                style: AppTheme.bodyMedium.copyWith(letterSpacing: 0.5),
              )
                  .animate()
                  .fadeIn(delay: 900.ms, duration: 600.ms),

              const SizedBox(height: 80),

              _buildLoadingDots(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF4F8CFF), Color(0xFF7C5CFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha:
                  0.3 + 0.2 * _pulseController.value,
                ),
                blurRadius: 30 + 10 * _pulseController.value,
                spreadRadius: 5 + 5 * _pulseController.value,
              ),
            ],
          ),
          child: const Icon(
            Icons.cloud_rounded,
            color: Colors.white,
            size: 56,
          ),
        );
      },
    )
        .animate()
        .scale(
          begin: const Offset(0.5, 0.5),
          end: const Offset(1.0, 1.0),
          duration: 700.ms,
          curve: Curves.elasticOut,
        )
        .fadeIn(duration: 400.ms);
  }

  Widget _buildLoadingDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
          ),
        )
            .animate(onPlay: (c) => c.repeat())
            .scaleXY(
              begin: 0.5,
              end: 1.2,
              delay: (200 * i).ms,
              duration: 600.ms,
              curve: Curves.easeInOut,
            )
            .then()
            .scaleXY(
              begin: 1.2,
              end: 0.5,
              duration: 600.ms,
              curve: Curves.easeInOut,
            );
      }),
    ).animate().fadeIn(delay: 1200.ms, duration: 500.ms);
  }
}
