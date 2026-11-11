import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketlock/crypto/chunk_cipher.dart';
import 'package:pocketlock/platform/native_bridge.dart';
import 'package:pocketlock/vault/vault_index.dart';
import 'package:pocketlock/vault/vault_store.dart';

/// Keystore stand-in: "seals" by reversing bytes and "wraps" biometrics the
/// same way. Real behavior is covered on device.
class FakeKeystore implements VaultKeystore {
  bool invalidated = false;
  bool enrolled = false;

  @override
  Future<Uint8List> seal(Uint8List data) async => Uint8List.fromList(data.reversed.toList());

  @override
  Future<Uint8List> unseal(Uint8List data) async => Uint8List.fromList(data.reversed.toList());

  @override
  Future<String> biometricStatus() async => 'available';

  @override
  Future<Uint8List> biometricEnroll(Uint8List vmk) async {
    enrolled = true;
    return Uint8List.fromList(vmk.reversed.toList());
  }

  @override
  Future<Uint8List> biometricUnlock(Uint8List wrapped) async {
    if (invalidated) throw const KeystoreException('invalidated');
    return Uint8List.fromList(wrapped.reversed.toList());
  }

  @override
  Future<void> biometricRemove() async => enrolled = false;
}

const _iterations = 1000;

void main() {
  late Directory tmp;
  late FakeKeystore keystore;

  VaultStore newStore({int iterations = _iterations, int min = _iterations}) => VaultStore(
    root: Directory('${tmp.path}/vault'),
    keystore: keystore,
    kdfIterations: iterations,
    minKdfIterations: min,
    chunkSize: 64,
  );

  Future<File> source(List<int> bytes, [String name = 'src.bin']) async =>
      File('${tmp.path}/$name').writeAsBytes(bytes);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pocketlock_test');
    keystore = FakeKeystore();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('create, lock, unlock with the PIN', () async {
    final store = newStore();
    await store.create('2580');
    expect(store.isUnlocked, isTrue);
    expect(store.pinLength, 4);
    store.lock();
    expect(store.isUnlocked, isFalse);

    final again = newStore();
    await again.load();
    expect(again.exists, isTrue);
    await again.unlockWithPin('2580');
    expect(again.isUnlocked, isTrue);
  });

  test('wrong PIN is rejected and the vault stays locked', () async {
    final store = newStore();
    await store.create('2580');
    store.lock();
    await expectLater(store.unlockWithPin('2581'), throwsA(isA<VaultAuthException>()));
    expect(store.isUnlocked, isFalse);
  });

  test('imports a multi-chunk file and reads it back', () async {
    final store = newStore();
    await store.create('2580');
    final plain = List.generate(1000, (i) => i & 0xff);
    final item = await store.addFile(
      source: await source(plain),
      name: 'secret.pdf',
      mime: 'application/pdf',
      albumId: VaultAlbum.defaultId,
    );
    expect(item.size, 1000);
    expect(item.kind, VaultKind.file);

    expect(await store.readBytes(item.id), plain);

    final out = File('${tmp.path}/out.bin');
    await store.decryptTo(item.id, out);
    expect(await out.readAsBytes(), plain);
  });

  test('thumbnails are stored encrypted and read back', () async {
    final store = newStore();
    await store.create('2580');
    final thumb = Uint8List.fromList(List.generate(200, (i) => i));
    final item = await store.addFile(
      source: await source([1, 2, 3]),
      name: 'a.jpg',
      mime: 'image/jpeg',
      albumId: VaultAlbum.defaultId,
      thumbnail: thumb,
    );
    expect(item.hasThumb, isTrue);
    expect(await store.readThumb(item.id), thumb);
  });

  test('nothing readable is on disk: no names, no plaintext', () async {
    final store = newStore();
    await store.create('2580');
    final marker = utf8.encode('TOP-SECRET-CONTENT' * 10);
    await store.addAlbum('Private Album Name');
    await store.addFile(
      source: await source(marker),
      name: 'passport-scan.jpg',
      mime: 'image/jpeg',
      albumId: VaultAlbum.defaultId,
      thumbnail: Uint8List.fromList(marker),
    );
    await for (final entity in Directory('${tmp.path}/vault').list(recursive: true)) {
      if (entity is! File || entity.path.endsWith('vault.json')) continue;
      final text = latin1.decode(await entity.readAsBytes());
      expect(text.contains('TOP-SECRET'), isFalse, reason: entity.path);
      expect(text.contains('passport'), isFalse, reason: entity.path);
      expect(text.contains('Private Album'), isFalse, reason: entity.path);
      expect(entity.uri.pathSegments.last.contains('passport'), isFalse);
    }
  });

  test('index persists across unlock', () async {
    final store = newStore();
    await store.create('2580');
    final album = await store.addAlbum('Trips');
    final item = await store.addFile(
      source: await source([9, 9, 9]),
      name: 'b.png',
      mime: 'image/png',
      albumId: album.id,
    );
    store.lock();

    final again = newStore();
    await again.load();
    await again.unlockWithPin('2580');
    expect(again.albums.map((a) => a.name), containsAll(['Unsorted', 'Trips']));
    expect(again.itemsIn(album.id).single.id, item.id);
    expect(again.itemsIn(album.id).single.name, 'b.png');
  });

  test('change PIN re-wraps the key and leaves files readable', () async {
    final store = newStore();
    await store.create('2580');
    final item = await store.addFile(
      source: await source(List.filled(300, 7)),
      name: 'c.bin',
      mime: 'application/octet-stream',
      albumId: VaultAlbum.defaultId,
    );
    final before = await File('${tmp.path}/vault/blobs/${item.id}').readAsBytes();

    await expectLater(store.changePin('0000', '135790'), throwsA(isA<VaultAuthException>()));
    await store.changePin('2580', '135790');
    expect(store.pinLength, 6);
    expect(await File('${tmp.path}/vault/blobs/${item.id}').readAsBytes(), before, reason: 'files are untouched');
    store.lock();

    final again = newStore();
    await again.load();
    await expectLater(again.unlockWithPin('2580'), throwsA(isA<VaultAuthException>()));
    await again.unlockWithPin('135790');
    expect(await again.readBytes(item.id), List.filled(300, 7));
  });

  test('biometric unlock opens the same vault', () async {
    final store = newStore();
    await store.create('2580');
    final item = await store.addFile(
      source: await source([5, 6, 7]),
      name: 'd.bin',
      mime: 'application/octet-stream',
      albumId: VaultAlbum.defaultId,
    );
    await store.enableBiometric();
    expect(store.biometricEnabled, isTrue);
    store.lock();

    final again = newStore();
    await again.load();
    expect(again.biometricEnabled, isTrue);
    await again.unlockWithBiometric();
    expect(await again.readBytes(item.id), [5, 6, 7]);
  });

  test('lost biometric key clears the biometric wrap but PIN still works', () async {
    final store = newStore();
    await store.create('2580');
    await store.enableBiometric();
    store.lock();
    keystore.invalidated = true;

    await expectLater(store.unlockWithBiometric(), throwsA(isA<KeystoreException>()));
    expect(store.biometricEnabled, isFalse);
    await store.unlockWithPin('2580');
    expect(store.isUnlocked, isTrue);
  });

  test('tampered blob fails to decrypt and leaves no output file', () async {
    final store = newStore();
    await store.create('2580');
    final item = await store.addFile(
      source: await source(List.filled(500, 1)),
      name: 'e.bin',
      mime: 'application/octet-stream',
      albumId: VaultAlbum.defaultId,
    );
    final blob = File('${tmp.path}/vault/blobs/${item.id}');
    final bytes = await blob.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 1;
    await blob.writeAsBytes(bytes);

    final out = File('${tmp.path}/tampered.out');
    await expectLater(store.decryptTo(item.id, out), throwsA(isA<VaultAuthException>()));
    expect(await out.exists(), isFalse);
  });

  test('tampered index fails to unlock', () async {
    final store = newStore();
    await store.create('2580');
    store.lock();
    final index = File('${tmp.path}/vault/index.enc');
    final bytes = await index.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await index.writeAsBytes(bytes);

    await expectLater(store.unlockWithPin('2580'), throwsA(isA<VaultAuthException>()));
    expect(store.isUnlocked, isFalse);
  });

  test('a header with a weakened KDF is refused', () async {
    await (newStore(iterations: 10, min: 10)).create('2580');
    final store = newStore(min: 310000);
    await store.load();
    await expectLater(store.unlockWithPin('2580'), throwsA(isA<VaultFormatException>()));
  });

  test('delete removes the blob and thumbnail', () async {
    final store = newStore();
    await store.create('2580');
    final item = await store.addFile(
      source: await source([1]),
      name: 'f.jpg',
      mime: 'image/jpeg',
      albumId: VaultAlbum.defaultId,
      thumbnail: Uint8List.fromList([1, 2]),
    );
    await store.deleteItems([item.id]);
    expect(store.item(item.id), isNull);
    expect(await File('${tmp.path}/vault/blobs/${item.id}').exists(), isFalse);
    expect(await File('${tmp.path}/vault/thumbs/${item.id}').exists(), isFalse);
  });

  test('deleting an album moves its items to Unsorted; move works', () async {
    final store = newStore();
    await store.create('2580');
    final album = await store.addAlbum('Temp');
    final item = await store.addFile(
      source: await source([1]),
      name: 'g.bin',
      mime: 'application/octet-stream',
      albumId: VaultAlbum.defaultId,
    );
    await store.moveItems([item.id], album.id);
    expect(store.itemsIn(album.id), hasLength(1));
    await store.deleteAlbum(album.id);
    expect(store.itemsIn(VaultAlbum.defaultId).single.id, item.id);
    expect(store.albums.any((a) => a.id == album.id), isFalse);
  });

  test('unlock sweeps blobs left by an interrupted import', () async {
    final store = newStore();
    await store.create('2580');
    store.lock();
    final orphan = File('${tmp.path}/vault/blobs/deadbeef.tmp');
    await orphan.create(recursive: true);

    await store.unlockWithPin('2580');
    expect(await orphan.exists(), isFalse);
  });

  test('locked vault refuses reads', () async {
    final store = newStore();
    await store.create('2580');
    final item = await store.addFile(
      source: await source([1]),
      name: 'h.bin',
      mime: 'application/octet-stream',
      albumId: VaultAlbum.defaultId,
    );
    store.lock();
    await expectLater(store.readBytes(item.id), throwsA(isA<StateError>()));
  });
}
