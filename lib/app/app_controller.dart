import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import '../crypto/chunk_cipher.dart';
import '../platform/native_bridge.dart';
import '../vault/vault_store.dart';
import 'settings_store.dart';
import 'temp_files.dart';

enum AppStatus { loading, setup, locked, unlocked }

enum UnlockResult { success, wrongPin, lockedOut, cancelled, biometricLost, error }

/// Owns the lock state: which screen shows, when to auto-lock, and the
/// wrong-PIN rate limit.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    required this.vault,
    required this.settings,
    required this.native,
    required this.temp,
    required this.navigatorKey,
  });

  final VaultStore vault;
  final SettingsStore settings;
  final NativeBridge native;
  final TempFiles temp;
  final GlobalKey<NavigatorState> navigatorKey;

  AppStatus _status = AppStatus.loading;
  int _suppressed = 0;
  DateTime? _leftAt;

  AppStatus get status => _status;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    await vault.load();
    // Plaintext leftovers from a crash or a kill while unlocked.
    await temp.wipe();
    unawaited(native.wipeStaging().catchError((Object _) {}));
    unawaited(native.setSecure(settings.hideFromRecents).catchError((Object _) {}));
    _setStatus(vault.exists ? AppStatus.locked : AppStatus.setup);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setStatus(AppStatus value) {
    _status = value;
    notifyListeners();
  }

  // ---- unlock -------------------------------------------------------------

  Future<void> createVault(String pin) async {
    await vault.create(pin);
    _setStatus(AppStatus.unlocked);
  }

  Duration get lockoutRemaining => settings.lockoutRemaining();

  Future<UnlockResult> unlockWithPin(String pin) async {
    if (lockoutRemaining > Duration.zero) return UnlockResult.lockedOut;
    try {
      await vault.unlockWithPin(pin);
    } on VaultAuthException {
      await settings.recordFailure();
      return lockoutRemaining > Duration.zero ? UnlockResult.lockedOut : UnlockResult.wrongPin;
    } on KeystoreException {
      return UnlockResult.error;
    } on VaultFormatException {
      return UnlockResult.error;
    }
    await settings.resetFailures();
    _setStatus(AppStatus.unlocked);
    return UnlockResult.success;
  }

  Future<UnlockResult> unlockWithBiometric() async {
    if (!vault.biometricEnabled) return UnlockResult.biometricLost;
    try {
      await suppressLock(vault.unlockWithBiometric);
    } on KeystoreException catch (e) {
      if (e.cancelled) return UnlockResult.cancelled;
      return e.code == 'invalidated' ? UnlockResult.biometricLost : UnlockResult.error;
    } on VaultAuthException {
      return UnlockResult.error;
    }
    _setStatus(AppStatus.unlocked);
    return UnlockResult.success;
  }

  /// Verifies the current PIN and sets a new one. Shares the wrong-PIN limit.
  Future<UnlockResult> changePin(String oldPin, String newPin) async {
    if (lockoutRemaining > Duration.zero) return UnlockResult.lockedOut;
    try {
      await vault.changePin(oldPin, newPin);
    } on VaultAuthException {
      await settings.recordFailure();
      return lockoutRemaining > Duration.zero ? UnlockResult.lockedOut : UnlockResult.wrongPin;
    } on KeystoreException {
      return UnlockResult.error;
    }
    await settings.resetFailures();
    return UnlockResult.success;
  }

  // ---- lock ---------------------------------------------------------------

  /// Locks now: drops keys, decrypted copies and cached images, and closes
  /// every screen above the lock gate.
  void lock() {
    if (_status != AppStatus.unlocked) return;
    vault.lock();
    unawaited(temp.wipe());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _leftAt = null;
    _setStatus(AppStatus.locked);
  }

  /// Runs [action] without auto-locking when the app is covered by a system
  /// screen (picker, biometric prompt, share sheet, delete confirmation).
  Future<T> suppressLock<T>(Future<T> Function() action) async {
    _suppressed++;
    try {
      return await action();
    } finally {
      _suppressed--;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_status != AppStatus.unlocked || _suppressed > 0) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _leftAt ??= DateTime.now();
        if (settings.autoLockSeconds == 0) lock();
      case AppLifecycleState.resumed:
        final left = _leftAt;
        _leftAt = null;
        if (left != null && DateTime.now().difference(left).inSeconds >= settings.autoLockSeconds) lock();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  // ---- settings -----------------------------------------------------------

  Future<void> setAutoLockSeconds(int seconds) => settings.setAutoLockSeconds(seconds);

  Future<void> setHideFromRecents(bool value) async {
    await settings.setHideFromRecents(value);
    await native.setSecure(value);
  }

  Future<bool> setBiometric(bool enabled) async {
    try {
      await suppressLock(enabled ? vault.enableBiometric : vault.disableBiometric);
      return true;
    } on KeystoreException {
      return false;
    }
  }
}
