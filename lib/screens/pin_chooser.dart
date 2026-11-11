import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../vault/vault_store.dart';

/// Picks a new PIN: length (4 to 8), enter, confirm.
class PinChooser extends StatefulWidget {
  const PinChooser({super.key, required this.onChosen, this.title = 'Choose a PIN'});

  final ValueChanged<String> onChosen;
  final String title;

  /// Rejects PINs that are trivial to guess: one repeated digit.
  static String? weakness(String pin) {
    if (RegExp(r'^(\d)\1+$').hasMatch(pin)) return 'Do not repeat one digit. Choose another PIN.';
    return null;
  }

  @override
  State<PinChooser> createState() => _PinChooserState();
}

class _PinChooserState extends State<PinChooser> {
  int _length = 6;
  String? _first;
  String? _error;

  void _entered(String pin) {
    if (_first == null) {
      final weak = PinChooser.weakness(pin);
      if (weak != null) {
        setState(() => _error = weak);
        return;
      }
      setState(() {
        _first = pin;
        _error = null;
      });
      return;
    }
    if (pin == _first) {
      widget.onChosen(pin);
    } else {
      setState(() {
        _first = null;
        _error = 'The PINs did not match. Start again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirming = _first != null;
    return SingleChildScrollView(
      child: Column(
        children: [
          Text(confirming ? 'Confirm your PIN' : widget.title, style: context.text.headlineSmall),
          const UiGap(UiSpace.sm),
          Text(
            confirming ? 'Enter the same PIN again.' : 'Use $_length digits. You can change it later in Settings.',
            style: context.text.bodyMedium?.copyWith(color: context.colors.textMuted),
            textAlign: TextAlign.center,
          ),
          const UiGap(UiSpace.lg),
          if (!confirming)
            UiSegmentedControl(
              [
                for (var n = VaultStore.minPinLength; n <= VaultStore.maxPinLength; n++) UiSegment(n, label: '$n'),
              ],
              value: _length,
              onChanged: (n) => setState(() {
                _length = n;
                _error = null;
              }),
            ),
          const UiGap(UiSpace.xl),
          UiPinPad(
            key: ValueKey('$_length-$confirming'),
            length: _length,
            error: _error,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onCompleted: _entered,
          ),
        ],
      ),
    );
  }
}
