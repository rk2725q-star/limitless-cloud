import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/telegram_auth_service.dart';

class PhoneInputPage extends ConsumerStatefulWidget {
  const PhoneInputPage({super.key});

  @override
  ConsumerState<PhoneInputPage> createState() => _PhoneInputPageState();
}

class _PhoneInputPageState extends ConsumerState<PhoneInputPage> {
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _countryCode = '+91';
  bool _isLoading = false;
  String? _errorMessage;
  String _serverUrl = '';

  @override
  void initState() {
    super.initState();
    _loadServerUrl();
  }

  Future<void> _loadServerUrl() async {
    var url = await TelegramAuthService.loadServerUrl();
    // First launch: auto-set Railway production URL as default
    if (url.isEmpty) {
      url = 'https://limitless-cloud-production.up.railway.app';
      await TelegramAuthService.saveServerUrl(url);
    }
    if (mounted) setState(() => _serverUrl = url);
  }

  Future<void> _showServerSetup() async {
    final ctrl = TextEditingController(text: _serverUrl);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Server URL', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your PC\'s LAN IP where the backend server is running.\n\n'
              'Example:\nhttp://192.168.1.5:8000\n\n'
              'Find your PC IP: open CMD → type ipconfig',
              style: AppTheme.bodyMedium.copyWith(height: 1.6),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              style: AppTheme.bodyMedium.copyWith(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.X:8000',
                prefixIcon: Icon(Icons.dns_rounded,
                    color: AppTheme.textHint, size: 20),
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () async {
              final url = ctrl.text.trim();
              await TelegramAuthService.saveServerUrl(url);
              if (mounted) setState(() => _serverUrl = url);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
  }

  final List<Map<String, String>> _countryCodes = [
    {'code': '+91', 'flag': '🇮🇳', 'name': 'India'},
    {'code': '+1', 'flag': '🇺🇸', 'name': 'USA'},
    {'code': '+44', 'flag': '🇬🇧', 'name': 'UK'},
    {'code': '+971', 'flag': '🇦🇪', 'name': 'UAE'},
    {'code': '+966', 'flag': '🇸🇦', 'name': 'Saudi Arabia'},
    {'code': '+65', 'flag': '🇸🇬', 'name': 'Singapore'},
    {'code': '+61', 'flag': '🇦🇺', 'name': 'Australia'},
    {'code': '+49', 'flag': '🇩🇪', 'name': 'Germany'},
    {'code': '+33', 'flag': '🇫🇷', 'name': 'France'},
    {'code': '+86', 'flag': '🇨🇳', 'name': 'China'},
  ];

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _sendOTP() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final phone = '$_countryCode${_phoneController.text.trim()}';
    final authService = ref.read(telegramAuthServiceProvider);
    final result = await authService.sendCode(phone);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result.success) {
      Navigator.of(context).pushNamed(
        AppRoutes.otp,
        arguments: {
          'phone': phone,
          'phoneCodeHash': result.phoneCodeHash,
          'sessionString': result.sessionString ?? '', // ← CRITICAL: pass partial session
        },
      );
    } else {
      setState(() => _errorMessage = result.error ?? 'Failed to send OTP');
    }
  }

