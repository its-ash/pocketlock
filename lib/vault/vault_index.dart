import 'dart:convert';
import 'dart:typed_data';

enum VaultKind { photo, video, file }

VaultKind kindForMime(String mime) {
  if (mime.startsWith('image/')) return VaultKind.photo;
  if (mime.startsWith('video/')) return VaultKind.video;
  return VaultKind.file;
}

/// One encrypted item. Names, sizes and dates live only in the encrypted index.
class VaultItem {
  const VaultItem({
    required this.id,
    required this.name,
    required this.mime,
    required this.kind,
    required this.size,
    required this.addedAt,
    required this.albumId,
    required this.hasThumb,
  });

  /// Random hex id. It is also the name of the encrypted blob on disk.
  final String id;
  final String name;
  final String mime;
  final VaultKind kind;

  /// Size of the original in bytes.
  final int size;
  final DateTime addedAt;
  final String albumId;
  final bool hasThumb;

  VaultItem copyWith({String? albumId}) => VaultItem(
    id: id,
    name: name,
    mime: mime,
    kind: kind,
    size: size,
    addedAt: addedAt,
    albumId: albumId ?? this.albumId,
    hasThumb: hasThumb,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'kind': kind.name,
    'size': size,
    'addedAt': addedAt.millisecondsSinceEpoch,
    'albumId': albumId,
    'hasThumb': hasThumb,
  };

  factory VaultItem.fromJson(Map<String, Object?> json) => VaultItem(
    id: json['id']! as String,
    name: json['name']! as String,
    mime: json['mime']! as String,
    kind: VaultKind.values.byName(json['kind']! as String),
    size: json['size']! as int,
    addedAt: DateTime.fromMillisecondsSinceEpoch(json['addedAt']! as int),
    albumId: json['albumId']! as String,
    hasThumb: json['hasThumb']! as bool,
  );
}

class VaultAlbum {
  const VaultAlbum({required this.id, required this.name});

  /// Id of the album every vault has. It cannot be deleted.
  static const defaultId = 'default';

  final String id;
  final String name;

  bool get isDefault => id == defaultId;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  factory VaultAlbum.fromJson(Map<String, Object?> json) =>
      VaultAlbum(id: json['id']! as String, name: json['name']! as String);
}

/// The vault's table of contents. Stored as one encrypted file.
class VaultIndex {
  VaultIndex({List<VaultAlbum>? albums, List<VaultItem>? items})
    : albums = albums ?? [const VaultAlbum(id: VaultAlbum.defaultId, name: 'Unsorted')],
      items = items ?? [];

  static const version = 1;

  final List<VaultAlbum> albums;
  final List<VaultItem> items;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'albums': [for (final a in albums) a.toJson()],
        'items': [for (final i in items) i.toJson()],
      }),
    ),
  );

  factory VaultIndex.decode(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final albums = [
      for (final a in json['albums']! as List) VaultAlbum.fromJson((a as Map).cast<String, Object?>()),
    ];
    if (!albums.any((a) => a.isDefault)) {
      albums.insert(0, const VaultAlbum(id: VaultAlbum.defaultId, name: 'Unsorted'));
    }
    return VaultIndex(
      albums: albums,
      items: [for (final i in json['items']! as List) VaultItem.fromJson((i as Map).cast<String, Object?>())],
    );
  }
}
