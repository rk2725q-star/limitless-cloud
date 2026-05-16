import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

class FileUtils {
  /// Returns the file type category from extension
  static String getFileType(String extension) {
    final ext = extension.toLowerCase().replaceAll('.', '');
    if (AppConstants.imageExtensions.contains(ext)) return 'image';
    if (AppConstants.videoExtensions.contains(ext)) return 'video';
    if (AppConstants.audioExtensions.contains(ext)) return 'audio';
    if (AppConstants.documentExtensions.contains(ext)) return 'document';
    if (AppConstants.spreadsheetExtensions.contains(ext)) return 'spreadsheet';
    if (AppConstants.presentationExtensions.contains(ext)) return 'presentation';
    if (AppConstants.archiveExtensions.contains(ext)) return 'archive';
    if (AppConstants.codeExtensions.contains(ext)) return 'code';
    if (AppConstants.apkExtensions.contains(ext)) return 'apk';
    return 'other';
  }

  /// Returns the display icon for a file type
  static IconData getFileIcon(String extension) {
    final type = getFileType(extension);
    switch (type) {
      case 'image':
        return Icons.image_rounded;
      case 'video':
        return Icons.play_circle_filled_rounded;
      case 'audio':
        return Icons.music_note_rounded;
      case 'document':
        return extension.toLowerCase() == 'pdf'
            ? Icons.picture_as_pdf_rounded
            : Icons.description_rounded;
      case 'spreadsheet':
        return Icons.table_chart_rounded;
      case 'presentation':
        return Icons.slideshow_rounded;
      case 'archive':
        return Icons.folder_zip_rounded;
      case 'code':
        return Icons.code_rounded;
      case 'apk':
        return Icons.android_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  /// Returns the color for a file type
  static Color getFileColor(String extension) {
    final ext = extension.toLowerCase().replaceAll('.', '');
    final type = getFileType(ext);
    switch (type) {
      case 'image':
        return AppTheme.fileColorImage;
      case 'video':
        return AppTheme.fileColorVideo;
      case 'audio':
        return AppTheme.fileColorAudio;
      case 'document':
        return ext == 'pdf' ? AppTheme.fileColorPDF : AppTheme.fileColorDoc;
      case 'spreadsheet':
        return AppTheme.fileColorSpreadsheet;
      case 'presentation':
        return AppTheme.fileColorPresentation;
      case 'archive':
        return AppTheme.fileColorArchive;
      case 'code':
        return AppTheme.fileColorCode;
      case 'apk':
        return AppTheme.fileColorAPK;
      default:
        return AppTheme.fileColorDefault;
    }
  }

  /// Formats bytes into a human-readable string
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Extracts extension from filename
  static String getExtension(String filename) {
    final parts = filename.split('.');
    if (parts.length <= 1) return '';
    return parts.last.toLowerCase();
  }

  /// Generates a safe filename (removes special characters)
  static String sanitizeFilename(String filename) {
    return filename.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  /// Gets MIME type display name
  static String getMimeDisplayName(String? mimeType) {
    if (mimeType == null) return 'Unknown';
    final parts = mimeType.split('/');
    if (parts.length < 2) return mimeType;
    switch (mimeType) {
      case 'application/pdf':
        return 'PDF Document';
      case 'application/zip':
        return 'ZIP Archive';
      case 'application/x-rar-compressed':
        return 'RAR Archive';
      case 'video/mp4':
        return 'MP4 Video';
      case 'audio/mpeg':
        return 'MP3 Audio';
      case 'image/jpeg':
        return 'JPEG Image';
      case 'image/png':
        return 'PNG Image';
      case 'text/plain':
        return 'Text File';
      default:
        return parts.last.toUpperCase();
    }
  }
}
