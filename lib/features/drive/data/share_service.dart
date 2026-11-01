import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../core/services/tdlib_service.dart';
import 'models/share_record.dart';
import 'models/cloud_file.dart';
import 'models/cloud_folder.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  DB singleton (shares table version 1)
// ─────────────────────────────────────────────────────────────────────────────

class _SharesDB {
  static Database? _db;

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dbPath = p.join(await getDatabasesPath(), 'limitless_shares.db');
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE shares (
            id              TEXT PRIMARY KEY,
            ownerUserId     TEXT NOT NULL,
            recipientUserId TEXT NOT NULL,
            recipientPhone  TEXT NOT NULL,
            recipientName   TEXT NOT NULL,
            fileId          TEXT,
            folderId        TEXT,
            itemName        TEXT NOT NULL,
            role            TEXT NOT NULL DEFAULT "viewer",
            metaMessageId   INTEGER DEFAULT 0,
            isRevoked       INTEGER DEFAULT 0,
            createdAt       TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_shares_owner ON shares(ownerUserId)');
        await db.execute(
          'CREATE INDEX idx_shares_recipient ON shares(recipientUserId)');
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Prefix used in Telegram captions for share metadata messages
// ─────────────────────────────────────────────────────────────────────────────

const _kSharePrefix = 'LIMITLESS_SHARE:';

// ─────────────────────────────────────────────────────────────────────────────
//  ShareService
// ─────────────────────────────────────────────────────────────────────────────

class ShareService {
  const ShareService();

  // ── Lookup recipient by phone number OR user ID / nickname ───────────────

  /// Resolves either a phone number or a username / custom ID to a Telegram user.
  /// Returns {userId, firstName, lastName, name, phone, username} or throws.
  Future<Map<String, dynamic>> lookupRecipient(String query) async {
    final tdlib = TdlibService.instance;
    final trimmed = query.trim();
    if (trimmed.isEmpty) throw Exception('Please enter a phone number or user ID');

    final isPhone = trimmed.startsWith('+') ||
        (RegExp(r'^\d+$').hasMatch(trimmed.replaceAll(RegExp(r'[\s\-]'), '')) && trimmed.length >= 7);

    if (isPhone) {
      try {
        final resp = await tdlib.sendRaw({
          '@type': 'searchUserByPhoneNumber',
          'phone_number': trimmed,
        });
        final firstName = resp['first_name'] as String? ?? '';
        final lastName  = resp['last_name']  as String? ?? '';
        final username  = (resp['usernames'] as Map<String, dynamic>?)?['editable_username'] as String?
            ?? resp['username'] as String? ?? '';
        return {
          'userId':    resp['id'].toString(),
          'firstName': firstName,
          'lastName':  lastName,
          'name':      '$firstName $lastName'.trim().isNotEmpty ? '$firstName $lastName'.trim() : (username.isNotEmpty ? '@$username' : trimmed),
          'phone':     resp['phone_number'] as String? ?? trimmed,
          'username':  username,
        };
      } catch (e) {
        throw Exception('No Telegram user found for phone $trimmed');
      }
    } else {
      // Lookup by username / custom ID
      final cleanUsername = trimmed.replaceAll('@', '');
      try {
        final chat = await tdlib.sendRaw({
          '@type': 'searchPublicChat',
          'username': cleanUsername,
        });
        final chatType = chat['type'] as Map<String, dynamic>?;
        if (chatType?['@type'] == 'chatTypePrivate') {
          final userId = chatType!['user_id'] as int;
          try {
            final user = await tdlib.sendRaw({
              '@type': 'getUser',
              'user_id': userId,
            });
            final firstName = user['first_name'] as String? ?? '';
            final lastName  = user['last_name']  as String? ?? '';
            final phone     = user['phone_number'] as String? ?? '';
            return {
              'userId':    userId.toString(),
              'firstName': firstName,
              'lastName':  lastName,
              'name':      '$firstName $lastName'.trim().isNotEmpty ? '$firstName $lastName'.trim() : '@$cleanUsername',
              'phone':     phone.isNotEmpty ? phone : '@$cleanUsername',
              'username':  cleanUsername,
            };
          } catch (_) {
            return {
              'userId':    userId.toString(),
              'firstName': chat['title'] as String? ?? '',
              'lastName':  '',
              'name':      chat['title'] as String? ?? '@$cleanUsername',
              'phone':     '@$cleanUsername',
              'username':  cleanUsername,
            };
          }
        } else {
          throw Exception('The ID "@$cleanUsername" is a group or channel, not a user.');
        }
      } catch (e) {
        throw Exception('No user found with ID or username "@$cleanUsername".');
      }
    }
  }

  /// Backward-compatible alias
  Future<Map<String, dynamic>> lookupUserByPhone(String phone) => lookupRecipient(phone);

  // ── Create share ──────────────────────────────────────────────────────────

  /// Share a [file] or [folder] with a recipient identified by phone or username.
  /// Returns the created [ShareRecord].
  Future<ShareRecord> shareItem({
    required String ownerUserId,
    required String phone,
    CloudFile?   file,
    CloudFolder? folder,
  }) async {
    assert(file != null || folder != null, 'Must share a file OR folder');

    // 1. Resolve recipient
    final user = await lookupRecipient(phone);

    final id        = _uuid();
    final now       = DateTime.now();
    final itemName  = file?.name ?? folder!.name;
    final fileId    = file?.id;
    final folderId  = folder?.id;

    final record = ShareRecord(
      id:              id,
      ownerUserId:     ownerUserId,
      recipientUserId: user['userId'] as String,
      recipientPhone:  (user['phone'] as String? ?? '').isNotEmpty
          ? (user['phone'] as String)
          : (user['username'] as String? ?? phone),
      recipientName:   user['name']   as String,
      fileId:          fileId,
      folderId:        folderId,
      itemName:        itemName,
      createdAt:       now,
    );

    // 2. Persist to local DB
    final db = await _SharesDB.instance;
    await db.insert('shares', _toRow(record));

    // 3. Persist share notification to Telegram Saved Messages so the
    //    RECIPIENT can sync it on their next app open.
    //    We send a special text message to OUR Saved Messages that the
    //    recipient's app will read during sync (it fetches messages tagged
    //    LIMITLESS_SHARE: addressed to their userId).
    try {
      final msgId = await _persistShareToTelegram(record);
      await db.update(
        'shares',
        {'metaMessageId': msgId},
        where: 'id = ?',
        whereArgs: [id],
      );
      return record.copyWith(metaMessageId: msgId);
    } catch (e) {
      debugPrint('[ShareService] Telegram persist failed: $e');
      // Still return the local record — it will sync later
      return record;
    }
  }

  // ── Revoke share ─────────────────────────────────────────────────────────

  Future<void> revokeShare(String shareId, String ownerUserId) async {
    final db = await _SharesDB.instance;
    await db.update(
      'shares',
      {'isRevoked': 1},
      where: 'id = ? AND ownerUserId = ?',
      whereArgs: [shareId, ownerUserId],
    );
    // Also update the Telegram message so recipients see revocation on sync
    final rows = await db.query('shares',
        where: 'id = ?', whereArgs: [shareId]);
    if (rows.isEmpty) return;
    final rec = _fromRow(rows.first);
    if (rec.metaMessageId > 0) {
      try {
        await _updateShareTelegram(rec.copyWith(isRevoked: true));
      } catch (e) {
        debugPrint('[ShareService] Revoke Telegram update failed: $e');
      }
    }
  }

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Returns all active shares created BY the owner (My Shares tab).
  Future<List<ShareRecord>> myShares(String ownerUserId) async {
    final db = await _SharesDB.instance;
    final rows = await db.query(
      'shares',
      where: 'ownerUserId = ? AND isRevoked = 0',
      whereArgs: [ownerUserId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns all active shares where [userId] is the recipient (Shared With Me).
  Future<List<ShareRecord>> sharedWithMe(String userId) async {
    final db = await _SharesDB.instance;
    final rows = await db.query(
      'shares',
      where: 'recipientUserId = ? AND isRevoked = 0',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns active shares for a specific [fileId] (for owner permission checks).
  Future<List<ShareRecord>> sharesForFile(String fileId) async {
    final db = await _SharesDB.instance;
    final rows = await db.query(
      'shares',
      where: 'fileId = ? AND isRevoked = 0',
      whereArgs: [fileId],
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns active shares for a specific [folderId].
  Future<List<ShareRecord>> sharesForFolder(String folderId) async {
    final db = await _SharesDB.instance;
    final rows = await db.query(
      'shares',
      where: 'folderId = ? AND isRevoked = 0',
      whereArgs: [folderId],
    );
    return rows.map(_fromRow).toList();
  }

  // ── Sync from Telegram ────────────────────────────────────────────────────

  /// Scans Telegram Saved Messages for LIMITLESS_SHARE: messages addressed
  /// to [currentUserId] and upserts them into the local DB.
  /// Called during app sync to populate "Shared with me".
  Future<void> syncSharedWithMe(String currentUserId) async {
    try {
      final tdlib  = TdlibService.instance;
      final chatId = await tdlib.getStorageChatId();
      final db     = await _SharesDB.instance;

      // Fetch up to 200 messages from Saved Messages
      final resp = await tdlib.sendRaw({
        '@type':            'searchChatMessages',
        'chat_id':          chatId,
        'query':            _kSharePrefix,
        'from_message_id':  0,
        'offset':           0,
        'limit':            200,
        'filter':           {'@type': 'searchMessagesFilterEmpty'},
      });

      final messages = resp['messages'] as List? ?? [];
      for (final msg in messages) {
        final content = msg['content'] as Map<String, dynamic>?;
        final text    = (content?['text'] as Map<String, dynamic>?)?['text'] as String?;
        if (text == null || !text.startsWith(_kSharePrefix)) continue;

        try {
          final json = text.substring(_kSharePrefix.length);
          final rec  = ShareRecord.fromJsonString(json);

          // Only import shares addressed to ME
          if (rec.recipientUserId != currentUserId) continue;

          // Upsert
          final existing = await db.query('shares',
              where: 'id = ?', whereArgs: [rec.id]);
          if (existing.isEmpty) {
            await db.insert('shares', _toRow(rec.copyWith(
              metaMessageId: msg['id'] as int? ?? 0,
            )));
          } else {
            // Update revocation status
            await db.update(
              'shares',
              {'isRevoked': rec.isRevoked ? 1 : 0},
              where: 'id = ?',
              whereArgs: [rec.id],
            );
          }
        } catch (e) {
          debugPrint('[ShareService] Malformed share message: $e');
        }
      }
    } catch (e) {
      debugPrint('[ShareService] syncSharedWithMe error: $e');
    }
  }

  // ── Permission check ─────────────────────────────────────────────────────

  /// Returns true if [userId] owns the file/folder with given ID.
  bool isOwner(String ownerUserId, String currentUserId) =>
      ownerUserId == currentUserId;

  // ── Telegram persistence ─────────────────────────────────────────────────

  Future<int> _persistShareToTelegram(ShareRecord rec) async {
    final tdlib  = TdlibService.instance;
    final chatId = await tdlib.getStorageChatId();
    final text   = '$_kSharePrefix${rec.toJsonString()}';

    final resp = await tdlib.sendRaw({
      '@type':   'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text':  {'@type': 'formattedText', 'text': text, 'entities': []},
      },
    });
    return resp['id'] as int? ?? 0;
  }

  Future<void> _updateShareTelegram(ShareRecord rec) async {
    if (rec.metaMessageId <= 0) return;
    final tdlib  = TdlibService.instance;
    final chatId = await tdlib.getStorageChatId();
    final text   = '$_kSharePrefix${rec.toJsonString()}';

    await tdlib.sendRaw({
      '@type':      'editMessageText',
      'chat_id':    chatId,
      'message_id': rec.metaMessageId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text':  {'@type': 'formattedText', 'text': text, 'entities': []},
      },
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Map<String, dynamic> _toRow(ShareRecord r) => {
    'id':              r.id,
    'ownerUserId':     r.ownerUserId,
    'recipientUserId': r.recipientUserId,
    'recipientPhone':  r.recipientPhone,
    'recipientName':   r.recipientName,
    'fileId':          r.fileId,
    'folderId':        r.folderId,
    'itemName':        r.itemName,
    'role':            r.role.name,
    'metaMessageId':   r.metaMessageId,
    'isRevoked':       r.isRevoked ? 1 : 0,
    'createdAt':       r.createdAt.toIso8601String(),
  };

  ShareRecord _fromRow(Map<String, dynamic> r) => ShareRecord(
    id:              r['id']              as String,
    ownerUserId:     r['ownerUserId']     as String,
    recipientUserId: r['recipientUserId'] as String,
    recipientPhone:  r['recipientPhone']  as String,
    recipientName:   r['recipientName']   as String,
    fileId:          r['fileId']          as String?,
    folderId:        r['folderId']        as String?,
    itemName:        r['itemName']        as String,
    role:            ShareRole.viewer,
    metaMessageId:   (r['metaMessageId']  as int?) ?? 0,
    isRevoked:       (r['isRevoked']      as int?) == 1,
    createdAt:       DateTime.parse(r['createdAt'] as String),
  );

  String _uuid() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (1000 + (DateTime.now().millisecond % 9000)).toString();
}

