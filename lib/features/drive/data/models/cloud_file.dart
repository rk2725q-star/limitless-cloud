import 'dart:convert';

class CloudFile {
  final String id;
  final String name;
  final String? folderId;
  final String folderPath;
  final int telegramMessageId;
  final String telegramFileId;
  final String? mimeType;
  final int sizeBytes;
  final String extension;
  final String? thumbnailPath;
  final bool isStarred;
  final bool isTrashed;
  final DateTime uploadedAt;
  final DateTime updatedAt;

  /// For files split into multiple Telegram messages (>2 GB).
  /// Empty list means the file is a single message (stored in [telegramMessageId]).
  final List<int> chunkMessageIds;

  bool get isChunked => chunkMessageIds.isNotEmpty;

  CloudFile({
    required this.id,
    required this.name,
    this.folderId,
    required this.folderPath,
    required this.telegramMessageId,
    required this.telegramFileId,
    this.mimeType,
    required this.sizeBytes,
    required this.extension,
    this.thumbnailPath,
    this.isStarred = false,
    this.isTrashed = false,
    required this.uploadedAt,
    required this.updatedAt,
    this.chunkMessageIds = const [],
  });

  CloudFile copyWith({
    String? id,
    String? name,
    String? folderId,
    String? folderPath,
    int? telegramMessageId,
    String? telegramFileId,
    String? mimeType,
    int? sizeBytes,
    String? extension,
    String? thumbnailPath,
    bool? isStarred,
    bool? isTrashed,
    DateTime? uploadedAt,
    DateTime? updatedAt,
    List<int>? chunkMessageIds,
  }) {
    return CloudFile(
      id: id ?? this.id,
      name: name ?? this.name,
      folderId: folderId ?? this.folderId,
      folderPath: folderPath ?? this.folderPath,
      telegramMessageId: telegramMessageId ?? this.telegramMessageId,
      telegramFileId: telegramFileId ?? this.telegramFileId,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      extension: extension ?? this.extension,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      isStarred: isStarred ?? this.isStarred,
      isTrashed: isTrashed ?? this.isTrashed,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      chunkMessageIds: chunkMessageIds ?? this.chunkMessageIds,
    );
  }

  /// Encode chunk IDs as JSON string for DB storage
  String get chunkIdsJson => jsonEncode(chunkMessageIds);

  static List<int> parseChunkIds(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      return (jsonDecode(json) as List<dynamic>).cast<int>();
    } catch (_) {
      return [];
    }
  }
}
