import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/agent/llm_client.dart';
import '../../state/providers.dart';
import '../theme.dart';

/// On-phone settings: agentic brain (Termux Qwen / Gemini / Groq / rule),
/// Coinbase credentials (secure storage), and risk limits. Everything the
/// app needs to run standalone lives here.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late BrainKind _kind;
  late TextEditingController _url;
  late TextEditingController _model;
  late TextEditingController _brainKey;
  late TextEditingController _cbKey;
  late TextEditingController _cbSecret;
  String? _probeResult;
  bool _probing = false;
  bool _savingCb = false;
  bool _bioLock = false;

  Future<void> _toggleBioLock(bool v) async {
    if (v) {
      // Verify once before enabling, so we know the device supports it.
      try {
        final ok = await LocalAuthentication().authenticate(
          localizedReason: 'Confirm to enable the app lock',
          options:
              const AuthenticationOptions(stickyAuth: true, biometricOnly: true),
        );
        if (!ok) return;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'No biometrics available on this device — lock not enabled.')));
        }
        return;
      }
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('biometric_lock', v);
    if (mounted) setState(() => _bioLock = v);
  }

  @override
  void initState() {
    super.initState();
    _kind = BrainKind.rule;
    _url = TextEditingController();
    _model = TextEditingController();
    _brainKey = TextEditingController();
    _cbKey = TextEditingController();
    _cbSecret = TextEditingController();
    _hydrate();
  }

  Future<void> _hydrate() async {
    final svc = ref.read(tradingServiceProvider);
    await svc.ensureLoaded();
    if (!mounted) return;
    final s = svc.settings;
    setState(() {
      _kind = s.brain.kind;
      _url.text = s.brain.baseUrl;
      _model.text = s.brain.model;
      _brainKey.text = s.brain.apiKey;
      _cbKey.text = s.coinbaseKey;
      _cbSecret.text = s.coinbaseSecret;
    });
    final bio = await SharedPreferences.getInstance()
        .then((sp) => sp.getBool('biometric_lock') ?? false);
    if (mounted) setState(() => _bioLock = bio);
  }

  @override
  void dispose() {
    for (final c in [_url, _model, _brainKey, _cbKey, _cbSecret]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveBrain() async {
    final cfg = BrainConfig.defaults(
      _kind,
      baseUrl: _url.text.trim(),
      apiKey: _brainKey.text.trim(),
      model: _model.text.trim(),
    );
    await ref.read(tradingServiceProvider).saveBrain(cfg);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Agent brain saved.')));
    }
  }

  /// Switch provider and prefill the fields with that provider's defaults
  /// (keeping anything already typed that still applies).
  void _pickBrain(BrainKind k) {
    final preset = BrainConfig.defaults(k);
    setState(() {
      _kind = k;
      _url.text = preset.baseUrl;
      _model.text = preset.model;
    });
  }

  Future<void> _probeBrain() async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    try {
      final cfg = BrainConfig.defaults(_kind,
          baseUrl: _url.text.trim(),
          apiKey: _brainKey.text.trim(),
          model: _model.text.trim());
      final reply = await LlmClient().probe(cfg);
      setState(() => _probeResult = 'OK — brain replied: "$reply"');
    } catch (e) {
      setState(() => _probeResult = 'FAILED: $e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _saveCoinbase() async {
    setState(() => _savingCb = true);
    try {
      await ref.read(tradingServiceProvider).saveCoinbaseCredentials(
            key: _cbKey.text.trim(),
            secret: _cbSecret.text.trim(),
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Coinbase credentials stored in the Android Keystore.')));
      }
    } finally {
      if (mounted) setState(() => _savingCb = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(tradingServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const _SectionTitle('Agent brain'),
          Text(
            'The crew thinks with this LLM. Pick any provider — every one '
            'speaks the same OpenAI-compatible protocol, so the whole agentic '
            'flow stays identical.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.6, // tall enough for label + 2-line subtitle
            children: [
              for (final k in BrainKind.values)
                _ProviderCard(
                  kind: k,
                  selected: _kind == k,
                  onTap: () => _pickBrain(k),
                ),
            ],
          ),
          if (_kind == BrainKind.rule)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Rule brain runs fully offline — no URL, no key. The crew uses '
                'deterministic momentum/RSI logic instead of an LLM.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else ...[
            if (_kind == BrainKind.localServer)
              Text(
                'Point this at any llama-server / LM Studio / Ollama on the '
                'phone (Termux: http://127.0.0.1:8080/v1) or your PC on the '
                'same Wi-Fi (e.g. http://10.156.105.149:8080/v1 — take your '
                'web chat URL, drop the #/chat part, add /v1).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            _Field(_url,
                _kind == BrainKind.localServer ? 'Base URL' : 'Base URL (optional override)'),
            if (_kind.needsKey)
              _Field(_brainKey, 'API key',
                  obscure: true, hint: _kind.keyHint),
            _Field(_model, 'Model name', hint: 'e.g. qwen3.5-9b'),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: _saveBrain,
                child: const Text('Save brain'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _probing ? null : _probeBrain,
                child: Text(_probing ? 'Testing…' : 'Test brain'),
              ),
            ),
          ]),
          if (_probeResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_probeResult!,
                  style: const TextStyle(fontSize: 12.5, color: TC.onBg)),
            ),
          const SizedBox(height: 24),
          const _SectionTitle('Coinbase (live trading + live account)'),
          Text(
            'Paste the CDP API key JSON contents from the Coinbase portal. '
            'Stored in the Android Keystore — never synced, never exported.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          _Field(_cbKey, 'API key ID'),
          _Field(_cbSecret, 'Private key (base64)', obscure: true),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _savingCb ? null : _saveCoinbase,
            child: Text(_savingCb ? 'Saving…' : 'Save Coinbase credentials'),
          ),
          const SizedBox(height: 6),
          Builder(builder: (context) {
            final ok = svc.settings.coinbaseConfigured;
            return Text(
              ok
                  ? 'Configured — Live mode is unlocked.'
                  : 'Not configured — Live mode stays locked.',
              style:
                  TextStyle(fontSize: 12.5, color: ok ? TC.gain : TC.onBgDim),
            );
          }),
          const SizedBox(height: 24),
          const _SectionTitle('Security'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Biometric app lock'),
            subtitle: const Text(
                'Fingerprint / face required to open the app. Keys stay in '
                'the Android Keystore either way.'),
            value: _bioLock,
            activeThumbColor: TC.gain,
            onChanged: _toggleBioLock,
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Risk limits'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Risk Engine enabled'),
            subtitle: const Text('Kill switch — off blocks every proposal'),
            value: svc.risk.config.enabled,
            activeThumbColor: TC.gain,
            onChanged: (v) => setState(() => svc.risk.config.enabled = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Max position size'),
            subtitle: Text(
                '₹${svc.risk.config.maxPositionNotional.toStringAsFixed(0)} per position'),
            trailing: SizedBox(
              width: 190,
              child: Slider(
                value: svc.risk.config.maxPositionNotional,
                min: 5000,
                max: 100000,
                divisions: 19,
                label:
                    '₹${svc.risk.config.maxPositionNotional.toStringAsFixed(0)}',
                onChanged: (v) =>
                    setState(() => svc.risk.config.maxPositionNotional = v),
              ),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Max open positions'),
            subtitle: Text('${svc.risk.config.maxOpenPositions}'),
            trailing: SizedBox(
              width: 190,
              child: Slider(
                value: svc.risk.config.maxOpenPositions.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '${svc.risk.config.maxOpenPositions}',
                onChanged: (v) =>
                    setState(() => svc.risk.config.maxOpenPositions = v.round()),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Paper account'),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset paper account to ₹10,00,000'),
            onPressed: () async {
              final svc = ref.read(tradingServiceProvider);
              await svc.ensureLoaded();
              svc.paper.reset();
              ref.invalidate(accountProvider);
              ref.invalidate(historyProvider);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Paper account reset.')));
            },
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
      );
}

class _Field extends StatelessWidget {
  const _Field(this.controller, this.label, {this.hint, this.obscure = false});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}

/// One selectable LLM provider card in the brain picker.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard(
      {required this.kind, required this.selected, required this.onTap});

  final BrainKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? TC.gain.withValues(alpha: 0.10) : TC.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? TC.gain : TC.outline,
              width: selected ? 1.4 : 1),
        ),
        child: Row(
          children: [
            Icon(kind.icon,
                size: 20, color: selected ? TC.gain : TC.onBgDim),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    kind.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: selected ? TC.gain : TC.onBg,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    kind.subtitle,
                    style: const TextStyle(
                        fontSize: 10, color: TC.onBgDim),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, size: 16, color: TC.gain),
          ],
        ),
      ),
    );
  }
}
