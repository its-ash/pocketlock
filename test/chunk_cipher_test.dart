import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketlock/crypto/chunk_cipher.dart';

const _chunk = 16;
const _record = _chunk + ChunkCipher.recordOverhead;

SecretKey _key(int seed) => SecretKeyData(List.generate(32, (i) => (i + seed) & 0xff));

Uint8List _data(int length) => Uint8List.fromList(List.generate(length, (i) => (i * 7 + 3) & 0xff));

Future<Uint8List> _encrypt(ChunkCipher cipher, Uint8List plain, {int part = 5}) async {
  final out = BytesBuilder();
  // Feed the plaintext in odd-sized parts to exercise regrouping.
  final parts = <List<int>>[for (var i = 0; i < plain.length; i += part) plain.sublist(i, (i + part).clamp(0, plain.length))];
  await for (final c in cipher.encrypt(Stream.fromIterable(parts))) {
    out.add(c);
  }
  return out.takeBytes();
}

Future<Uint8List> _decrypt(ChunkCipher cipher, Uint8List blob, {int part = 7}) async {
  final out = BytesBuilder();
  final parts = <List<int>>[for (var i = 0; i < blob.length; i += part) blob.sublist(i, (i + part).clamp(0, blob.length))];
  await for (final c in cipher.decrypt(Stream.fromIterable(parts))) {
    out.add(c);
  }
  return out.takeBytes();
}

void main() {
  late ChunkCipher cipher;

  setUp(() => cipher = ChunkCipher(_key(1), chunkSize: _chunk));

  group('round trip', () {
    for (final length in [0, 1, _chunk - 1, _chunk, _chunk + 1, _chunk * 3, _chunk * 3 + 5, 1000]) {
      test('$length bytes', () async {
        final plain = _data(length);
        final blob = await _encrypt(cipher, plain);
        expect(await _decrypt(cipher, blob), plain);
      });
    }

    test('size matches the layout', () async {
      final blob = await _encrypt(cipher, _data(_chunk * 2 + 3));
      expect(blob.length, ChunkCipher.headerLength + 2 * _record + (3 + ChunkCipher.recordOverhead));
    });

    test('exact multiple of the chunk size ends with an empty-free final chunk', () async {
      final blob = await _encrypt(cipher, _data(_chunk * 2));
      expect(blob.length, ChunkCipher.headerLength + 2 * _record);
    });

    test('encryptBytes and decryptBytes', () async {
      final plain = _data(100);
      expect(await cipher.decryptBytes(await cipher.encryptBytes(plain)), plain);
    });

    test('two encryptions of the same data differ (random file id and nonces)', () async {
      final plain = _data(40);
      expect(await _encrypt(cipher, plain), isNot(await _encrypt(cipher, plain)));
    });

    test('ciphertext does not contain the plaintext', () async {
      final plain = Uint8List.fromList(List.filled(_chunk * 2, 0x41));
      final blob = await _encrypt(cipher, plain);
      expect(String.fromCharCodes(blob).contains('A' * 8), isFalse);
    });
  });

  group('wrong key', () {
    test('fails with VaultAuthException', () async {
      final blob = await _encrypt(cipher, _data(50));
      expect(_decrypt(ChunkCipher(_key(2), chunkSize: _chunk), blob), throwsA(isA<VaultAuthException>()));
    });
  });

  group('tampering', () {
    late Uint8List plain;
    late Uint8List blob;

    setUp(() async {
      plain = _data(_chunk * 3 + 4);
      blob = await _encrypt(cipher, plain);
    });

    test('flipped ciphertext bit', () {
      final bad = Uint8List.fromList(blob);
      bad[ChunkCipher.headerLength + ChunkCipher.nonceLength + 2] ^= 1;
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('flipped tag bit', () {
      final bad = Uint8List.fromList(blob);
      bad[bad.length - 1] ^= 1;
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('flipped nonce bit', () {
      final bad = Uint8List.fromList(blob);
      bad[ChunkCipher.headerLength] ^= 1;
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('changed file id', () {
      final bad = Uint8List.fromList(blob);
      bad[6] ^= 1;
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('dropped last chunk (truncation at a chunk boundary)', () {
      final bad = blob.sublist(0, ChunkCipher.headerLength + 3 * _record);
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('dropped chunk in the middle', () {
      final h = ChunkCipher.headerLength;
      final bad = Uint8List.fromList([...blob.sublist(0, h), ...blob.sublist(h + _record)]);
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('reordered chunks', () {
      final h = ChunkCipher.headerLength;
      final bad = Uint8List.fromList([
        ...blob.sublist(0, h),
        ...blob.sublist(h + _record, h + 2 * _record),
        ...blob.sublist(h, h + _record),
        ...blob.sublist(h + 2 * _record),
      ]);
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('data appended', () async {
      final extra = await _encrypt(cipher, _data(_chunk));
      final bad = Uint8List.fromList([...blob, ...extra.sublist(ChunkCipher.headerLength)]);
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });

    test('chunks spliced from another file with the same key', () async {
      final other = await _encrypt(cipher, _data(_chunk * 3 + 4));
      final h = ChunkCipher.headerLength;
      final bad = Uint8List.fromList([...blob.sublist(0, h + _record), ...other.sublist(h + _record)]);
      expect(_decrypt(cipher, bad), throwsA(isA<VaultAuthException>()));
    });
  });

  group('malformed input', () {
    test('bad magic', () async {
      final blob = await _encrypt(cipher, _data(10));
      final bad = Uint8List.fromList(blob)..[0] = 0;
      expect(_decrypt(cipher, bad), throwsA(isA<VaultFormatException>()));
    });

    test('empty input', () {
      expect(_decrypt(cipher, Uint8List(0)), throwsA(isA<VaultFormatException>()));
    });

    test('header only', () async {
      final blob = await _encrypt(cipher, _data(10));
      expect(_decrypt(cipher, blob.sublist(0, ChunkCipher.headerLength)), throwsA(isA<VaultFormatException>()));
    });

    test('record shorter than nonce and tag', () async {
      final blob = await _encrypt(cipher, _data(10));
      expect(_decrypt(cipher, blob.sublist(0, ChunkCipher.headerLength + 10)), throwsA(isA<VaultFormatException>()));
    });
  });

  test('default chunk size is 1 MiB', () {
    expect(ChunkCipher.defaultChunkSize, 1024 * 1024);
  });
}
