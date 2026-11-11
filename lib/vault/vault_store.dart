import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../crypto/chunk_cipher.dart';
import '../crypto/key_wrap.dart';
import '../platform/native_bridge.dart';
import 'vault_index.dart';

/// The encrypted vault on disk and, while unlocked, its keys in memory.
///
/// Files under [root]:
/// - `vault.json`: public header (KDF parameters, wrapped VMK blobs, PIN length).
/// - `index.enc`: encrypted [VaultIndex] (names, types, sizes, dates, albums).
/// - `blobs/<id>`: one encrypted container per item.
/// - `thumbs/<id>`: encrypted JPEG thumbnail.
///
/// Nothing readable is stored: file names on disk are random ids.
class VaultStore extends ChangeNotifier {
  VaultStore({
    required this.root,
    required this.keystore,
    this.kdfIterations = KeyWrap.defaultIterations,
    this.minKdfIterations = KeyWrap.minIterations,
    this.chunkSize = ChunkCipher.defaultChunkSize,
  });

  final Directory root;
  final VaultKeystore keystore;

  /// PBKDF2 iterations used when a PIN is set or changed.
  final int kdfIterations;

  /// Headers asking for fewer iterations are rejected (downgrade protection).
  final int minKdfIterations;
  final int chunkSize;

  static const minPinLength = 4;
  static const maxPinLength = 8;

  Map<String, Object?>? _header;
  Uint8List? _vmk;
  SecretKeyData? _contentKey;
  SecretKeyData? _indexKey;
  ChunkCipher? _content;
  VaultIndex? _index;
  Future<void> _saveChain = Future.value();

  File get _headerFile => File('${root.path}/vault.json');
  File get _indexFile => File('${root.path}/index.enc');
  Directory get _blobDir => Directory('${root.path}/blobs');
  Directory get _thumbDir => Directory('${root.path}/thumbs');

  /// A vault header exists on disk.
  bool get exists => _header != null;
  bool get isUnlocked => _vmk != null && _index != null;
  int get pinLength => (_header?['pinLength'] as int?) ?? minPinLength;
  bool get biometricEnabled => _header?['bioWrap'] != null;

  /// Reads the header. Call once at startup.
  Future<void> load() async {
    if (!await _headerFile.exists()) return;
    _header = (jsonDecode(await _headerFile.readAsString()) as Map).cast<String, Object?>();
  }

  // ---- lifecycle ----------------------------------------------------------

  /// Creates a new vault protected by [pin] and leaves it unlocked.
  Future<void> create(String pin) async {
    assert(!exists, 'A vault already exists');
    await root.create(recursive: true);
    final vmk = KeyWrap.randomBytes(KeyWrap.keyLength);
    try {
      _header = await _pinHeader(pin, vmk);
      await _writeHeader();
      await _activate(vmk);
      _index = VaultIndex();
      await _persist();
    } finally {
      vmk.fillRange(0, vmk.length, 0);
    }
    notifyListeners();
  }

  /// Unlocks with the PIN. Throws [VaultAuthException] when it is wrong.
  Future<void> unlockWithPin(String pin) async {
    final vmk = await _unwrapWithPin(pin);
    try {
      await _open(vmk);
    } finally {
      vmk.fillRange(0, vmk.length, 0);
    }
  }

  /// Unlocks after a fingerprint check. Throws [KeystoreException].
  Future<void> unlockWithBiometric() async {
    final wrapped = _header?['bioWrap'] as String?;
    if (wrapped == null) throw const KeystoreException('invalidated');
    final Uint8List vmk;
    try {
      vmk = await keystore.biometricUnlock(base64Decode(wrapped));
    } on KeystoreException catch (e) {
      if (e.code == 'invalidated') await _setBiometricWrap(null);
      rethrow;
    }
    try {
      await _open(vmk);
    } finally {
      vmk.fillRange(0, vmk.length, 0);
    }
  }

  /// Forgets all keys held in memory.
  void lock() {
    _contentKey?.destroy();
    _indexKey?.destroy();
    _vmk?.fillRange(0, _vmk!.length, 0);
    _contentKey = _indexKey = null;
    _vmk = null;
    _content = null;
    _index = null;
    notifyListeners();
  }

  /// Re-wraps the VMK under a new PIN. Files are untouched.
  /// Throws [VaultAuthException] when [oldPin] is wrong.
  Future<void> changePin(String oldPin, String newPin) async {
    final vmk = await _unwrapWithPin(oldPin);
    try {
      final header = await _pinHeader(newPin, vmk);
      _header = {...?_header, ...header};
      await _writeHeader();
    } finally {
      vmk.fillRange(0, vmk.length, 0);
    }
    notifyListeners();
  }

