import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_scope.dart';
import 'pin_chooser.dart';

/// First run: explain, then choose the PIN that protects the vault.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _started = false;
  bool _busy = false;

  Future<void> _create(String pin) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).controller.createVault(pin);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showToast('Could not create the vault.', status: UiStatus.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UiScaffold(
      body: UiLoadingOverlay(
        loading: _busy,
        message: 'Creating your vault',
        child: _started
            ? Center(child: PinChooser(onChosen: _create))
            : Center(
                child: SingleChildScrollView(
                  child: UiColumn(
                    gap: UiSpace.lg,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: UiIconBox(Icons.lock_rounded, size: 72)),
                      Text('Welcome to Pocketlock', style: context.text.headlineMedium, textAlign: TextAlign.center),
                      Text(
                        'Hide photos, videos and files behind a PIN. Everything is encrypted on this phone and '
                        'never leaves it.',
                        style: context.text.bodyLarge?.copyWith(color: context.colors.textMuted),
                        textAlign: TextAlign.center,
                      ),
                      const UiAlert(
                        'Pocketlock has no account, no cloud and no reset. If you forget your PIN and cannot '
                        'use your fingerprint, your files cannot be recovered by anyone.',
                        title: 'Remember your PIN',
                        status: UiStatus.warning,
                      ),
                      UiButton('Set up PIN', expand: true, onPressed: () => setState(() => _started = true)),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
