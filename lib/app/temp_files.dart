import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../crypto/key_wrap.dart';

/// Decrypted copies that must exist for a while (video playback, share,
/// export). They live in app-private cache, one folder per file, and are
/// deleted when released, when the vault locks, and at startup.
class TempFiles {
  TempFiles(this.root);

  static Future<TempFiles> create() async =>
      TempFiles(Directory('${(await getTemporaryDirectory()).path}/pl_tmp'));

  final Directory root;

  /// A fresh, empty path for a decrypted copy of [name].
  Future<File> reserve(String name) async {
    final id = KeyWrap.randomBytes(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final dir = await Directory('${root.path}/$id').create(recursive: true);
    return File('${dir.path}/${_safe(name)}');
  }

  /// Deletes a file from [reserve] and its folder.
  Future<void> release(File file) async {
    try {
      await file.parent.delete(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<void> wipe() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }

  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    final base = cleaned.isEmpty ? 'file' : cleaned;
    return base.length > 100 ? base.substring(base.length - 100) : base;
  }
}
