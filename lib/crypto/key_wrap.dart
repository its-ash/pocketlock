import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'chunk_cipher.dart';

/// Key hierarchy of the vault.
///
/// - The vault master key (VMK) is 32 random bytes, created once.
/// - The content key (files, thumbnails) and the index key are derived from
///   the VMK with HKDF-SHA256, so no key is used for two purposes.
/// - The VMK is stored wrapped (AES-256-GCM) under a key-encryption key (KEK).
///   For the PIN, the KEK comes from PBKDF2-HMAC-SHA256 with a random salt.
class KeyWrap {
  const KeyWrap._();

  static const keyLength = 32;
  static const saltLength = 16;

  /// PBKDF2 iterations for new vaults (OWASP 2023: 600,000 for HMAC-SHA256).
  static const defaultIterations = 600000;

  /// Lowest iteration count accepted when reading a vault header.
  static const minIterations = 310000;

  static const _pinContext = 'pocketlock/pin-wrap/v1';
  static final AesGcm _aes = AesGcm.with256bits();

  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
  }

  /// KEK from a PIN. The PIN is never stored.
  static Future<SecretKey> pinKek(String pin, Uint8List salt, {int iterations = defaultIterations}) {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: keyLength * 8);
    return kdf.deriveKeyFromPassword(password: pin, nonce: salt);
  }

  /// Wraps [secret] under [kek]: `nonce (12) | ciphertext | tag (16)`.
  /// [context] is authenticated, so a blob only opens in its own role.
  static Future<Uint8List> wrap(SecretKey kek, List<int> secret, {String context = _pinContext}) async {
    final box = await _aes.encrypt(secret, secretKey: kek, aad: utf8.encode(context));
    return box.concatenation();
  }

  /// Opens a blob made by [wrap]. Throws [VaultAuthException] when [kek] is wrong or the blob changed.
  static Future<Uint8List> unwrap(SecretKey kek, List<int> blob, {String context = _pinContext}) async {
    if (blob.length < ChunkCipher.recordOverhead) throw const VaultFormatException('Wrapped key is too short');
    try {
      final box = SecretBox.fromConcatenation(blob, nonceLength: 12, macLength: 16);
      return Uint8List.fromList(await _aes.decrypt(box, secretKey: kek, aad: utf8.encode(context)));
    } on SecretBoxAuthenticationError {
      throw const VaultAuthException();
    }
  }

  static Future<SecretKey> _subkey(List<int> vmk, String info) {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLength);
    return hkdf.deriveKey(secretKey: SecretKeyData(vmk), nonce: const <int>[], info: utf8.encode(info));
  }

  /// Keys for files and thumbnails.
  static Future<SecretKey> contentKey(List<int> vmk) => _subkey(vmk, 'pocketlock/content/v1');

  /// Key for the encrypted index.
  static Future<SecretKey> indexKey(List<int> vmk) => _subkey(vmk, 'pocketlock/index/v1');
}
