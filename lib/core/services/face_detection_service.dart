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

  FaceDetector? _detector;
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  final Map<String, List<PersonGroup>> _userPeopleCache = {};
  final Map<String, Set<String>> _scannedFileIdsCache = {};

  FaceDetector get _getDetector {
    _detector ??= FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableContours: false,
        enableClassification: false,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.12,
      ),
    );
    return _detector!;
  }

  /// Initialize and load saved people from SharedPreferences for a user.
  Future<List<PersonGroup>> getPeople(String userId) async {
    if (_userPeopleCache.containsKey(userId)) {
      return _userPeopleCache[userId]!;
    }

    final prefs = await SharedPreferences.getInstance();
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
          // If thumbnail not downloaded yet, try downloading via TDLib
          if (file.telegramThumbnailId != null && file.telegramThumbnailId! > 0) {
            try {
              localPath = await TdlibService.instance
                  .downloadThumbnail(file.telegramThumbnailId!);
            } catch (_) {}
          }
        }

        if (localPath != null && File(localPath).existsSync()) {
          await _processFileFaces(userId, file, localPath, people);
          scannedSet.add(file.id);
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

  Future<void> _processFileFaces(
    String userId,
    CloudFile file,
    String localPath,
    List<PersonGroup> people,
  ) async {
    try {
      final inputImage = InputImage.fromFilePath(localPath);
      final faces = await _getDetector.processImage(inputImage);
      if (faces.isEmpty) return;

      final fileBytes = await File(localPath).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final facesDir = Directory(p.join(appDir.path, 'faces'));
      if (!facesDir.existsSync()) {
        facesDir.createSync(recursive: true);
      }

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

        // Compute feature vector for clustering
        final features = _computeFeatureVector(face, resized);

        // Find best match among existing PersonGroups
        PersonGroup? bestMatch;
        double highestSimilarity = 0.0;

        for (final p in people) {
          final sim = _cosineSimilarity(features, p.featureVector);
          if (sim > highestSimilarity) {
            highestSimilarity = sim;
            bestMatch = p;
          }
        }

        // Threshold for grouping the same person
        if (bestMatch != null && highestSimilarity >= 0.72) {
          if (!bestMatch.fileIds.contains(file.id)) {
            bestMatch.fileIds.add(file.id);
            bestMatch.updatedAt = DateTime.now();
          }
        } else {
          // New person cluster
          final newPerson = PersonGroup(
            id: 'person_${DateTime.now().millisecondsSinceEpoch}_$i',
            name: 'Person ${people.length + 1}',
            avatarPath: avatarFile.path,
            fileIds: [file.id],
            featureVector: features,
            updatedAt: DateTime.now(),
          );
          people.add(newPerson);
        }
      }
    } catch (e) {
      debugPrint('[FaceDetectionService] Face crop error on ${file.id}: $e');
    }
  }

  /// Calculates facial geometry ratios and a 16-bin color histogram
  List<double> _computeFeatureVector(Face face, img.Image faceCrop) {
    final List<double> vec = [];
    final box = face.boundingBox;
    final w = box.width.abs();
    final h = box.height.abs();

    // 1. Aspect ratio
    vec.add((h > 0 ? (w / h) : 1.0).clamp(0.0, 3.0));

    // 2. Eye landmarks geometry
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final nose = face.landmarks[FaceLandmarkType.noseBase];
    final mouth = face.landmarks[FaceLandmarkType.bottomMouth];

    if (leftEye != null && rightEye != null) {
      final eyeDx = (rightEye.position.x - leftEye.position.x).toDouble();
      final eyeDy = (rightEye.position.y - leftEye.position.y).toDouble();
      final eyeDist = sqrt(eyeDx * eyeDx + eyeDy * eyeDy);
      vec.add(w > 0 ? (eyeDist / w) : 0.4);
    } else {
      vec.add(0.4);
    }

    if (nose != null && h > 0) {
      vec.add(((nose.position.y - box.top) / h).clamp(0.0, 1.0));
    } else {
      vec.add(0.5);
    }

    if (mouth != null && h > 0) {
      vec.add(((mouth.position.y - box.top) / h).clamp(0.0, 1.0));
    } else {
      vec.add(0.75);
    }

    // 3. 12-bin HSV color histogram from center face region
    final int centerX = faceCrop.width ~/ 4;
    final int centerY = faceCrop.height ~/ 4;
    final int centerW = faceCrop.width ~/ 2;
    final int centerH = faceCrop.height ~/ 2;

    final hist = List<double>.filled(12, 0.0);
    int count = 0;

    for (int y = centerY; y < centerY + centerH; y += 2) {
      for (int x = centerX; x < centerX + centerW; x += 2) {
        final pixel = faceCrop.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();

        // Convert to Hue [0..360]
        final maxC = max(r, max(g, b));
        final minC = min(r, min(g, b));
        final delta = maxC - minC;
        double hue = 0.0;
        if (delta > 0.0001) {
          if (maxC == r) {
            hue = 60 * (((g - b) / delta) % 6);
          } else if (maxC == g) {
            hue = 60 * (((b - r) / delta) + 2);
          } else {
            hue = 60 * (((r - g) / delta) + 4);
          }
        }
        if (hue < 0) hue += 360;

        final bin = ((hue / 360) * 12).floor().clamp(0, 11);
        hist[bin] += 1.0;
        count++;
      }
    }

    if (count > 0) {
      for (int k = 0; k < 12; k++) {
        vec.add(hist[k] / count);
      }
    } else {
      vec.addAll(List.filled(12, 0.0));
    }

    return vec;
  }

  double _cosineSimilarity(List<double> v1, List<double> v2) {
    if (v1.length != v2.length || v1.isEmpty) return 0.0;
    double dot = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;
    for (int i = 0; i < v1.length; i++) {
      dot += v1[i] * v2[i];
      norm1 += v1[i] * v1[i];
      norm2 += v2[i] * v2[i];
    }
    if (norm1 == 0 || norm2 == 0) return 0.0;
    return (dot / (sqrt(norm1) * sqrt(norm2))).clamp(0.0, 1.0);
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
