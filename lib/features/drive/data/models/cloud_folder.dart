class CloudFolder {
  final String id;
  final String name;
  final String? parentFolderId;
  final String path;
  final String color;
  final int itemCount;
  final bool isTrashed;
  final DateTime createdAt;
  final DateTime updatedAt;

  CloudFolder({
    required this.id,
    required this.name,
    this.parentFolderId,
    required this.path,
    this.color = '#4F8CFF',
    this.itemCount = 0,
    this.isTrashed = false,
    required this.createdAt,
    required this.updatedAt,
  });

  CloudFolder copyWith({
    String? id,
    String? name,
    String? parentFolderId,
    String? path,
    String? color,
    int? itemCount,
    bool? isTrashed,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CloudFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      parentFolderId: parentFolderId ?? this.parentFolderId,
      path: path ?? this.path,
      color: color ?? this.color,
      itemCount: itemCount ?? this.itemCount,
      isTrashed: isTrashed ?? this.isTrashed,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
