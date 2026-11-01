import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/drive/data/models/cloud_file.dart';
import 'tdlib_service.dart';

/// Represents a detected and clustered person with avatar and associated file IDs.
class PersonGroup {
  final String id;
  String name;
  final String avatarPath;
  final List<String> fileIds;
  final List<double> featureVector;
  DateTime updatedAt;

  PersonGroup({
    required this.id,
    required this.name,
    required this.avatarPath,
    required this.fileIds,
    required this.featureVector,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatarPath': avatarPath,
        'fileIds': fileIds,
        'featureVector': featureVector,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PersonGroup.fromJson(Map<String, dynamic> json) {
    return PersonGroup(
      id: json['id'] as String,
      name: json['name'] as String,
      avatarPath: json['avatarPath'] as String,
      fileIds: (json['fileIds'] as List<dynamic>).cast<String>(),
      featureVector: (json['featureVector'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          [],
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class FaceDetectionService extends ChangeNotifier {
  static final FaceDetectionService instance = FaceDetectionService._();
  FaceDetectionService._();

  static const int _kFaceAlgoVersion = 5;
  FaceDetector? _detector;
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  final Map<String, List<PersonGroup>> _userPeopleCache = {};
  final Map<String, Set<String>> _scannedFileIdsCache = {};

  FaceDetector get _getDetector {
    _detector ??= FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableContours: true,
        enableClassification: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.05,
      ),
    );
    return _detector!;
  }

  /// Initialize and load saved people from SharedPreferences for a user.
  Future<List<PersonGroup>> getPeople(String userId) async {
    final prefs = await SharedPreferences.getInstance();

    // Migration / cache version check: auto-resets corrupt single-cluster data
    final currentVer = prefs.getInt('face_algo_version_$userId') ?? 0;
    if (currentVer < _kFaceAlgoVersion) {
      final customNames = <String>[];
      final oldRaw = prefs.getString('face_people_$userId');
      if (oldRaw != null && oldRaw.isNotEmpty) {
        try {
          final list = (jsonDecode(oldRaw) as List<dynamic>)
              .map((e) => PersonGroup.fromJson(e as Map<String, dynamic>));
          for (final p in list) {
            if (!p.name.startsWith('Person ') && p.name.trim().isNotEmpty) {
              customNames.add(p.name);
            }
          }
        } catch (_) {}
      }

      _userPeopleCache[userId] = [];
      _scannedFileIdsCache[userId] = {};
      await prefs.remove('face_people_$userId');
      await prefs.remove('face_scanned_$userId');
      await prefs.setInt('face_algo_version_$userId', _kFaceAlgoVersion);
      if (customNames.isNotEmpty) {
        await prefs.setStringList('face_custom_names_$userId', customNames);
      }
      return [];
    }

    if (_userPeopleCache.containsKey(userId)) {
      return _userPeopleCache[userId]!;
    }

    final raw = prefs.getString('face_people_$userId');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) => PersonGroup.fromJson(e as Map<String, dynamic>))
            .where((p) => p.fileIds.isNotEmpty && File(p.avatarPath).existsSync())
            .toList();
        _userPeopleCache[userId] = list;
      } catch (_) {
        _userPeopleCache[userId] = [];
      }
    } else {
      _userPeopleCache[userId] = [];
    }

    final scannedRaw = prefs.getStringList('face_scanned_$userId') ?? [];
    _scannedFileIdsCache[userId] = scannedRaw.toSet();

    return _userPeopleCache[userId]!;
  }

  /// Synchronous getter if already loaded, with optional activeFileIds filter
  List<PersonGroup> getCachedPeople(String userId, [Set<String>? activeFileIds]) {
    final list = _userPeopleCache[userId] ?? [];
    if (activeFileIds == null) {
      return list.where((p) => p.fileIds.isNotEmpty).toList();
    }
    return list.where((p) {
      return p.fileIds.any(activeFileIds.contains);
    }).toList();
  }

  /// Remove a deleted file from all people and auto-purge any person with 0 photos
  Future<void> onFileDeleted(String userId, String fileId) async {
    final people = await getPeople(userId);
    bool changed = false;
    for (final person in people) {
      if (person.fileIds.remove(fileId)) {
        changed = true;
      }
    }

    final toRemove = people.where((p) => p.fileIds.isEmpty).toList();
    for (final r in toRemove) {
      try {
        final f = File(r.avatarPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    people.removeWhere((p) => p.fileIds.isEmpty);
    _scannedFileIdsCache[userId]?.remove(fileId);

    if (changed || toRemove.isNotEmpty) {
      await _savePeople(userId);
      notifyListeners();
    }
  }

  /// Immediately purge deleted files from memory cache and prune any face with 0 photos
  void purgeOrphanedPeople(String userId, Set<String> activeFileIds) {
    final list = _userPeopleCache[userId];
    if (list == null) return;

    bool changed = false;
    for (final person in list) {
      final prev = person.fileIds.length;
      person.fileIds.removeWhere((id) => !activeFileIds.contains(id));
      if (person.fileIds.length != prev) changed = true;
    }

    final toRemove = list.where((p) => p.fileIds.isEmpty).toList();
    for (final r in toRemove) {
      try {
        final f = File(r.avatarPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    list.removeWhere((p) => p.fileIds.isEmpty);

    if (changed || toRemove.isNotEmpty) {
      _savePeople(userId);
      notifyListeners();
    }
  }

  /// Rename a detected person (e.g. "Person 1" -> "Manith")
  Future<void> renamePerson(String userId, String personId, String newName) async {
    final people = await getPeople(userId);
    final idx = people.indexWhere((p) => p.id == personId);
    if (idx != -1) {
      people[idx].name = newName.trim();
      people[idx].updatedAt = DateTime.now();
      await _savePeople(userId);
      notifyListeners();
    }
  }

  /// Delete a person cluster
  Future<void> deletePerson(String userId, String personId) async {
    final people = await getPeople(userId);
    final idx = people.indexWhere((p) => p.id == personId);
    if (idx != -1) {
      try {
        final f = File(people[idx].avatarPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      people.removeAt(idx);
      await _savePeople(userId);
      notifyListeners();
    }
  }

  /// Scans a list of cloud files in the background without blocking the UI.
  Future<void> batchScanImages(String userId, List<CloudFile> files) async {
    if (_isScanning) return;
    _isScanning = true;
    notifyListeners();

    try {
      final people = await getPeople(userId);
      final scannedSet = _scannedFileIdsCache[userId] ??= {};
      final activeFileIds = files.map((f) => f.id).toSet();

      // Immediately purge deleted files and any person who has 0 photos remaining
      bool purged = false;
      for (final person in people) {
        final beforeCount = person.fileIds.length;
        person.fileIds.removeWhere((id) => !activeFileIds.contains(id));
        if (person.fileIds.length != beforeCount) purged = true;
      }

      final orphaned = people.where((p) => p.fileIds.isEmpty).toList();
      for (final o in orphaned) {
        try {
          final f = File(o.avatarPath);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      people.removeWhere((p) => p.fileIds.isEmpty);
      scannedSet.removeWhere((id) => !activeFileIds.contains(id));

      if (purged || orphaned.isNotEmpty) {
        await _savePeople(userId);
      }

      for (final file in files) {
        if (scannedSet.contains(file.id)) continue;

        String? localPath = file.thumbnailPath;
        if (localPath == null || !File(localPath).existsSync()) {
          // 1. Check local Camera directories on device (e.g. auto backup photos)
          const cameraDirs = [
            '/storage/emulated/0/DCIM/Camera',
            '/storage/emulated/0/DCIM',
            '/storage/emulated/0/Pictures',
          ];
          for (final dirPath in cameraDirs) {
            final candidate = File('$dirPath/${file.name}');
            if (candidate.existsSync()) {
              localPath = candidate.path;
              break;
            }
          }

          // 2. If not found locally, try downloading via TDLib
          if (localPath == null && file.telegramThumbnailId != null && file.telegramThumbnailId! > 0) {
            try {
              localPath = await TdlibService.instance
                  .downloadThumbnail(file.telegramThumbnailId!);
            } catch (_) {}
          }
        }

        if (localPath != null && File(localPath).existsSync()) {
          final changed = await _processFileFaces(userId, file, localPath, people);
          scannedSet.add(file.id);
          if (changed) {
            await _savePeople(userId);
            notifyListeners();
          }
          // Yield to main event loop
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }

      await _savePeople(userId);
    } catch (e) {
      debugPrint('[FaceDetectionService] batchScan error: $e');
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Forces a complete re-scan of all photos and clears stale clusters
  Future<void> rescanAll(String userId, List<CloudFile> files) async {
    final prefs = await SharedPreferences.getInstance();
    _scannedFileIdsCache[userId] = {};
    _userPeopleCache[userId] = [];
    await prefs.remove('face_scanned_$userId');
    await prefs.remove('face_people_$userId');
    await batchScanImages(userId, files);
  }

  /// Scan a single freshly uploaded or viewed file
  Future<void> scanSingleFile(String userId, CloudFile file, String imagePath) async {
    final people = await getPeople(userId);
    final scannedSet = _scannedFileIdsCache[userId] ??= {};
    if (scannedSet.contains(file.id)) return;

    if (File(imagePath).existsSync()) {
      await _processFileFaces(userId, file, imagePath, people);
      scannedSet.add(file.id);
      await _savePeople(userId);
      notifyListeners();
    }
  }

  Future<bool> _processFileFaces(
    String userId,
    CloudFile file,
    String localPath,
    List<PersonGroup> people,
  ) async {
    bool changed = false;
    try {
      final inputImage = InputImage.fromFilePath(localPath);
      final faces = await _getDetector.processImage(inputImage);
      if (faces.isEmpty) return false;

      final fileBytes = await File(localPath).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return false;

      final appDir = await getApplicationDocumentsDirectory();
      final facesDir = Directory(p.join(appDir.path, 'faces'));
      if (!facesDir.existsSync()) {
        facesDir.createSync(recursive: true);
      }

      // Track person IDs matched in THIS photo:
      // Multiple faces in the SAME photo MUST belong to different people!
      final matchedInThisFile = <String>{};

      for (int i = 0; i < faces.length; i++) {
        final face = faces[i];
        final box = face.boundingBox;

        // Add 25% margin around face bounding box for head avatar
        final marginX = (box.width * 0.25).round();
        final marginY = (box.height * 0.25).round();

        final cropX = (box.left - marginX).clamp(0, decoded.width - 1).round();
        final cropY = (box.top - marginY).clamp(0, decoded.height - 1).round();
        final cropW = (box.width + marginX * 2).clamp(1, decoded.width - cropX).round();
        final cropH = (box.height + marginY * 2).clamp(1, decoded.height - cropY).round();

        final cropped = img.copyCrop(decoded, x: cropX, y: cropY, width: cropW, height: cropH);
        final resized = img.copyResize(cropped, width: 140, height: 140);
        final jpgBytes = img.encodeJpg(resized, quality: 85);

        final avatarFileName = '${userId}_face_${file.id}_$i.jpg';
        final avatarFile = File(p.join(facesDir.path, avatarFileName));
        await avatarFile.writeAsBytes(jpgBytes);

        // Compute 268-element normalized appearance + landmark geometry feature vector
        final features = _computeFeatureVector(face, resized);

        // Find best match among existing PersonGroups (excluding anyone already matched in this photo)
        PersonGroup? bestMatch;
        double highestSimilarity = -1.0;

        for (final p in people) {
          if (matchedInThisFile.contains(p.id)) continue;
          final sim = _computeSimilarity(features, p.featureVector);
          if (sim > highestSimilarity) {
            highestSimilarity = sim;
            bestMatch = p;
          }
        }

        // Calibrated threshold for matching the exact same person
        if (bestMatch != null && highestSimilarity >= 0.80) {
          matchedInThisFile.add(bestMatch.id);
          if (!bestMatch.fileIds.contains(file.id)) {
            bestMatch.fileIds.add(file.id);
            bestMatch.updatedAt = DateTime.now();
            changed = true;
          }
          // Conservative adaptation to prevent feature drift
          _adaptFeatureVector(bestMatch.featureVector, features);
        } else {
          // New person cluster
          String personName = 'Person ${people.length + 1}';
          final prefs = await SharedPreferences.getInstance();
          final customNames = prefs.getStringList('face_custom_names_$userId');
          if (customNames != null && customNames.isNotEmpty && people.isEmpty) {
            personName = customNames.first;
          }

          final newPerson = PersonGroup(
            id: 'person_${DateTime.now().millisecondsSinceEpoch}_${people.length}_$i',
            name: personName,
            avatarPath: avatarFile.path,
            fileIds: [file.id],
            featureVector: List<double>.from(features),
            updatedAt: DateTime.now(),
          );
          matchedInThisFile.add(newPerson.id);
          people.add(newPerson);
          changed = true;
        }
      }
    } catch (e) {
      debugPrint('[FaceDetectionService] Face crop error on ${file.id}: $e');
    }
    return changed;
  }

  /// Calculates a 268-element vector:
  /// - 256 floats: 16x16 normalized grayscale appearance map (illumination-invariant)
  /// - 8 floats: facial landmark geometry ratios
  /// - 4 floats: facial contrast signatures (glasses, beard, hair, tone)
  List<double> _computeFeatureVector(Face face, img.Image faceCrop) {
    final List<double> vec = [];

    // 1. Appearance: 16x16 normalized grayscale grid (256 floats)
    final grayCrop = img.copyResize(faceCrop, width: 16, height: 16);
    final List<double> grayVals = [];
    double graySum = 0.0;
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 16; x++) {
        final pixel = grayCrop.getPixel(x, y);
        final lum = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        grayVals.add(lum);
        graySum += lum;
      }
    }
    final mean = graySum / 256.0;
    double varSum = 0.0;
    for (final g in grayVals) {
      final diff = g - mean;
      varSum += diff * diff;
    }
    final std = sqrt(varSum / 256.0);
    final denom = std < 1.0 ? 1.0 : std;
    for (final g in grayVals) {
      vec.add((g - mean) / denom);
    }

    // 2. Geometry: 8 landmark geometry ratios
    final box = face.boundingBox;
    final w = box.width.abs();
    final h = box.height.abs();
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final nose = face.landmarks[FaceLandmarkType.noseBase];
    final mouth = face.landmarks[FaceLandmarkType.bottomMouth];
    final leftMouth = face.landmarks[FaceLandmarkType.leftMouth];
    final rightMouth = face.landmarks[FaceLandmarkType.rightMouth];
    final leftCheek = face.landmarks[FaceLandmarkType.leftCheek];
    final rightCheek = face.landmarks[FaceLandmarkType.rightCheek];

    double eyeDist = w * 0.4;
    if (leftEye != null && rightEye != null) {
      final dx = (rightEye.position.x - leftEye.position.x).toDouble();
      final dy = (rightEye.position.y - leftEye.position.y).toDouble();
      eyeDist = sqrt(dx * dx + dy * dy);
    }
    if (eyeDist < 1.0) eyeDist = 1.0;

    // G1: Eye spacing ratio
    vec.add((eyeDist / (w > 0 ? w : 1.0)).clamp(0.1, 1.0));

    // G2: Nose vertical distance relative to eye spacing
    if (nose != null && leftEye != null && rightEye != null) {
      final eyeMidY = (leftEye.position.y + rightEye.position.y) / 2.0;
      final noseDistY = (nose.position.y - eyeMidY).toDouble();
      vec.add((noseDistY / eyeDist).clamp(0.1, 2.0));
    } else {
      vec.add(0.65);
    }

    // G3: Mouth vertical distance relative to eye spacing
    if (mouth != null && nose != null) {
      final mouthDistY = (mouth.position.y - nose.position.y).toDouble();
      vec.add((mouthDistY / eyeDist).clamp(0.1, 2.0));
    } else {
      vec.add(0.55);
    }

    // G4: Mouth width ratio relative to eye spacing
    if (leftMouth != null && rightMouth != null) {
      final mdx = (rightMouth.position.x - leftMouth.position.x).toDouble();
      final mdy = (rightMouth.position.y - leftMouth.position.y).toDouble();
      final mouthW = sqrt(mdx * mdx + mdy * mdy);
      vec.add((mouthW / eyeDist).clamp(0.2, 2.0));
    } else {
      vec.add(0.8);
    }

    // G5: Nose horizontal centering ratio
    if (nose != null && leftEye != null && rightEye != null) {
      final dLeft = (nose.position.x - leftEye.position.x).abs().toDouble();
      final dRight = (rightEye.position.x - nose.position.x).abs().toDouble();
      vec.add((dLeft / (dRight > 0 ? dRight : 1.0)).clamp(0.3, 3.0));
    } else {
      vec.add(1.0);
    }

    // G6: Face aspect ratio
    vec.add((h > 0 ? (w / h) : 0.85).clamp(0.3, 2.5));

    // G7: Cheek distance relative to eye spacing
    if (leftCheek != null && rightCheek != null) {
      final cdx = (rightCheek.position.x - leftCheek.position.x).toDouble();
      final cdy = (rightCheek.position.y - leftCheek.position.y).toDouble();
      final cheekDist = sqrt(cdx * cdx + cdy * cdy);
      vec.add((cheekDist / eyeDist).clamp(0.5, 3.0));
    } else {
      vec.add(1.6);
    }

    // G8: Head roll
    vec.add((face.headEulerAngleZ ?? 0.0) / 90.0);

    // 3. Contrast Signatures (Glasses, Beard, Hair, Tone)
    double glassesAvg = 0.0;
    int glassesCount = 0;
    double cheekAvg = 0.0;
    int cheekCount = 0;
    double beardAvg = 0.0;
    int beardCount = 0;
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 16; x++) {
        final val = grayVals[y * 16 + x];
        if (y >= 5 && y <= 7 && x >= 3 && x <= 12) {
          glassesAvg += val;
          glassesCount++;
        }
        if (y >= 9 && y <= 11 && ((x >= 2 && x <= 4) || (x >= 11 && x <= 13))) {
          cheekAvg += val;
          cheekCount++;
        }
        if (y >= 12 && y <= 15 && x >= 4 && x <= 11) {
          beardAvg += val;
          beardCount++;
        }
      }
    }
    final gVal = glassesCount > 0 ? glassesAvg / glassesCount : mean;
    final cVal = cheekCount > 0 ? cheekAvg / cheekCount : mean;
    final bVal = beardCount > 0 ? beardAvg / beardCount : mean;

    vec.add(((gVal - cVal) / 128.0).clamp(-1.0, 1.0));
    vec.add(((bVal - cVal) / 128.0).clamp(-1.0, 1.0));
    vec.add((mean / 255.0).clamp(0.0, 1.0));
    vec.add((std / 128.0).clamp(0.0, 2.0));

    return vec;
  }

  /// Discriminates between different individuals using normalized appearance correlation,
  /// facial geometry, and contrast signatures.
  double _computeSimilarity(List<double> v1, List<double> v2) {
    if (v1.length < 268 || v2.length < 268) return 0.0;

    // 1. Appearance correlation: Pearson normalized cross-correlation
    double dot = 0.0;
    for (int i = 0; i < 256; i++) {
      dot += v1[i] * v2[i];
    }
    final appCorr = (dot / 256.0).clamp(-1.0, 1.0);

    // 2. Geometry distance
    double geomDist = 0.0;
    for (int i = 256; i < 264; i++) {
      geomDist += (v1[i] - v2[i]).abs();
    }
    geomDist /= 8.0;
    final geomSim = (1.0 - geomDist * 1.5).clamp(0.0, 1.0);

    // 3. Contrast distance
    double contrastDist = 0.0;
    for (int i = 264; i < 268; i++) {
      contrastDist += (v1[i] - v2[i]).abs();
    }
    contrastDist /= 4.0;
    final contrastSim = (1.0 - contrastDist * 1.5).clamp(0.0, 1.0);

    double score = 0.65 * appCorr + 0.20 * geomSim + 0.15 * contrastSim;

    // Strong discriminator: if glasses or facial hair contrast differs notably
    final glassesDiff = (v1[264] - v2[264]).abs();
    if (glassesDiff > 0.35) {
      score -= 0.15; // strong penalty: one has glasses/frames, the other does not
    }

    return score.clamp(0.0, 1.0);
  }

  void _adaptFeatureVector(List<double> target, List<double> incoming) {
    if (target.length != incoming.length) return;
    for (int i = 0; i < target.length; i++) {
      target[i] = 0.92 * target[i] + 0.08 * incoming[i];
    }
  }

  Future<void> _savePeople(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final people = _userPeopleCache[userId] ?? [];
    final jsonList = people.map((p) => p.toJson()).toList();
    await prefs.setString('face_people_$userId', jsonEncode(jsonList));

    final scanned = _scannedFileIdsCache[userId]?.toList() ?? [];
    await prefs.setStringList('face_scanned_$userId', scanned);
  }

  @override
  void dispose() {
    _detector?.close();
    super.dispose();
  }
}
