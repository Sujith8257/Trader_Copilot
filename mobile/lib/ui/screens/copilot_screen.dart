import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
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

  Side _side = Side.buy;
  double _confidence = 72; // percent
  bool _evaluating = false;
  bool _executing = false;
  TradeProposal? _proposal;
  RiskVerdict? _verdict;
  String? _error;

  @override
  void dispose() {
    for (final c in [_symbol, _quantity, _marketPrice, _stopLoss, _takeProfit]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _step {
    if (_executing) return 3;
    if (_verdict != null) return 2;
    if (_evaluating) return 1;
    return 0;
  }

  TradeProposal _readProposal() {
    return TradeProposal(
      symbol: _symbol.text.trim().toUpperCase(),
      side: _side,
      quantity: double.parse(_quantity.text),
      entryPrice: double.tryParse(_marketPrice.text),
      stopLoss: double.tryParse(_stopLoss.text),
      takeProfit: double.tryParse(_takeProfit.text),
      rationale:
          'Template rationale — the local LLM will generate this once the '
          'on-device runtime is integrated.',
      confidence: _confidence / 100,
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
                '${formatINR(result.filledPrice ?? 0, decimals: 2)}'
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _Pipeline(step: _step),
          const SizedBox(height: 18),
          const SectionHeader('Propose a trade'),
          Text(
            'The AI can only propose. The deterministic Risk Engine decides, '
            'and nothing executes without your approval.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SegmentedButton<Side>(
            segments: const [
              ButtonSegment(
                value: Side.buy,
                icon: Icon(Icons.arrow_downward, size: 16),
                label: Text('BUY'),
              ),
              ButtonSegment(
                value: Side.sell,
                icon: Icon(Icons.arrow_upward, size: 16),
                label: Text('SELL'),
              ),
            ],
            selected: {_side},
            onSelectionChanged: (s) => setState(() => _side = s.first),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _symbol,
            decoration: const InputDecoration(labelText: 'Symbol'),
            textCapitalization: TextCapitalization.characters,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _quantity,
                decoration: const InputDecoration(labelText: 'Quantity'),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (double.tryParse(v ?? '') ?? 0) > 0 ? 'Must be > 0' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _marketPrice,
                decoration: const InputDecoration(
                  labelText: 'Market price',
                  prefixText: '₹ ',
                ),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (double.tryParse(v ?? '') ?? 0) > 0 ? 'Must be > 0' : null,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _stopLoss,
                decoration: const InputDecoration(
                    labelText: 'Stop loss', prefixText: '₹ '),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _takeProfit,
                decoration: const InputDecoration(
                    labelText: 'Target', prefixText: '₹ '),
                keyboardType: TextInputType.number,
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: TC.surfaceHi,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('AI confidence',
                        style: Theme.of(context).textTheme.titleSmall),
                    Text('${_confidence.round()}%',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: TC.gain, fontWeight: FontWeight.w800)),
                  ],
                ),
                Slider(
                  value: _confidence,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${_confidence.round()}%',
                  onChanged: (v) => setState(() => _confidence = v),
                ),
                Row(
                  children: [
                    const Icon(Icons.info_outline, size: 13, color: TC.warn),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'An assessment, not a probability of success.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: TC.warn),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _evaluating ? null : _evaluate,
              icon: _evaluating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.shield_outlined),
              label: Text(_evaluating ? 'Checking risk…' : 'Run Risk Engine'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: TC.loss.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_error!,
                  style: const TextStyle(color: TC.loss, fontSize: 13)),
            ),
          ],
          if (_proposal != null && _verdict != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: ProposalCard(
                key: ValueKey(_proposal),
                proposal: _proposal!,
                verdict: _verdict!,
                onApprove: _executing ? () {} : _approve,
                onReject: _reject,
              ),
            ),
        ],
      ),
    );
  }
}

/// Idea → Risk → Approval → Filled progress header.
class _Pipeline extends StatelessWidget {
  const _Pipeline({required this.step});

  final int step;

  static const _items = [
    (Icons.lightbulb_outline, 'Idea'),
    (Icons.shield_outlined, 'Risk check'),
    (Icons.fact_check_outlined, 'Approval'),
    (Icons.bolt_outlined, 'Filled'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _items.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: i <= step
                    ? TC.gain.withValues(alpha: 0.5)
                    : TC.outline,
              ),
            ),
          Tooltip(
            message: _items[i].$2,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: i <= step
                    ? TC.gain.withValues(alpha: i == step ? 0.22 : 0.12)
                    : TC.surfaceHi,
                shape: BoxShape.circle,
                border: Border.all(
                  color: i <= step
                      ? TC.gain.withValues(alpha: 0.5)
                      : TC.outline,
                ),
              ),
              child: Icon(
                _items[i].$1,
                size: 16,
                color: i <= step ? TC.gain : TC.onBgDim,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

