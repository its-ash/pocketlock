import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The data failed authentication: wrong key, or the container was modified.
class VaultAuthException implements Exception {
  const VaultAuthException([this.message = 'Authentication failed']);

  final String message;

  @override
  String toString() => 'VaultAuthException: $message';
}

/// The data is not a Pocketlock container, or it is cut short.
class VaultFormatException implements Exception {
  const VaultFormatException(this.message);

  final String message;

  @override
  String toString() => 'VaultFormatException: $message';
}

/// Streaming AES-256-GCM container.
///
/// Layout: `"PLK1"` (4) | file id (16, random) | chunk records.
/// A record is `nonce (12) | ciphertext | tag (16)`. Every record holds
/// [chunkSize] plaintext bytes except the last, which holds 0..[chunkSize].
///
/// Each chunk is authenticated with AAD = `file id | chunk index (u32 BE) |
/// final flag (1 byte)`. That binds a chunk to its file and position, so
/// chunks cannot be reordered, swapped between files or dropped, and the
/// final flag makes truncation and appending fail too.
///
/// Memory use is one chunk, however large the file is.
class ChunkCipher {
  ChunkCipher(this._key, {this.chunkSize = defaultChunkSize});

  static const defaultChunkSize = 1024 * 1024;
  static const magic = [0x50, 0x4c, 0x4b, 0x31]; // "PLK1"
  static const fileIdLength = 16;
  static const headerLength = 4 + fileIdLength;
  static const nonceLength = 12;
  static const macLength = 16;
  static const recordOverhead = nonceLength + macLength;

  static final AesGcm _aes = AesGcm.with256bits();

  final SecretKey _key;
  final int chunkSize;

  int get _recordSize => chunkSize + recordOverhead;

  /// Encrypts [plain] into a container stream.
  Stream<Uint8List> encrypt(Stream<List<int>> plain) async* {
    final random = Random.secure();
    final fileId = Uint8List.fromList(List.generate(fileIdLength, (_) => random.nextInt(256)));
    yield Uint8List.fromList([...magic, ...fileId]);

    final reader = _ByteReader(plain);
    try {
      var index = 0;
      var pending = await reader.take(chunkSize);
      while (true) {
        final next = pending == null ? null : await reader.take(chunkSize);
        final isFinal = next == null;
        yield await _seal(pending ?? Uint8List(0), fileId, index++, isFinal);
        if (isFinal) break;
        pending = next;
      }
    } finally {
      await reader.close();
    }
  }

  /// Decrypts a container stream. Throws [VaultAuthException] on a wrong key
  /// or tampering, and [VaultFormatException] on a malformed container.
  /// Chunks already yielded are authentic, but the stream is only complete
  /// once it ends without an error: callers must discard partial output.
  Stream<Uint8List> decrypt(Stream<List<int>> encrypted) async* {
    final reader = _ByteReader(encrypted);
    try {
      final header = await reader.take(headerLength);
      if (header == null || header.length < headerLength || !_hasMagic(header)) {
        throw const VaultFormatException('Not a Pocketlock file');
      }
      final fileId = Uint8List.sublistView(header, 4);

      var record = await reader.take(_recordSize);
      if (record == null) throw const VaultFormatException('File is truncated');
      var index = 0;
      while (true) {
        final next = await reader.take(_recordSize);
        final isFinal = next == null;
        yield await _open(record!, fileId, index++, isFinal);
        if (isFinal) break;
        record = next;
      }
    } finally {
      await reader.close();
    }
  }

  /// Encrypts a small value (index, thumbnail) held in memory.
  Future<Uint8List> encryptBytes(List<int> plain) async {
    final builder = BytesBuilder(copy: false);
    await for (final part in encrypt(Stream.value(plain))) {
      builder.add(part);
    }
    return builder.takeBytes();
  }

  /// Decrypts a small value held in memory.
  Future<Uint8List> decryptBytes(List<int> encrypted) async {
    final builder = BytesBuilder(copy: false);
    await for (final part in decrypt(Stream.value(encrypted))) {
      builder.add(part);
    }
    return builder.takeBytes();
  }

  bool _hasMagic(Uint8List header) {
    for (var i = 0; i < magic.length; i++) {
      if (header[i] != magic[i]) return false;
    }
    return true;
  }

  Uint8List _aad(Uint8List fileId, int index, bool isFinal) {
    final aad = Uint8List(fileIdLength + 5)..setRange(0, fileIdLength, fileId);
    ByteData.sublistView(aad).setUint32(fileIdLength, index);
    aad[fileIdLength + 4] = isFinal ? 1 : 0;
    return aad;
  }

  Future<Uint8List> _seal(Uint8List clear, Uint8List fileId, int index, bool isFinal) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(clear, secretKey: _key, nonce: nonce, aad: _aad(fileId, index, isFinal));
    final out = Uint8List(nonceLength + box.cipherText.length + macLength);
    out.setRange(0, nonceLength, nonce);
    out.setRange(nonceLength, nonceLength + box.cipherText.length, box.cipherText);
    out.setRange(out.length - macLength, out.length, box.mac.bytes);
    return out;
  }

  Future<Uint8List> _open(Uint8List record, Uint8List fileId, int index, bool isFinal) async {
    if (record.length < recordOverhead) throw const VaultFormatException('File is truncated');
    final box = SecretBox(
      Uint8List.sublistView(record, nonceLength, record.length - macLength),
      nonce: Uint8List.sublistView(record, 0, nonceLength),
      mac: Mac(Uint8List.sublistView(record, record.length - macLength)),
    );
    try {
      final clear = await _aes.decrypt(box, secretKey: _key, aad: _aad(fileId, index, isFinal));
      return clear is Uint8List ? clear : Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const VaultAuthException();
    }
  }
}

/// Pulls exact-size blocks out of a stream of arbitrary-size parts.
class _ByteReader {
  _ByteReader(Stream<List<int>> source) : _iterator = StreamIterator(source);

  final StreamIterator<List<int>> _iterator;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _done = false;

  /// Returns exactly [n] bytes, fewer only at the end of the stream, or null
  /// when nothing is left.
  Future<Uint8List?> take(int n) async {
    while (_buffer.length < n && !_done) {
      if (await _iterator.moveNext()) {
        final part = _iterator.current;
        if (part.isNotEmpty) _buffer.add(part is Uint8List ? part : Uint8List.fromList(part));
      } else {
        _done = true;
      }
    }
    if (_buffer.isEmpty) return null;
    final all = _buffer.takeBytes();
    if (all.length <= n) return all;
    _buffer.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }

  Future<void> close() => _iterator.cancel();
}
