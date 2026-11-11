import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_controller.dart';
import '../app/app_scope.dart';
import 'pin_chooser.dart';

/// Change the PIN: current PIN, then a new one. Files are not re-encrypted:
/// only the wrapped vault key changes.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key});

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  String? _current;
  String? _error;
  bool _busy = false;

  Future<void> _apply(String newPin) async {
    final scope = AppScope.of(context);
    final current = _current!;
    setState(() => _busy = true);
    final result = await scope.controller.changePin(current, newPin);
    if (!mounted) return;
    switch (result) {
      case UnlockResult.success:
        Navigator.of(context).pop();
        context.showToast('PIN changed.', status: UiStatus.success);
      case UnlockResult.wrongPin:
        setState(() {
          _busy = false;
          _current = null;
          _error = 'Wrong current PIN';
        });
      case UnlockResult.lockedOut:
        Navigator.of(context).pop();
        context.showToast('Too many wrong tries. Try again later.', status: UiStatus.danger);
      default:
        setState(() {
          _busy = false;
          _current = null;
        });
        context.showToast('Could not change the PIN.', status: UiStatus.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = AppScope.of(context).controller.vault;
    return UiScaffold(
      appBar: const UiAppBar(title: 'Change PIN'),
      body: UiLoadingOverlay(
        loading: _busy,
        message: 'Updating your PIN',
        child: Center(
          child: _current == null
              ? SingleChildScrollView(
                  child: Column(
                    children: [
                      Text('Enter your current PIN', style: context.text.headlineSmall),
                      const UiGap(UiSpace.xl),
                      UiPinPad(
                        key: ValueKey(vault.pinLength),
                        length: vault.pinLength,
                        error: _error,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        onCompleted: (pin) => setState(() => _current = pin),
                      ),
                    ],
                  ),
                )
              : PinChooser(title: 'Choose a new PIN', onChosen: _apply),
        ),
      ),
    );
  }
}
