import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// Optional biometric app lock (fingerprint / face). Enabled in Settings;
/// when on, the whole app sits behind a system biometric prompt. Falls back
/// gracefully: if the device has no biometrics or the plugin errors, the
/// app unlocks rather than bricking itself.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  bool? _lockEnabled; // null = still loading prefs
  bool _unlocked = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _lockEnabled = sp.getBool('biometric_lock') ?? false;
    });
    if (_lockEnabled!) await _authenticate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock when the app goes to background and comes back.
    if (state == AppLifecycleState.resumed &&
        _lockEnabled == true &&
        !_unlocked) {
      _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock Trader Copilot',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      if (mounted) setState(() => _unlocked = ok);
    } catch (_) {
      // no hardware / plugin error — fail open, never lock the user out
      if (mounted) setState(() => _unlocked = true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_lockEnabled != true || _unlocked) return widget.child;
    return Scaffold(
      backgroundColor: TC.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: TC.heroGradient),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: TC.outline),
              ),
              child:
                  const Icon(Icons.lock_outline, size: 34, color: TC.gain),
            ),
            const SizedBox(height: 20),
            Text('Trader Copilot is locked',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('Authenticate with your fingerprint or face.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.fingerprint),
              label: Text(_checking ? 'Checking…' : 'Unlock'),
              onPressed: _checking ? null : _authenticate,
            ),
          ],
        ),
      ),
    );
  }
}