  /// Turns fingerprint unlock on. Shows the biometric prompt.
  Future<void> enableBiometric() async {
    _requireUnlocked();
    final wrapped = await keystore.biometricEnroll(Uint8List.fromList(_vmk!));
    await _setBiometricWrap(base64Encode(wrapped));
  }

  Future<void> disableBiometric() async {
    await keystore.biometricRemove();
    await _setBiometricWrap(null);
  }

  // ---- index --------------------------------------------------------------

  List<VaultAlbum> get albums => List.unmodifiable(_index?.albums ?? const <VaultAlbum>[]);

  /// Items of an album, newest first.
  List<VaultItem> itemsIn(String albumId) {
    final items = [for (final i in _index?.items ?? const <VaultItem>[]) if (i.albumId == albumId) i];
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return items;
  }

  int get itemCount => _index?.items.length ?? 0;

  VaultItem? item(String id) {
    for (final i in _index?.items ?? const <VaultItem>[]) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<VaultAlbum> addAlbum(String name) async {
    final album = VaultAlbum(id: _newId(), name: name.trim());
    _requireIndex().albums.add(album);
    await _persist();
    notifyListeners();
    return album;
  }

  Future<void> renameAlbum(String id, String name) async {
    final albums = _requireIndex().albums;
    final i = albums.indexWhere((a) => a.id == id);
    if (i < 0 || albums[i].isDefault) return;
    albums[i] = VaultAlbum(id: id, name: name.trim());
    await _persist();
    notifyListeners();
  }

  /// Deletes an album. Its items move to the default album.
  Future<void> deleteAlbum(String id) async {
    if (id == VaultAlbum.defaultId) return;
    final index = _requireIndex();
    index.albums.removeWhere((a) => a.id == id);
    for (var n = 0; n < index.items.length; n++) {
      if (index.items[n].albumId == id) index.items[n] = index.items[n].copyWith(albumId: VaultAlbum.defaultId);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> moveItems(Iterable<String> ids, String albumId) async {
    final index = _requireIndex();
    final set = ids.toSet();
    for (var n = 0; n < index.items.length; n++) {
      if (set.contains(index.items[n].id)) index.items[n] = index.items[n].copyWith(albumId: albumId);
    }
    await _persist();
    notifyListeners();
  }

  // ---- files --------------------------------------------------------------

  /// Encrypts [source] into the vault. [onProgress] gets plaintext bytes done.
  /// The caller deletes [source] afterwards.
  Future<VaultItem> addFile({
    required File source,
    required String name,
    required String mime,
    required String albumId,
    Uint8List? thumbnail,
    void Function(int bytes)? onProgress,
  }) async {
    final cipher = _requireContent();
    final index = _requireIndex();
    await _blobDir.create(recursive: true);
    final id = _newId();
    final blob = File('${_blobDir.path}/$id');
    final tmp = File('${blob.path}.tmp');
    var done = 0;
    try {
      final plain = source.openRead().map((chunk) {
        done += chunk.length;
        onProgress?.call(done);
        return chunk;
      });
      final sink = tmp.openWrite();
      try {
        await sink.addStream(cipher.encrypt(plain));
      } finally {
        await sink.close();
      }
      await tmp.rename(blob.path);
      if (thumbnail != null) {
        await _thumbDir.create(recursive: true);
        await File('${_thumbDir.path}/$id').writeAsBytes(await cipher.encryptBytes(thumbnail), flush: true);
      }
    } catch (_) {
      await _deleteQuietly(tmp);
      await _deleteQuietly(blob);
      await _deleteQuietly(File('${_thumbDir.path}/$id'));
      rethrow;
    }
    final item = VaultItem(
      id: id,
      name: name,
      mime: mime,
      kind: kindForMime(mime),
      size: done,
      addedAt: DateTime.now(),
      albumId: index.albums.any((a) => a.id == albumId) ? albumId : VaultAlbum.defaultId,
      hasThumb: thumbnail != null,
    );
    index.items.add(item);
    await _persist();
    notifyListeners();
    return item;
  }

  Future<void> deleteItems(Iterable<String> ids) async {
    final set = ids.toSet();
    _requireIndex().items.removeWhere((i) => set.contains(i.id));
    await _persist();
    for (final id in set) {
      await _deleteQuietly(File('${_blobDir.path}/$id'));
      await _deleteQuietly(File('${_thumbDir.path}/$id'));
    }
    notifyListeners();
  }

  /// Decrypted thumbnail, held in memory only.
  Future<Uint8List> readThumb(String id) async =>
      _requireContent().decryptBytes(await File('${_thumbDir.path}/$id').readAsBytes());

  /// Whole decrypted file in memory. Use for photos, not for videos.
  Future<Uint8List> readBytes(String id) async =>
      _requireContent().decryptBytes(await File('${_blobDir.path}/$id').readAsBytes());

  /// Decrypts an item to [dest]. A failed or tampered decrypt leaves no file.
  Future<void> decryptTo(String id, File dest) async {
    final cipher = _requireContent();
    await dest.parent.create(recursive: true);
    final sink = dest.openWrite();
    try {
      await sink.addStream(cipher.decrypt(File('${_blobDir.path}/$id').openRead()));
      await sink.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      await _deleteQuietly(dest);
      rethrow;
    }
  }

  // ---- internals ----------------------------------------------------------

  Future<Map<String, Object?>> _pinHeader(String pin, Uint8List vmk) async {
    final salt = KeyWrap.randomBytes(KeyWrap.saltLength);
    final kek = await KeyWrap.pinKek(pin, salt, iterations: kdfIterations);
    final wrapped = await KeyWrap.wrap(kek, vmk);
    final sealed = await keystore.seal(wrapped);
    return {
      'v': 1,
      'pinLength': pin.length,
      'kdf': {'alg': 'pbkdf2-hmac-sha256', 'iterations': kdfIterations, 'salt': base64Encode(salt)},
      'pinWrap': base64Encode(sealed),
    };
  }

  Future<Uint8List> _unwrapWithPin(String pin) async {
    final header = _header;
    if (header == null) throw const VaultFormatException('No vault');
    final kdf = (header['kdf']! as Map).cast<String, Object?>();
    final iterations = kdf['iterations']! as int;
    if (kdf['alg'] != 'pbkdf2-hmac-sha256' || iterations < minKdfIterations) {
      throw const VaultFormatException('Unsupported key derivation');
    }
    final salt = base64Decode(kdf['salt']! as String);
    final wrapped = await keystore.unseal(base64Decode(header['pinWrap']! as String));
    final kek = await KeyWrap.pinKek(pin, salt, iterations: iterations);
    return KeyWrap.unwrap(kek, wrapped);
  }

  Future<void> _open(Uint8List vmk) async {
    await _activate(vmk);
    try {
      final bytes = await _indexFile.readAsBytes();
      final plain = await ChunkCipher(_indexKey!, chunkSize: chunkSize).decryptBytes(bytes);
      _index = VaultIndex.decode(plain);
    } catch (_) {
      lock();
      rethrow;
    }
    await _sweepOrphans();
    notifyListeners();
  }

  Future<void> _activate(Uint8List vmk) async {
    _vmk = Uint8List.fromList(vmk);
    _contentKey = await _zeroable(KeyWrap.contentKey(vmk));
    _indexKey = await _zeroable(KeyWrap.indexKey(vmk));
    _content = ChunkCipher(_contentKey!, chunkSize: chunkSize);
  }

  /// Copies a derived key into key data that is overwritten on `destroy()`.
  Future<SecretKeyData> _zeroable(Future<SecretKey> key) async =>
      SecretKeyData(await (await key).extractBytes(), overwriteWhenDestroyed: true);

  /// Removes blobs left by an interrupted import or delete.
  Future<void> _sweepOrphans() async {
    final known = {for (final i in _index!.items) i.id};
    for (final dir in [_blobDir, _thumbDir]) {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && !known.contains(name)) await _deleteQuietly(entity);
      }
    }
  }

  Future<void> _setBiometricWrap(String? value) async {
    final header = {...?_header};
    if (value == null) {
      header.remove('bioWrap');
    } else {
      header['bioWrap'] = value;
    }
    _header = header;
    await _writeHeader();
    notifyListeners();
  }

  Future<void> _writeHeader() => _writeAtomic(_headerFile, utf8.encode(jsonEncode(_header)));

  /// Saves the index. Saves are serialized so a slow one cannot overwrite a newer one.
  Future<void> _persist() {
    final cipher = ChunkCipher(_indexKey!, chunkSize: chunkSize);
    final plain = _requireIndex().encode();
    return _saveChain = _saveChain.catchError((Object _) {}).then((_) async {
      await _writeAtomic(_indexFile, await cipher.encryptBytes(plain));
    });
  }

  Future<void> _writeAtomic(File file, List<int> bytes) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort.
    }
  }

  String _newId() => KeyWrap.randomBytes(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _requireUnlocked() {
    if (!isUnlocked) throw StateError('Vault is locked');
  }

  ChunkCipher _requireContent() {
    _requireUnlocked();
    return _content!;
  }

  VaultIndex _requireIndex() {
    _requireUnlocked();
    return _index!;
  }
}
