import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../vault/vault_store.dart';

/// An image that is decrypted on demand, in memory only.
///
/// Works with `Image`, `ImageCache` (in memory, cleared on lock) and
/// `UiImageViewer`, so a photo is decrypted only when it is about to show.
@immutable
class VaultImageProvider extends ImageProvider<VaultImageProvider> {
  const VaultImageProvider(this.vault, this.id, {this.thumbnail = false});

  final VaultStore vault;
  final String id;

  /// Decrypt the small thumbnail instead of the full file.
  final bool thumbnail;

  @override
  Future<VaultImageProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(VaultImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _decode(decode),
      scale: 1,
      debugLabel: thumbnail ? 'vault thumbnail' : 'vault image',
    );
  }

  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    final bytes = thumbnail ? await vault.readThumb(id) : await vault.readBytes(id);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is VaultImageProvider && other.id == id && other.thumbnail == thumbnail && identical(other.vault, vault);

  @override
  int get hashCode => Object.hash(id, thumbnail, identityHashCode(vault));
}
