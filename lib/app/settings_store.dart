import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Increasing delay after wrong PINs: free for the first two, then 30 s,
/// doubling per failure up to one hour.
Duration pinLockoutFor(int failures) {
  if (failures < 3) return Duration.zero;
  final seconds = 30 * pow(2, min(failures - 3, 7)).toInt();
  return Duration(seconds: min(seconds, 3600));
}

/// Non-secret preferences and the wrong-PIN counter.
///
/// The counter lives in SharedPreferences, so it survives app restarts. It is
/// a speed bump, not a defense against someone who copies the data off the
/// phone: that is what the KDF and the Keystore-sealed key are for.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  static Future<SettingsStore> load() async => SettingsStore(await SharedPreferences.getInstance());

  static const _autoLock = 'auto_lock_seconds';
  static const _hideRecents = 'hide_from_recents';
  static const _failures = 'pin_failures';
  static const _lockedUntil = 'pin_locked_until_ms';

  /// Auto-lock choices in seconds. 0 locks as soon as the app leaves the screen.
  static const autoLockChoices = [0, 30, 60];

  final SharedPreferences _prefs;

  int get autoLockSeconds => _prefs.getInt(_autoLock) ?? 0;

  bool get hideFromRecents => _prefs.getBool(_hideRecents) ?? true;

  int get failedAttempts => _prefs.getInt(_failures) ?? 0;

  /// Time left before another PIN try is allowed, or zero.
  Duration lockoutRemaining([DateTime? now]) {
    final until = _prefs.getInt(_lockedUntil);
    if (until == null) return Duration.zero;
    final left = DateTime.fromMillisecondsSinceEpoch(until).difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Future<void> setAutoLockSeconds(int seconds) async {
    await _prefs.setInt(_autoLock, seconds);
    notifyListeners();
  }

  Future<void> setHideFromRecents(bool value) async {
    await _prefs.setBool(_hideRecents, value);
    notifyListeners();
  }

  Future<void> recordFailure([DateTime? now]) async {
    final failures = failedAttempts + 1;
    await _prefs.setInt(_failures, failures);
    final delay = pinLockoutFor(failures);
    if (delay > Duration.zero) {
      final until = (now ?? DateTime.now()).add(delay);
      await _prefs.setInt(_lockedUntil, until.millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  Future<void> resetFailures() async {
    await _prefs.remove(_failures);
    await _prefs.remove(_lockedUntil);
    notifyListeners();
  }
}