  void _showCountryPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _CountryPickerSheet(
        selectedCode: _countryCode,
        countries: _countryCodes,
        onSelected: (code) {
          setState(() => _countryCode = code);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 32),

                // ── Header Icon ────────────────────────────────────────────
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF4F8CFF), Color(0xFF7C5CFF)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primary.withValues(alpha:0.3),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 36),
                ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),

                const SizedBox(height: 28),

                Text('Enter your\nPhone Number', style: AppTheme.displayLarge)
                    .animate()
                    .fadeIn(delay: 200.ms)
                    .slideX(begin: -0.2, end: 0),

                const SizedBox(height: 12),

                // ── Server URL Banner ──────────────────────────────────────
                GestureDetector(
                  onTap: _showServerSetup,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: _serverUrl.isEmpty
                          ? AppTheme.error.withValues(alpha: 0.12)
                          : AppTheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _serverUrl.isEmpty
                            ? AppTheme.error.withValues(alpha: 0.4)
                            : AppTheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _serverUrl.isEmpty
                              ? Icons.warning_amber_rounded
                              : Icons.dns_rounded,
                          color: _serverUrl.isEmpty ? AppTheme.error : AppTheme.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _serverUrl.isEmpty
                                ? 'Tap to set Server URL  (required)'
                                : _serverUrl,
                            style: AppTheme.bodyMedium.copyWith(
                              color: _serverUrl.isEmpty
                                  ? AppTheme.error
                                  : AppTheme.primary,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.edit_rounded,
                            color: _serverUrl.isEmpty
                                ? AppTheme.error
                                : AppTheme.textHint,
                            size: 16),
                      ],
                    ),
                  ),
                ).animate().fadeIn(delay: 150.ms),

                const SizedBox(height: 20),

                Text(
                  'We\'ll send a verification code to your Telegram-linked number',
                  style: AppTheme.bodyMedium.copyWith(height: 1.5),
                )
                    .animate()
                    .fadeIn(delay: 350.ms),

                const SizedBox(height: 48),

                // ── Phone Input ────────────────────────────────────────────
                Text(
                  'PHONE NUMBER',
                  style: AppTheme.labelLarge.copyWith(letterSpacing: 1.2),
                ).animate().fadeIn(delay: 450.ms),

                const SizedBox(height: 10),

                Row(
                  children: [
                    // Country code selector
                    GestureDetector(
                      onTap: _showCountryPicker,
                      child: Container(
                        height: 56,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _countryCodes.firstWhere(
                                (c) => c['code'] == _countryCode,
                                orElse: () => {'flag': '🌐'},
                              )['flag']!,
                              style: const TextStyle(fontSize: 22),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _countryCode,
                              style: AppTheme.titleMedium.copyWith(color: AppTheme.textPrimary),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary, size: 20),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: 12),

                    Expanded(
                      child: TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        style: AppTheme.titleMedium,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(12),
                        ],
                        decoration: const InputDecoration(
                          hintText: '98765 43210',
                          prefixIcon: Icon(Icons.phone_rounded, color: AppTheme.textHint, size: 20),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Enter phone number';
                          }
                          if (value.length < 8) {
                            return 'Enter valid number';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) => _sendOTP(),
                      ),
                    ),
                  ],
                ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.2, end: 0),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha:0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.error.withValues(alpha:0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: AppTheme.error, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: AppTheme.bodyMedium.copyWith(color: AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  ).animate().fadeIn().shakeX(),
                ],

                const SizedBox(height: 40),

                // ── Continue Button ────────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _sendOTP,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Send OTP via Telegram',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(Icons.arrow_forward_rounded, size: 20),
                            ],
                          ),
                  ),
                )
                    .animate()
                    .fadeIn(delay: 650.ms)
                    .slideY(begin: 0.3, end: 0),

                const SizedBox(height: 32),

                // ── Info Note ─────────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha:0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.primary.withValues(alpha:0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: AppTheme.primary, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Your files will be stored in your Telegram Saved Messages. We never store file contents on our servers.',
                          style: AppTheme.bodyMedium.copyWith(
                            color: AppTheme.primary.withValues(alpha:0.8),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 800.ms),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Country Picker Bottom Sheet ────────────────────────────────────────────────

class _CountryPickerSheet extends StatefulWidget {
  final String selectedCode;
  final List<Map<String, String>> countries;
  final ValueChanged<String> onSelected;

  const _CountryPickerSheet({
    required this.selectedCode,
    required this.countries,
    required this.onSelected,
  });

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.countries
        .where((c) =>
            c['name']!.toLowerCase().contains(_search.toLowerCase()) ||
            c['code']!.contains(_search))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollController) {
        return Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Select Country', style: AppTheme.titleLarge),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                style: AppTheme.bodyLarge,
                decoration: const InputDecoration(
                  hintText: 'Search country...',
                  prefixIcon: Icon(Icons.search, color: AppTheme.textHint),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: filtered.length,
                itemBuilder: (ctx, i) {
                  final country = filtered[i];
                  final isSelected = country['code'] == widget.selectedCode;
                  return ListTile(
                    leading: Text(
                      country['flag']!,
                      style: const TextStyle(fontSize: 24),
                    ),
                    title: Text(country['name']!, style: AppTheme.bodyLarge),
                    trailing: Text(
                      country['code']!,
                      style: AppTheme.titleMedium.copyWith(
                        color: isSelected ? AppTheme.primary : AppTheme.textSecondary,
                      ),
                    ),
                    selected: isSelected,
                    selectedTileColor: AppTheme.primary.withValues(alpha:0.1),
                    onTap: () => widget.onSelected(country['code']!),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
