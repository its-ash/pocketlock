import 'dart:io';

import '../platform/native_bridge.dart';
import '../vault/vault_store.dart';

class ImportProgress {
  const ImportProgress({required this.index, required this.total, required this.name, required this.fraction});

  /// Zero-based index of the file being imported.
  final int index;
  final int total;
  final String name;

  /// 0..1 progress of the current file.
  final double fraction;

  /// 0..1 progress of the whole import.
  double get overall => total == 0 ? 1 : (index + fraction) / total;
}

class ImportResult {
  const ImportResult({required this.imported, required this.failed, required this.originals});

  final int imported;
  final List<String> failed;

  /// MediaStore URIs of gallery originals that were imported successfully.
  final List<String> originals;
}

/// Copies picked files into the vault one at a time.
///
/// Each file is staged to private cache, thumbnailed natively, encrypted
/// chunk by chunk, and the plaintext staging copy is deleted right after.
class ImportService {
  ImportService({required this.vault, required this.native});

  final VaultStore vault;
  final NativeBridge native;

  Future<ImportResult> run(
    List<PickedFile> files, {
    required String albumId,
    required void Function(ImportProgress progress) onProgress,
  }) async {
    final failed = <String>[];
    final originals = <String>[];
    var imported = 0;

    for (var i = 0; i < files.length; i++) {
      final picked = files[i];
      void report(double fraction) =>
          onProgress(ImportProgress(index: i, total: files.length, name: picked.name, fraction: fraction));
      report(0);

      File? staged;
      try {
        staged = File(await native.stage(picked.uri));
        final size = picked.size > 0 ? picked.size : await staged.length();
        final thumb = await native.thumbnail(staged.path, picked.mime);
        await vault.addFile(
          source: staged,
          name: picked.name,
          mime: picked.mime,
          albumId: albumId,
          thumbnail: thumb,
          onProgress: (bytes) => report(size == 0 ? 1 : (bytes / size).clamp(0, 1).toDouble()),
        );
        imported++;
        final original = picked.mediaUri;
        if (original != null) originals.add(original);
      } on Exception {
        failed.add(picked.name);
      } finally {
        if (staged != null) {
          try {
            await staged.delete();
          } on FileSystemException {
            // Staging is also wiped at startup.
          }
        }
      }
      report(1);
    }
    return ImportResult(imported: imported, failed: failed, originals: originals);
  }
}
