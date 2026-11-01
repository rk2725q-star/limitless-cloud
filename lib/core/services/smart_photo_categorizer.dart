import 'package:flutter/material.dart';
import '../../../features/drive/data/models/cloud_file.dart';

// ── Smart Album Types (15 Essential Daily Categories) ────────────────────────

enum SmartAlbumType {
  travel,
  food,
  portraits,
  nature,
  pets,
  receipts,
  idCards,
  notesDocs,
  screenshots,
  events,
  shopping,
  vehicles,
  fitness,
  memes,
  camera,
}

class SmartAlbum {
  final SmartAlbumType type;
  final String title;
  final String subtitle;
  final String emptyHint;
  final IconData icon;
  final Color color;
  final List<CloudFile> files;

  const SmartAlbum({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.emptyHint,
    required this.icon,
    required this.color,
    required this.files,
  });

  int get count => files.length;
  CloudFile? get coverPhoto => files.isNotEmpty ? files.first : null;
}

// ── Categorizer Engine ───────────────────────────────────────────────────────

class SmartPhotoCategorizer {
  // 1. Food & Dining
  static const _foodKeywords = [
    'food', 'dinner', 'lunch', 'breakfast', 'meal', 'cafe', 'restaurant',
    'dish', 'pizza', 'burger', 'coffee', 'tea', 'cake', 'biryani',
    'snack', 'cook', 'kitchen', 'recipe', 'hotel', 'eat', 'beverage', 'drink',
    'juice', 'sweet', 'icecream', 'dessert', 'roti', 'dosa', 'chicken', 'paneer'
  ];

  // 2. Trips & Travel
  static const _travelKeywords = [
    'travel', 'trip', 'tour', 'vacation', 'holiday', 'beach', 'mountain',
    'hill', 'flight', 'airport', 'resort', 'ooty', 'kodaikanal', 'goa',
    'kerala', 'paris', 'tokyo', 'dubai', 'roadtrip', 'journey', 'visit',
    'hotel', 'stay', 'explore', 'trek', 'sea', 'lake', 'station', 'taj'
  ];

  // 3. Nature & Outdoors
  static const _natureKeywords = [
    'nature', 'sunset', 'sunrise', 'sky', 'flower', 'garden', 'park',
    'tree', 'forest', 'river', 'waterfall', 'landscape', 'cloud',
    'mountain_view', 'greenery', 'plant', 'leaf', 'botanical'
  ];

  // 4. Pets & Animals
  static const _petKeywords = [
    'pet', 'dog', 'cat', 'puppy', 'kitten', 'bird', 'animal', 'cow',
    'horse', 'fish', 'zoo', 'wildlife', 'bark', 'meow', 'canine', 'feline', 'rabbit'
  ];

  // 5. Bills & Receipts
  static const _receiptKeywords = [
    'bill', 'receipt', 'invoice', 'payment', 'gpay', 'phonepe', 'paytm',
    'upi', 'transaction', 'recharge', 'order_receipt', 'paid', 'gas_bill',
    'eb_bill', 'ticket', 'boarding', 'charge', 'amount', 'fee'
  ];

  // 6. Cards & Identity
  static const _idCardKeywords = [
    'aadhaar', 'aadhar', 'pan', 'license', 'licence', 'voter', 'passport',
    'id_card', 'identity', 'badge', 'card', 'atm', 'debit', 'credit',
    'bank_card', 'membership', 'visa', 'smart_card'
  ];

  // 7. Notes & Documents
  static const _notesDocsKeywords = [
    'note', 'notes', 'whiteboard', 'blackboard', 'study', 'doc', 'document',
    'paper', 'page', 'handwritten', 'assignment', 'homework', 'exam',
    'certificate', 'letter', 'contract', 'scan', 'form', 'textbook'
  ];

  // 8. Screenshots
  static const _screenshotKeywords = [
    'screenshot', 'screen_shot', 'screen', 'snap', 'capture_20', 'screencap'
  ];

  // 9. Portraits & Selfies
  static const _portraitKeywords = [
    'selfie', 'portrait', 'face', 'dp', 'profile', 'front', 'me', 'smile',
    'pose', 'person', 'people'
  ];

  // 10. Events & Celebrations
  static const _eventKeywords = [
    'wedding', 'birthday', 'anniversary', 'party', 'festival', 'celebration',
    'diwali', 'deepavali', 'pongal', 'eid', 'christmas', 'newyear',
    'ceremony', 'function', 'pooja', 'puja', 'concert', 'gathering'
  ];

  // 11. Shopping & Deliveries
  static const _shoppingKeywords = [
    'shopping', 'amazon', 'flipkart', 'myntra', 'parcel', 'package',
    'delivery', 'unboxing', 'clothes', 'dress', 'shoe', 'shoes', 'watch',
    'order', 'cart', 'box', 'courier'
  ];

