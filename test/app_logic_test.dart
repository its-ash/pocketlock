import 'package:flutter_test/flutter_test.dart';
import 'package:pocketlock/app/settings_store.dart';
import 'package:pocketlock/screens/pin_chooser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('pinLockoutFor', () {
    test('first two wrong PINs are free', () {
      expect(pinLockoutFor(0), Duration.zero);
      expect(pinLockoutFor(1), Duration.zero);
      expect(pinLockoutFor(2), Duration.zero);
    });

    test('then 30 s, doubling each failure', () {
      expect(pinLockoutFor(3), const Duration(seconds: 30));
      expect(pinLockoutFor(4), const Duration(seconds: 60));
      expect(pinLockoutFor(5), const Duration(seconds: 120));
      expect(pinLockoutFor(6), const Duration(seconds: 240));
    });

    test('never exceeds one hour', () {
      expect(pinLockoutFor(10), const Duration(hours: 1));
      expect(pinLockoutFor(1000), const Duration(hours: 1));
    });
  });

  group('SettingsStore', () {
    late SettingsStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await SettingsStore.load();
    });

    test('defaults: lock immediately, hide from recents', () {
      expect(store.autoLockSeconds, 0);
      expect(store.hideFromRecents, isTrue);
      expect(store.failedAttempts, 0);
      expect(store.lockoutRemaining(), Duration.zero);
    });

    test('wrong PINs lock out with a growing delay and persist', () async {
      final now = DateTime(2026, 1, 1, 12);
      await store.recordFailure(now);
      await store.recordFailure(now);
      expect(store.lockoutRemaining(now), Duration.zero);

      await store.recordFailure(now);
      expect(store.lockoutRemaining(now), const Duration(seconds: 30));
      expect(store.lockoutRemaining(now.add(const Duration(seconds: 31))), Duration.zero);

      await store.recordFailure(now);
      expect(store.lockoutRemaining(now), const Duration(seconds: 60));

      final reloaded = await SettingsStore.load();
      expect(reloaded.failedAttempts, 4);
      expect(reloaded.lockoutRemaining(now), const Duration(seconds: 60));
    });

    test('a correct PIN resets the counter', () async {
      final now = DateTime(2026, 1, 1, 12);
      for (var i = 0; i < 5; i++) {
        await store.recordFailure(now);
      }
      await store.resetFailures();
      expect(store.failedAttempts, 0);
      expect(store.lockoutRemaining(now), Duration.zero);
    });

    test('saves the auto-lock delay and the recents setting', () async {
      await store.setAutoLockSeconds(60);
      await store.setHideFromRecents(false);
      expect(store.autoLockSeconds, 60);
      expect(store.hideFromRecents, isFalse);
    });
  });

  group('PinChooser.weakness', () {
    test('rejects one repeated digit', () {
      expect(PinChooser.weakness('1111'), isNotNull);
      expect(PinChooser.weakness('00000000'), isNotNull);
    });

    test('accepts other PINs', () {
      expect(PinChooser.weakness('1234'), isNull);
      expect(PinChooser.weakness('112233'), isNull);
    });
  });
}
