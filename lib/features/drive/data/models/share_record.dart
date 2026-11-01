import 'dart:convert';

/// Who can access: currently always 'viewer' — recipient can only read/download.
/// Future: 'editor' for write access.
enum ShareRole { viewer }

/// A single share record — owner shared [fileId] or [folderId] with [recipientUserId].
class ShareRecord {
  final String id;

  /// The Telegram user ID of the file/folder owner.
  final String ownerUserId;

  /// The Telegram user ID of the person the share was sent to.
  final String recipientUserId;

  /// Recipient's phone number (E.164 format, e.g. +919XXXXXXXXX).
  final String recipientPhone;

  /// Recipient's Telegram display name (first + last), for UI.
  final String recipientName;

  /// Shared file ID — null if sharing a folder.
  final String? fileId;

  /// Shared folder ID — null if sharing a file.
  final String? folderId;

  /// Human-readable name of the shared item (filename or folder name).
  final String itemName;

  final ShareRole role;

  /// Telegram message ID of the LIMITLESS_SHARE: metadata message in Saved Messages.
  /// 0 = not yet persisted.
  final int metaMessageId;

  /// Whether the owner has revoked the share.
  final bool isRevoked;

  final DateTime createdAt;

  ShareRecord({
    required this.id,
    required this.ownerUserId,
    required this.recipientUserId,
    required this.recipientPhone,
    required this.recipientName,
    this.fileId,
    this.folderId,
    required this.itemName,
    this.role = ShareRole.viewer,
    this.metaMessageId = 0,
    this.isRevoked = false,
    required this.createdAt,
  });

  bool get isFileShare   => fileId != null;
  bool get isFolderShare => folderId != null;

  ShareRecord copyWith({
    String? id,
    String? ownerUserId,
    String? recipientUserId,
    String? recipientPhone,
    String? recipientName,
    String? fileId,
    String? folderId,
    String? itemName,
    ShareRole? role,
    int? metaMessageId,
    bool? isRevoked,
    DateTime? createdAt,
  }) {
    return ShareRecord(
      id:               id              ?? this.id,
      ownerUserId:      ownerUserId     ?? this.ownerUserId,
      recipientUserId:  recipientUserId ?? this.recipientUserId,
      recipientPhone:   recipientPhone  ?? this.recipientPhone,
      recipientName:    recipientName   ?? this.recipientName,
      fileId:           fileId          ?? this.fileId,
      folderId:         folderId        ?? this.folderId,
      itemName:         itemName        ?? this.itemName,
      role:             role            ?? this.role,
      metaMessageId:    metaMessageId   ?? this.metaMessageId,
      isRevoked:        isRevoked       ?? this.isRevoked,
      createdAt:        createdAt       ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id':              id,
    'ownerUserId':     ownerUserId,
    'recipientUserId': recipientUserId,
    'recipientPhone':  recipientPhone,
    'recipientName':   recipientName,
    if (fileId   != null) 'fileId':   fileId,
    if (folderId != null) 'folderId': folderId,
    'itemName':        itemName,
    'role':            role.name,
    'isRevoked':       isRevoked,
    'createdAt':       createdAt.toIso8601String(),
  };

  static ShareRecord fromJson(Map<String, dynamic> j) => ShareRecord(
    id:              j['id']              as String,
    ownerUserId:     j['ownerUserId']     as String,
    recipientUserId: j['recipientUserId'] as String,
    recipientPhone:  j['recipientPhone']  as String,
    recipientName:   j['recipientName']   as String,
    fileId:          j['fileId']          as String?,
    folderId:        j['folderId']        as String?,
    itemName:        j['itemName']        as String,
    role:            j['role'] == 'editor' ? ShareRole.viewer : ShareRole.viewer,
    isRevoked:       (j['isRevoked'] as bool?) ?? false,
    createdAt:       DateTime.parse(j['createdAt'] as String),
  );

  String toJsonString() => jsonEncode(toJson());
  static ShareRecord fromJsonString(String s) => fromJson(jsonDecode(s) as Map<String, dynamic>);
}

