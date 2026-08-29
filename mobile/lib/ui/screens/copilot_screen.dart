import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/providers.dart';
import '../widgets/proposal_card.dart';

/// The Copilot screen: a trade idea goes in, the deterministic Risk Engine
/// verdict comes back, and only an explicit user approval can execute.
///
/// (The on-device local LLM will later *fill* this same proposal struct —
/// the flow and guard rails stay identical.)
class CopilotScreen extends ConsumerStatefulWidget {
  const CopilotScreen({super.key});

  @override
  ConsumerState<CopilotScreen> createState() => _CopilotScreenState();
}

class _CopilotScreenState extends ConsumerState<CopilotScreen> {
  final _formKey = GlobalKey<FormState>();
  final _symbol = TextEditingController(text: 'RELIANCE');
  final _quantity = TextEditingController(text: '10');
  final _marketPrice = TextEditingController(text: '2450');
  final _stopLoss = TextEditingController(text: '2400');
  final _takeProfit = TextEditingController(text: '2550');
  final _confidence = TextEditingController(text: '0.72');

  bool _evaluating = false;
  bool _executing = false;
  TradeProposal? _proposal;
  RiskVerdict? _verdict;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _symbol,
      _quantity,
      _marketPrice,
      _stopLoss,
      _takeProfit,
      _confidence
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  TradeProposal _readProposal() {
    return TradeProposal(
      symbol: _symbol.text.trim().toUpperCase(),
      side: Side.buy,
      quantity: double.parse(_quantity.text),
      entryPrice: double.tryParse(_marketPrice.text),
      stopLoss: double.tryParse(_stopLoss.text),
      takeProfit: double.tryParse(_takeProfit.text),
      rationale:
          'Template rationale — the local LLM will generate this once the '
          'on-device runtime is integrated.',
      confidence: double.tryParse(_confidence.text),
      source: 'ai',
    );
  }

  Future<void> _evaluate() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _evaluating = true;
      _error = null;
      _verdict = null;
      _proposal = null;
    });
    try {
      final proposal = _readProposal();
      final verdict = await ref.read(apiClientProvider).evaluateProposal(
            proposal,
            marketPrice: double.parse(_marketPrice.text),
          );
      setState(() {
        _proposal = proposal;
        _verdict = verdict;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _evaluating = false);
    }
  }

  Future<void> _approve() async {
    final mode = ref.read(tradingModeProvider);
    final proposal = _proposal;
    if (proposal == null || _verdict == null || !_verdict!.allowed) return;

    if (mode == AccountMode.live) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Live execution is not connected yet — Paper only.'),
      ));
      return;
    }

    setState(() => _executing = true);
    try {
      final result = await ref.read(apiClientProvider).placePaperOrder(
            symbol: proposal.symbol,
            side: proposal.side,
            quantity: proposal.quantity,
            marketPrice: double.parse(_marketPrice.text),
          );
      if (!mounted) return;
      ref.read(journalProvider.notifier).add(
            ExecutedTrade(
              symbol: proposal.symbol,
              side: proposal.side,
              quantity: proposal.quantity,
              filledPrice: result.filledPrice ?? 0,
              at: DateTime.now(),
            ),
          );
      ref.invalidate(accountProvider);
      setState(() {
        _proposal = null;
        _verdict = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.filled
            ? 'Paper order FILLED: ${proposal.side.wire} '
                '${proposal.quantity} ${proposal.symbol} @ '
                '${result.filledPrice?.toStringAsFixed(2)}'
            : 'Order status: ${result.status}'),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  void _reject() {
    setState(() {
      _proposal = null;
      _verdict = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Proposal rejected. Nothing was executed.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Propose a trade',
              style: Theme.of(context).textTheme.titleMedium),
          const Text(
            'The AI can only propose. The Risk Engine decides, and nothing '
            'executes without your approval.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _symbol,
            decoration: const InputDecoration(
                labelText: 'Symbol', border: OutlineInputBorder()),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _quantity,
                decoration: const InputDecoration(
                    labelText: 'Quantity', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (double.tryParse(v ?? '') ?? 0) > 0 ? null : 'Must be > 0',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _marketPrice,
                decoration: const InputDecoration(
                    labelText: 'Market price', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (double.tryParse(v ?? '') ?? 0) > 0 ? null : 'Must be > 0',
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _stopLoss,
                decoration: const InputDecoration(
                    labelText: 'Stop loss', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _takeProfit,
                decoration: const InputDecoration(
                    labelText: 'Target', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextFormField(
            controller: _confidence,
            decoration: const InputDecoration(
                labelText: 'AI confidence (0-1)', border: OutlineInputBorder()),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _evaluating ? null : _evaluate,
            icon: _evaluating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.shield_outlined),
            label: Text(_evaluating ? 'Checking risk…' : 'Run Risk Engine'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (_proposal != null && _verdict != null) ...[
            const SizedBox(height: 16),
            ProposalCard(
              proposal: _proposal!,
              verdict: _verdict!,
              onApprove: _executing ? () {} : _approve,
              onReject: _reject,
            ),
          ],
        ],
      ),
    );
  }
}