  // 12. Vehicles & Rides
  static const _vehicleKeywords = [
    'car', 'bike', 'motorcycle', 'scooter', 'bullet', 'royalenfield',
    'ride', 'drive', 'vehicle', 'auto', 'bus', 'train', 'metro',
    'mechanic', 'service', 'wheels', 'honda', 'yamaha', 'bmw', 'audi'
  ];

  // 13. Fitness & Sports
  static const _fitnessKeywords = [
    'gym', 'workout', 'fitness', 'exercise', 'running', 'cycling',
    'marathon', 'sport', 'cricket', 'football', 'badminton', 'tennis',
    'yoga', 'bodybuilding', 'training', 'muscle', 'health'
  ];

  // 14. Memes & Graphics
  static const _memeKeywords = [
    'meme', 'funny', 'joke', 'wallpaper', 'sticker', 'illustration',
    'graphic', 'poster', 'quote', 'status', 'comic', 'humor', 'art'
  ];

  /// Categorizes a list of image files into Google Photos style Smart Albums across 15 daily categories.
  static List<SmartAlbum> categorize(List<CloudFile> allImages) {
    final travelFiles      = <CloudFile>[];
    final foodFiles        = <CloudFile>[];
    final portraitFiles    = <CloudFile>[];
    final natureFiles      = <CloudFile>[];
    final petFiles         = <CloudFile>[];
    final receiptFiles     = <CloudFile>[];
    final idCardFiles      = <CloudFile>[];
    final docFiles         = <CloudFile>[];
    final screenshotFiles  = <CloudFile>[];
    final eventFiles       = <CloudFile>[];
    final shoppingFiles    = <CloudFile>[];
    final vehicleFiles     = <CloudFile>[];
    final fitnessFiles     = <CloudFile>[];
    final memeFiles        = <CloudFile>[];
    final cameraFiles      = <CloudFile>[];

    for (final file in allImages) {
      final nameLower = file.name.toLowerCase();
      final pathLower = file.folderPath.toLowerCase();
      final combined  = '$pathLower/$nameLower';

      // 1. Screenshots
      if (_matchesAny(combined, _screenshotKeywords) || pathLower.contains('screenshot')) {
        screenshotFiles.add(file);
        continue;
      }

      // 2. Receipts & Bills
      if (_matchesAny(combined, _receiptKeywords)) {
        receiptFiles.add(file);
        continue;
      }

      // 3. ID & Cards
      if (_matchesAny(combined, _idCardKeywords)) {
        idCardFiles.add(file);
        continue;
      }

      // 4. Notes & Documents
      if (_matchesAny(combined, _notesDocsKeywords) || pathLower.contains('document')) {
        docFiles.add(file);
        continue;
      }

      // 5. Food & Dining
      if (_matchesAny(combined, _foodKeywords)) {
        foodFiles.add(file);
        continue;
      }

      // 6. Pets & Animals
      if (_matchesAny(combined, _petKeywords)) {
        petFiles.add(file);
        continue;
      }

      // 7. Events & Celebrations
      if (_matchesAny(combined, _eventKeywords)) {
        eventFiles.add(file);
        continue;
      }

      // 8. Shopping & Deliveries
      if (_matchesAny(combined, _shoppingKeywords)) {
        shoppingFiles.add(file);
        continue;
      }

      // 9. Vehicles & Rides
      if (_matchesAny(combined, _vehicleKeywords)) {
        vehicleFiles.add(file);
        continue;
      }

      // 10. Fitness & Sports
      if (_matchesAny(combined, _fitnessKeywords)) {
        fitnessFiles.add(file);
        continue;
      }

      // 11. Memes & Graphics
      if (_matchesAny(combined, _memeKeywords)) {
        memeFiles.add(file);
        continue;
      }

      // 12. Travel & Trips
      if (_matchesAny(combined, _travelKeywords)) {
        travelFiles.add(file);
        continue;
      }

      // 13. Nature & Outdoors
      if (_matchesAny(combined, _natureKeywords)) {
        natureFiles.add(file);
        continue;
      }

      // 14. Portraits & Selfies
      if (_matchesAny(combined, _portraitKeywords)) {
        portraitFiles.add(file);
        continue;
      }

      // 15. General Camera Captures (from DCIM/Camera, IMG_ prefixes, or camera captures)
      if (pathLower.contains('camera') ||
          pathLower.contains('dcim') ||
          nameLower.startsWith('img_') ||
          nameLower.startsWith('img20') ||
          nameLower.startsWith('pxl_') ||
          nameLower.startsWith('dji_') ||
          nameLower.startsWith('sam_')) {
        cameraFiles.add(file);
      }
    }

    final allAlbums = <SmartAlbum>[
      SmartAlbum(
        type: SmartAlbumType.travel,
        title: 'Trips & Travel',
        subtitle: '${travelFiles.length} moments',
        emptyHint: 'Photos of vacations, journeys, flights, and beaches will appear here.',
        icon: Icons.flight_takeoff_rounded,
        color: const Color(0xFF00C6FF),
        files: travelFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.food,
        title: 'Food & Dining',
        subtitle: '${foodFiles.length} photos',
        emptyHint: 'Photos of meals, cafes, dining, and snacks will appear here.',
        icon: Icons.restaurant_rounded,
        color: const Color(0xFFFF6B6B),
        files: foodFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.portraits,
        title: 'Portraits & Selfies',
        subtitle: '${portraitFiles.length} portraits',
        emptyHint: 'Selfies, portraits, and close-up face shots will appear here.',
        icon: Icons.face_rounded,
        color: const Color(0xFFFF9FF3),
        files: portraitFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.nature,
        title: 'Nature & Outdoors',
        subtitle: '${natureFiles.length} landscapes',
        emptyHint: 'Photos of sunsets, sky, greenery, and flowers will appear here.',
        icon: Icons.terrain_rounded,
        color: const Color(0xFF26DE81),
        files: natureFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.pets,
        title: 'Pets & Animals',
        subtitle: '${petFiles.length} moments',
        emptyHint: 'Cute photos of dogs, cats, birds, and pets will appear here.',
        icon: Icons.pets_rounded,
        color: const Color(0xFFFECA57),
        files: petFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.receipts,
        title: 'Bills & Receipts',
        subtitle: '${receiptFiles.length} receipts',
        emptyHint: 'UPI payment screenshots, store bills, and invoices will appear here.',
        icon: Icons.receipt_long_rounded,
        color: const Color(0xFF54A0FF),
        files: receiptFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.idCards,
        title: 'Cards & Identity',
        subtitle: '${idCardFiles.length} cards',
        emptyHint: 'Aadhaar, PAN, driving licenses, and ID cards will appear here.',
        icon: Icons.badge_rounded,
        color: const Color(0xFF9C88FF),
        files: idCardFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.notesDocs,
        title: 'Notes & Documents',
        subtitle: '${docFiles.length} documents',
        emptyHint: 'Study notes, book pages, whiteboards, and forms will appear here.',
        icon: Icons.menu_book_rounded,
        color: const Color(0xFF48DBFB),
        files: docFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.screenshots,
        title: 'Screenshots',
        subtitle: '${screenshotFiles.length} captures',
        emptyHint: 'Screen grabs and app captures will appear here.',
        icon: Icons.phone_android_rounded,
        color: const Color(0xFFFFA502),
        files: screenshotFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.events,
        title: 'Events & Celebrations',
        subtitle: '${eventFiles.length} memories',
        emptyHint: 'Weddings, birthdays, festivals (Diwali, Pongal), and parties will appear here.',
        icon: Icons.celebration_rounded,
        color: const Color(0xFFFF4757),
        files: eventFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.shopping,
        title: 'Shopping & Deliveries',
        subtitle: '${shoppingFiles.length} items',
        emptyHint: 'Amazon/Flipkart parcels, clothes, and shopping wishlists will appear here.',
        icon: Icons.shopping_bag_rounded,
        color: const Color(0xFF1DD1A1),
        files: shoppingFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.vehicles,
        title: 'Vehicles & Rides',
        subtitle: '${vehicleFiles.length} rides',
        emptyHint: 'Cars, bikes, road drives, and rides will appear here.',
        icon: Icons.directions_car_rounded,
        color: const Color(0xFF00D2D3),
        files: vehicleFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.fitness,
        title: 'Fitness & Sports',
        subtitle: '${fitnessFiles.length} activities',
        emptyHint: 'Gym workouts, running, cycling, and sports photos will appear here.',
        icon: Icons.fitness_center_rounded,
        color: const Color(0xFFFF9F43),
        files: fitnessFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.memes,
        title: 'Memes & Graphics',
        subtitle: '${memeFiles.length} graphics',
        emptyHint: 'Memes, funny images, stickers, and wallpapers will appear here.',
        icon: Icons.sentiment_very_satisfied_rounded,
        color: const Color(0xFFEE5253),
        files: memeFiles,
      ),
      SmartAlbum(
        type: SmartAlbumType.camera,
        title: 'Camera Captures',
        subtitle: '${cameraFiles.length} photos',
        emptyHint: 'All direct camera shots from DCIM/Camera will appear here.',
        icon: Icons.photo_camera_rounded,
        color: const Color(0xFF5F27CD),
        files: cameraFiles,
      ),
    ];

    // Place albums that contain photos first, followed by the remaining categories
    final withPhotos = allAlbums.where((a) => a.count > 0).toList();
    final emptyAlbums = allAlbums.where((a) => a.count == 0).toList();

    return [...withPhotos, ...emptyAlbums];
  }

  static bool _matchesAny(String text, List<String> keywords) {
    for (final kw in keywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }
}
