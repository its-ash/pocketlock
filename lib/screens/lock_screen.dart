import 'dart:async';

import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_controller.dart';
import '../app/app_scope.dart';

/// Unlock with the PIN or, when enabled, the fingerprint.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with WidgetsBindingObserver {
  Timer? _ticker;
  String? _error;
  bool _busy = false;
  bool _prompted = false;
  late AppController _controller;
  bool _bound = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bound) return;
    _bound = true;
    _controller = AppScope.of(context).controller;
    _syncTicker();
    // Offer the fingerprint right away when the app is in front.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrompt());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_busy) _prompted = false;
    if (state == AppLifecycleState.resumed) _autoPrompt();
  }

  void _autoPrompt() {
    if (!mounted || _prompted || _busy) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    if (!_controller.vault.biometricEnabled || _controller.lockoutRemaining > Duration.zero) return;
    _prompted = true;
    _biometric();
  }

  /// Ticks once a second while a wrong-PIN delay is running.
  void _syncTicker() {
    final locked = _controller.lockoutRemaining > Duration.zero;
    if (locked && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_controller.lockoutRemaining <= Duration.zero) {
          _ticker?.cancel();
          _ticker = null;
          setState(() => _error = null);
        } else {
          setState(() {});
        }
      });
    }
  }

  Future<void> _submit(String pin) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _controller.unlockWithPin(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = switch (result) {
        UnlockResult.wrongPin => 'Wrong PIN',
        UnlockResult.error => 'Could not open the vault',
        _ => null,
      };
    });
    _syncTicker();
  }

  Future<void> _biometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await _controller.unlockWithBiometric();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case UnlockResult.biometricLost:
        setState(() => _error = 'Fingerprint changed. Use your PIN, then turn fingerprint unlock on again.');
      case UnlockResult.error:
        context.showToast('Fingerprint unlock failed. Use your PIN.', status: UiStatus.warning);
      default:
        break;
    }
  }

  String _lockoutText(Duration left) {
    final minutes = left.inMinutes;
    final seconds = left.inSeconds % 60;
    return 'Too many wrong tries. Try again in ${minutes > 0 ? '$minutes min ' : ''}$seconds s.';
  }

  @override
  Widget build(BuildContext context) {
    final vault = _controller.vault;
    final left = _controller.lockoutRemaining;
    final lockedOut = left > Duration.zero;
    return UiScaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const UiIconBox(Icons.lock_rounded, size: 64),
              const UiGap(UiSpace.lg),
              Text('Pocketlock', style: context.text.headlineSmall),
              const UiGap(UiSpace.xs),
              Text(
                'Enter your PIN',
                style: context.text.bodyMedium?.copyWith(color: context.colors.textMuted),
              ),
              const UiGap(UiSpace.xl),
              UiPinPad(
                key: ValueKey(vault.pinLength),
                length: vault.pinLength,
                enabled: !_busy && !lockedOut,
                error: lockedOut ? _lockoutText(left) : _error,
                onBiometric: vault.biometricEnabled ? _biometric : null,
                onCompleted: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
