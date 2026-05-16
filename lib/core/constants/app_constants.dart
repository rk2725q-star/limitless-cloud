class AppConstants {
  // ── App Info ───────────────────────────────────────────────────────────────
  static const String appName = 'Limitless Cloud';
  static const String appVersion = '1.0.0';
  static const String appTagline = 'Unlimited Storage. Zero Cost.';

  // ── Telegram API ──────────────────────────────────────────────────────────
  // Credentials from my.telegram.org → API Development Tools
  // ⚠️  Keep these private – do not commit to public repos.
  static const int telegramApiId = 36148181;
  static const String telegramApiHash = 'cf8e8509b0ceaf5b229ad47f59b79e6e';

  // ── Backend Server ────────────────────────────────────────────────────────
  // Local development: run server/start_server.bat, then use your PC's LAN IP
  // so the Android device on the same Wi-Fi can reach it.
  // Example: 'http://192.168.1.5:8000'  (replace with your actual LAN IP)
  // For production, deploy the server and set the public URL here.
  static const String backendBaseUrl = 'http://10.0.2.2:8000'; // Android emulator localhost
  // static const String backendBaseUrl = 'http://192.168.1.5:8000'; // real device on LAN

  // ── Firestore Collections ─────────────────────────────────────────────────
  static const String usersCollection = 'users';
  static const String foldersCollection = 'folders';
  static const String filesCollection = 'files';
  static const String trashCollection = 'trash';

  // ── Hive Boxes ────────────────────────────────────────────────────────────
  static const String sessionBox = 'session_box';
  static const String cacheBox = 'cache_box';
  static const String settingsBox = 'settings_box';

  // ── Hive Keys ─────────────────────────────────────────────────────────────
  static const String keyTelegramSession = 'telegram_session';
  static const String keyUserId = 'user_id';
  static const String keyPhoneNumber = 'phone_number';
  static const String keyDisplayName = 'display_name';
  static const String keyViewMode = 'view_mode'; // 'grid' | 'list'
  static const String keySortMode = 'sort_mode'; // 'name' | 'date' | 'size'
  static const String keyTheme = 'theme_mode';

  // ── File Limits ────────────────────────────────────────────────────────────
  static const int maxFileSizeBytes = 4 * 1024 * 1024 * 1024; // 4GB (Telegram max)
  static const int chunkSize = 512 * 1024; // 512KB chunks for upload

  // ── Pagination ─────────────────────────────────────────────────────────────
  static const int pageSize = 50;

  // ── UI Constants ──────────────────────────────────────────────────────────
  static const double borderRadius = 16.0;
  static const double cardPadding = 16.0;
  static const double screenPadding = 20.0;
  static const double fabSize = 60.0;

  // ── Animation Durations ───────────────────────────────────────────────────
  static const Duration fastAnimation = Duration(milliseconds: 200);
  static const Duration normalAnimation = Duration(milliseconds: 350);
  static const Duration slowAnimation = Duration(milliseconds: 600);

  // ── File Type Extensions ──────────────────────────────────────────────────
  static const List<String> imageExtensions = [
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'heic', 'tiff'
  ];
  static const List<String> videoExtensions = [
    'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', '3gp'
  ];
  static const List<String> audioExtensions = [
    'mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma', 'opus'
  ];
  static const List<String> documentExtensions = [
    'pdf', 'doc', 'docx', 'odt', 'rtf', 'txt', 'md'
  ];
  static const List<String> spreadsheetExtensions = [
    'xls', 'xlsx', 'ods', 'csv'
  ];
  static const List<String> presentationExtensions = [
    'ppt', 'pptx', 'odp'
  ];
  static const List<String> archiveExtensions = [
    'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'
  ];
  static const List<String> codeExtensions = [
    'dart', 'py', 'js', 'ts', 'html', 'css', 'java', 'kt', 'swift',
    'go', 'rs', 'cpp', 'c', 'h', 'json', 'xml', 'yaml', 'yml', 'sh'
  ];
  static const List<String> apkExtensions = ['apk', 'aab', 'ipa'];
}
