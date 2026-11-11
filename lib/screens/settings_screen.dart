import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_scope.dart';
import '../app/settings_store.dart';
import 'change_pin_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _biometricStatus = 'unavailable';
  bool _bound = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bound) return;
    _bound = true;
    AppScope.of(context).controller.native.biometricStatus().then((status) {
      if (mounted) setState(() => _biometricStatus = status);
    }).catchError((Object _) {});
  }

  static String _autoLockLabel(int seconds) => switch (seconds) {
    0 => 'Immediately',
    30 => 'After 30 seconds',
    60 => 'After 1 minute',
    _ => 'After $seconds seconds',
  };

  Future<void> _pickAutoLock() async {
    final controller = AppScope.of(context).controller;
    final value = await UiActionSheet.show<int>(
      context,
      title: 'Auto-lock',
      message: 'When Pocketlock leaves the screen, lock the vault:',
      actions: [for (final s in SettingsStore.autoLockChoices) UiSheetAction(_autoLockLabel(s), value: s)],
    );
    if (value != null) await controller.setAutoLockSeconds(value);
  }

  Future<void> _setBiometric(bool on) async {
    final ok = await AppScope.of(context).controller.setBiometric(on);
    if (!ok && mounted) {
      context.showToast(
        on ? 'Fingerprint unlock was not turned on.' : 'Could not turn fingerprint unlock off.',
        status: UiStatus.warning,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context).controller;
    final vault = controller.vault;
    return UiScaffold(
      appBar: const UiAppBar(title: 'Settings'),
      scrollable: true,
      body: ListenableBuilder(
        listenable: Listenable.merge([vault, controller.settings]),
        builder: (context, _) {
          final canUseBiometric = _biometricStatus == 'available' || vault.biometricEnabled;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const UiAlert(
                'If you forget your PIN and lose fingerprint access, your files cannot be recovered. '
                'There is no backend and no reset.',
                title: 'No recovery',
                status: UiStatus.warning,
              ),
              const UiGap(UiSpace.lg),
              UiListGroup(
                header: 'Unlock',
                footer: switch (_biometricStatus) {
                  'none_enrolled' => 'Add a fingerprint in Android settings to use it here.',
                  'unavailable' when !vault.biometricEnabled => 'This phone has no strong biometric sensor.',
                  _ => 'The fingerprint unlocks the vault key stored in the Android Keystore. Your PIN always works too.',
                },
                children: [
                  UiSwitchTile(
                    'Fingerprint unlock',
                    icon: Icons.fingerprint_rounded,
                    value: vault.biometricEnabled,
                    onChanged: canUseBiometric ? _setBiometric : null,
                  ),
                  UiListTile(
                    'Change PIN',
                    icon: Icons.pin_rounded,
                    chevron: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const ChangePinScreen()),
                    ),
                  ),
                ],
              ),
              const UiGap(UiSpace.lg),
              UiListGroup(
                header: 'Privacy',
                footer: 'Hidden from recents also blocks screenshots and screen recording.',
                children: [
                  UiListTile(
                    'Auto-lock',
                    icon: Icons.timer_rounded,
                    value: _autoLockLabel(controller.settings.autoLockSeconds),
                    chevron: true,
                    onTap: _pickAutoLock,
                  ),
                  UiSwitchTile(
                    'Hide from recents',
                    icon: Icons.visibility_off_rounded,
                    value: controller.settings.hideFromRecents,
                    onChanged: controller.setHideFromRecents,
                  ),
                ],
              ),
              const UiGap(UiSpace.lg),
              const UiAppearanceSection(),
              const UiGap(UiSpace.lg),
              const UiUpdateSection(storeId: 'pocketlock'),
              const UiGap(UiSpace.lg),
              const UiDeveloperSection(),
            ],
          );
        },
      ),
    );
  }
}
