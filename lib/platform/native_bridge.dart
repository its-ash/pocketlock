import 'package:flutter/services.dart';

/// Failure reported by the Android Keystore or BiometricPrompt.
///
/// [code] is one of `cancelled` (user dismissed the prompt), `invalidated`
/// (biometric key lost, e.g. a new fingerprint was enrolled), `device_key`
/// (the device key cannot open the vault) or `failed`.
class KeystoreException implements Exception {
  const KeystoreException(this.code, [this.message = '']);

  final String code;
  final String message;

  bool get cancelled => code == 'cancelled';

  @override
  String toString() => 'KeystoreException($code)';
}

/// Keystore-backed operations the vault needs. Faked in tests.
abstract class VaultKeystore {
  /// Seals [data] under a non-authenticated, device-bound Keystore key.
  Future<Uint8List> seal(Uint8List data);

  Future<Uint8List> unseal(Uint8List data);

  /// `available`, `none_enrolled` or `unavailable`.
  Future<String> biometricStatus();

  /// Wraps [vmk] under a new biometric-gated key (shows the prompt).
  Future<Uint8List> biometricEnroll(Uint8List vmk);

  /// Returns the VMK after a successful biometric prompt.
  Future<Uint8List> biometricUnlock(Uint8List wrapped);

  Future<void> biometricRemove();
}

/// A document chosen in the system picker.
class PickedFile {
  const PickedFile({required this.uri, required this.name, required this.mime, required this.size, this.mediaUri});

  final String uri;
  final String name;
  final String mime;
  final int size;

  /// MediaStore URI of the original, when it is a gallery photo or video.
  final String? mediaUri;

  factory PickedFile.fromMap(Map<Object?, Object?> map) => PickedFile(
    uri: map['uri']! as String,
    name: map['name']! as String,
    mime: map['mime']! as String,
    size: (map['size']! as num).toInt(),
    mediaUri: map['mediaUri'] as String?,
  );
}

enum DeleteOutcome { deleted, denied, unsupported, failed }

/// MethodChannel client for `MainActivity` (Kotlin).
class NativeBridge implements VaultKeystore {
  NativeBridge() : _channel = const MethodChannel(channelName);

  static const channelName = 'com.itsash.pocketlock/native';

  final MethodChannel _channel;

  Future<T> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      return result as T;
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? '');
    }
  }

  /// FLAG_SECURE: hides the window in recents and blocks screenshots.
  Future<void> setSecure(bool on) => _call<void>('setSecure', {'on': on});

  @override
  Future<Uint8List> seal(Uint8List data) => _call<Uint8List>('deviceSeal', {'data': data});

  @override
  Future<Uint8List> unseal(Uint8List data) => _call<Uint8List>('deviceUnseal', {'data': data});

  @override
  Future<String> biometricStatus() => _call<String>('biometricStatus');

  @override
  Future<Uint8List> biometricEnroll(Uint8List vmk) => _call<Uint8List>('biometricEnroll', {'vmk': vmk});

  @override
  Future<Uint8List> biometricUnlock(Uint8List wrapped) => _call<Uint8List>('biometricUnlock', {'wrapped': wrapped});

  @override
  Future<void> biometricRemove() => _call<void>('biometricRemove');

  /// Opens the system document picker. Empty when the user cancels.
  Future<List<PickedFile>> pick({required bool mediaOnly}) async {
    final list = await _call<List<Object?>>('pick', {'mediaOnly': mediaOnly});
    return [for (final m in list) PickedFile.fromMap((m! as Map).cast<Object?, Object?>())];
  }

  /// Copies a picked document into private cache and returns its path.
  Future<String> stage(String uri) => _call<String>('stage', {'uri': uri});

  Future<void> wipeStaging() => _call<void>('wipeStaging');

  /// JPEG thumbnail of an image or a video file, or null.
  Future<Uint8List?> thumbnail(String path, String mime) async {
    try {
      return await _channel.invokeMethod<Uint8List>('thumbnail', {'path': path, 'mime': mime});
    } on PlatformException {
      return null;
    }
  }

  /// Copies a decrypted file to Pictures, Movies or Downloads (Android 10+).
  /// Throws [KeystoreException] with code `unsupported` on older versions.
  Future<void> export({required String path, required String name, required String mime, required String kind}) =>
      _call<void>('export', {'path': path, 'name': name, 'mime': mime, 'kind': kind});

  /// Asks the system to delete the gallery originals (Android 11+). The
  /// system shows its own confirmation.
  Future<DeleteOutcome> deleteOriginals(List<String> mediaUris) async {
    final result = await _call<String>('deleteOriginals', {'uris': mediaUris});
    return DeleteOutcome.values.firstWhere((o) => o.name == result, orElse: () => DeleteOutcome.failed);
  }
}
