import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
            'The crew thinks with this LLM. Rule brain = fully offline, no '
            'key. Local = your Termux llama-server / Ollama on this phone.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          SegmentedButton<BrainKind>(
            segments: const [
              ButtonSegment(value: BrainKind.rule, label: Text('Rule')),
              ButtonSegment(
                  value: BrainKind.localServer, label: Text('Local')),
              ButtonSegment(value: BrainKind.gemini, label: Text('Gemini')),
              ButtonSegment(value: BrainKind.groq, label: Text('Groq')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          if (_kind == BrainKind.localServer) ...[
            _Field(_url, 'Base URL', hint: 'http://127.0.0.1:8080/v1'),
            _Field(_model, 'Model name', hint: 'qwen3.5-9b'),
          ],
          if (_kind == BrainKind.gemini || _kind == BrainKind.groq) ...[
            _Field(_url, 'Base URL (optional override)'),
            _Field(_brainKey, 'API key', obscure: true),
            _Field(_model, 'Model name (optional)'),
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
