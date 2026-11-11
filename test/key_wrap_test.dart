import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketlock/crypto/chunk_cipher.dart';
import 'package:pocketlock/crypto/key_wrap.dart';

// Pure-Dart PBKDF2 is slow, so tests use few iterations. The app uses
// KeyWrap.defaultIterations with the native implementation.
const _iterations = 1000;

Future<List<int>> _bytes(SecretKey key) => key.extractBytes();

void main() {
  final salt = Uint8List.fromList(List.generate(16, (i) => i));

  test('defaults meet the 310k minimum', () {
    expect(KeyWrap.defaultIterations, greaterThanOrEqualTo(310000));
    expect(KeyWrap.minIterations, greaterThanOrEqualTo(310000));
  });

  group('PIN key derivation', () {
    test('is deterministic', () async {
      final a = await KeyWrap.pinKek('123456', salt, iterations: _iterations);
      final b = await KeyWrap.pinKek('123456', salt, iterations: _iterations);
      expect(await _bytes(a), await _bytes(b));
      expect((await _bytes(a)).length, 32);
    });

    test('depends on the PIN', () async {
      final a = await KeyWrap.pinKek('123456', salt, iterations: _iterations);
      final b = await KeyWrap.pinKek('123457', salt, iterations: _iterations);
      expect(await _bytes(a), isNot(await _bytes(b)));
    });

    test('depends on the salt', () async {
      final other = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final a = await KeyWrap.pinKek('123456', salt, iterations: _iterations);
      final b = await KeyWrap.pinKek('123456', other, iterations: _iterations);
      expect(await _bytes(a), isNot(await _bytes(b)));
    });

    test('depends on the iteration count', () async {
      final a = await KeyWrap.pinKek('123456', salt, iterations: _iterations);
      final b = await KeyWrap.pinKek('123456', salt, iterations: _iterations + 1);
      expect(await _bytes(a), isNot(await _bytes(b)));
    });

    test('matches the RFC 7914 PBKDF2-HMAC-SHA256 vector (c=1)', () async {
      // "passwd" / "salt", c = 1, dkLen = 32 (from the PBKDF2-HMAC-SHA256 test vectors).
      final key = await KeyWrap.pinKek('passwd', Uint8List.fromList('salt'.codeUnits), iterations: 1);
      final hex = (await _bytes(key)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hex, '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc');
    });
  });

  group('wrap and unwrap', () {
    late SecretKey kek;
    late Uint8List vmk;

    setUp(() async {
      kek = await KeyWrap.pinKek('2468', salt, iterations: _iterations);
      vmk = KeyWrap.randomBytes(KeyWrap.keyLength);
    });

    test('round trip', () async {
      final blob = await KeyWrap.wrap(kek, vmk);
      expect(await KeyWrap.unwrap(kek, blob), vmk);
    });

    test('wrong PIN fails', () async {
      final blob = await KeyWrap.wrap(kek, vmk);
      final wrong = await KeyWrap.pinKek('2469', salt, iterations: _iterations);
      expect(KeyWrap.unwrap(wrong, blob), throwsA(isA<VaultAuthException>()));
    });

    test('tampered blob fails', () async {
      final blob = Uint8List.fromList(await KeyWrap.wrap(kek, vmk));
      blob[15] ^= 1;
      expect(KeyWrap.unwrap(kek, blob), throwsA(isA<VaultAuthException>()));
    });

    test('a blob only opens in its own context', () async {
      final blob = await KeyWrap.wrap(kek, vmk, context: 'other');
      expect(KeyWrap.unwrap(kek, blob), throwsA(isA<VaultAuthException>()));
    });

    test('short blob is a format error', () {
      expect(KeyWrap.unwrap(kek, Uint8List(10)), throwsA(isA<VaultFormatException>()));
    });

    test('wrapping twice gives different blobs', () async {
      expect(await KeyWrap.wrap(kek, vmk), isNot(await KeyWrap.wrap(kek, vmk)));
    });
  });

  group('subkeys', () {
    test('content and index keys differ and are stable', () async {
      final vmk = KeyWrap.randomBytes(32);
      final content = await _bytes(await KeyWrap.contentKey(vmk));
      final index = await _bytes(await KeyWrap.indexKey(vmk));
      expect(content, isNot(index));
      expect(content, isNot(vmk));
      expect(await _bytes(await KeyWrap.contentKey(vmk)), content);
      expect(content.length, 32);
    });
  });
}
