import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../platform/native_bridge.dart';
import '../vault/vault_index.dart';
import '../vault/vault_store.dart';
import 'temp_files.dart';

enum ExportOutcome { done, usedShare }

/// Takes decrypted copies out of the vault: export to the device, or share.
class ExportService {
  ExportService({required this.vault, required this.native, required this.temp});

  final VaultStore vault;
  final NativeBridge native;
  final TempFiles temp;

  /// Saves items to Pictures, Movies or Downloads (`Pocketlock` folder).
  /// Before Android 10 there is no scoped way to do that, so the share sheet
  /// opens instead and the result is [ExportOutcome.usedShare].
  Future<ExportOutcome> export(List<VaultItem> items) async {
    for (final item in items) {
      final file = await temp.reserve(item.name);
      try {
        await vault.decryptTo(item.id, file);
        await native.export(path: file.path, name: item.name, mime: item.mime, kind: item.kind.name);
      } on KeystoreException catch (e) {
        if (e.code != 'unsupported') rethrow;
        await share(items);
        return ExportOutcome.usedShare;
      } finally {
        await temp.release(file);
      }
    }
    return ExportOutcome.done;
  }

  /// Decrypts items to private cache and opens the share sheet. The copies
  /// are deleted when the vault locks or the app restarts.
  Future<void> share(List<VaultItem> items) async {
    final files = <XFile>[];
    for (final item in items) {
      final file = await temp.reserve(item.name);
      await vault.decryptTo(item.id, file);
      files.add(XFile(file.path, mimeType: item.mime, name: item.name));
    }
    await SharePlus.instance.share(ShareParams(files: files));
  }

  /// Decrypts one item for playback. Release it with [TempFiles.release].
  Future<File> decryptForPlayback(VaultItem item) async {
    final file = await temp.reserve(item.name);
    await vault.decryptTo(item.id, file);
    return file;
  }
}
