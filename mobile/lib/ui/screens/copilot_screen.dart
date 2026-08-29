import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_engine.dart';
import '../../core/engine/risk_engine.dart';
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
  final _symbol = TextEditingController(text: 'BTC');
  final _quantity = TextEditingController(text: '0.003');
  final _stopLoss = TextEditingController();
  final _takeProfit = TextEditingController();

  Side _side = Side.buy;
  double _confidence = 72; // percent
  bool _evaluating = false;
  bool _executing = false;
  double? _livePrice;
  AgentProposal? _proposal;
  String? _error;

  @override
  void dispose() {
    for (final c in [_symbol, _quantity, _stopLoss, _takeProfit]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _step {
    if (_executing) return 3;
    if (_proposal != null) return 2;
    if (_evaluating) return 1;
    return 0;
  }

  /// Fetch the LIVE Coinbase price for the typed symbol.
  Future<void> _fetchPrice() async {
    final sym = _symbol.text.trim().toUpperCase();
    if (sym.isEmpty) return;
    setState(() => _error = null);
    try {
      final price = await ref.read(tradingServiceProvider).market.last(sym);
      setState(() => _livePrice = price);
    } catch (e) {
      setState(() {
        _livePrice = null;
        _error = 'Could not fetch the live price for $sym: $e';
      });
    }
  }

  Future<void> _evaluate() async {
    if (!_formKey.currentState!.validate()) return;
    if (_livePrice == null) {
      await _fetchPrice();
      if (_livePrice == null) return;
    }
    setState(() {
      _evaluating = true;
      _error = null;
      _proposal = null;
    });
    try {
      final svc = ref.read(tradingServiceProvider);
      final p = AgentProposal(
        symbol: _symbol.text.trim().toUpperCase(),
        side: _side,
        quantity: double.parse(_quantity.text),
        marketPrice: _livePrice!,
        stopLoss: double.tryParse(_stopLoss.text),
        takeProfit: double.tryParse(_takeProfit.text),
        rationale: 'Manual proposal — Risk Engine checked on-device.',
        confidence: _confidence / 100,
        verdict: svc.risk.evaluate(
          symbol: _symbol.text.trim().toUpperCase(),
          side: _side,
          quantity: double.parse(_quantity.text),
          marketPrice: _livePrice!,
          account: svc.paper.account,
          entryPrice: _livePrice!,
          stopLoss: double.tryParse(_stopLoss.text),
          takeProfit: double.tryParse(_takeProfit.text),
          source: 'manual',
        ),
      );
      setState(() => _proposal = p);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _evaluating = false);
    }
  }

  Future<void> _approve() async {
    final proposal = _proposal;
    if (proposal == null || !proposal.verdict.allowed || _executing) return;
    final mode = ref.read(tradingModeProvider);
    setState(() => _executing = true);
    try {
      final exec = await ref
          .read(tradingServiceProvider)
          .execute(proposal, mode);
      if (!mounted) return;
      if (exec.executed) {
        ref
            .read(journalProvider.notifier)
            .add(
              ExecutedTrade(
                symbol: proposal.symbol,
                side: proposal.side,
                quantity: proposal.quantity,
                filledPrice: exec.fillPrice ?? proposal.marketPrice,
                at: DateTime.now(),
              ),
            );
        ref.invalidate(accountProvider);
        ref.invalidate(historyProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${proposal.side.wire} ${proposal.quantity} '
              '${proposal.symbol} filled at '
              '₹${(exec.fillPrice ?? proposal.marketPrice).toStringAsFixed(2)}',
            ),
          ),
        );
        setState(() => _proposal = null);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Not executed: ${exec.reason ?? 'rejected'}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Execution failed: $e')));
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  void _reject() {
    setState(() => _proposal = null);
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
          const _AutopilotCard(),
          const _PendingQueue(),
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
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _symbol,
                  decoration: const InputDecoration(
                    labelText: 'Symbol (e.g. BTC, ETH, SOL)',
                  ),
                  textCapitalization: TextCapitalization.characters,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: _fetchPrice,
                  icon: const Icon(Icons.bolt, size: 18),
                  label: const Text('Live price'),
                ),
              ),
            ],
          ),
          if (_livePrice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'LIVE Coinbase: ₹${_livePrice!.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: TC.gain, fontWeight: FontWeight.w800),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _quantity,
                  decoration: const InputDecoration(labelText: 'Quantity'),
                  keyboardType: TextInputType.number,
                  validator: (v) => (double.tryParse(v ?? '') ?? 0) > 0
                      ? 'Must be > 0'
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _stopLoss,
                  decoration: const InputDecoration(
                    labelText: 'Stop loss',
                    prefixText: '₹ ',
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _takeProfit,
                  decoration: const InputDecoration(
                    labelText: 'Target',
                    prefixText: '₹ ',
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
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
                    Text(
                      'AI confidence',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${_confidence.round()}%',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: TC.gain,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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
                        style: Theme.of(context).textTheme.bodySmall
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
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
              child: Text(
                _error!,
                style: const TextStyle(color: TC.loss, fontSize: 13),
              ),
            ),
          ],
          if (_proposal != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: ProposalCard(
                key: ValueKey(_proposal),
                proposal: TradeProposal(
                  symbol: _proposal!.symbol,
                  side: _proposal!.side,
                  quantity: _proposal!.quantity,
                  entryPrice: _proposal!.marketPrice,
                  stopLoss: _proposal!.stopLoss,
                  takeProfit: _proposal!.takeProfit,
                  rationale: _proposal!.rationale,
                  confidence: _proposal!.confidence,
                  source: 'manual',
                ),
                verdict: RiskVerdict(
                  allowed: _proposal!.verdict.allowed,
                  violations: _proposal!.verdict.violations,
                  warnings: _proposal!.verdict.warnings,
                ),
                liveMode: ref.watch(tradingModeProvider) == AccountMode.live,
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
                color: i <= step ? TC.gain.withValues(alpha: 0.5) : TC.outline,
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

/// Autopilot: the agentic crew re-runs on a timer while the app is open.
/// Proposals land in the queue below — still approval-gated, still
/// Risk-Engine-checked. Nothing ever auto-executes.
class _AutopilotCard extends ConsumerWidget {
  const _AutopilotCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ap = ref.watch(autopilotProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_mode,
                  size: 18,
                  color: ap.enabled ? TC.gain : TC.onBgDim,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Autopilot',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Switch(
                  value: ap.enabled,
                  activeThumbColor: TC.gain,
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    ref.read(autopilotProvider.notifier).setEnabled(v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              ap.enabled
                  ? (ap.running
                        ? 'Crew is working on your goal…'
                        : 'Watching the market every ${ap.intervalMinutes} min.'
                              '${ap.lastRun == null ? '' : ' Last run ${ap.lastRun!.toLocal().toString().substring(11, 16)}.'}')
                  : 'Off — the crew only runs when you ask.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (ap.enabled) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('Every', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(width: 8),
                  for (final m in const [5, 15, 30, 60]) ...[
                    ChoiceChip(
                      label: Text(m >= 60 ? '1h' : '$m m'),
                      selected: ap.intervalMinutes == m,
                      onSelected: (_) =>
                          ref.read(autopilotProvider.notifier).setInterval(m),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: ap.running
                        ? null
                        : () => ref.read(autopilotProvider.notifier).runOnce(),
                    child: const Text('Run now'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The autopilot proposal queue. Approve = the same execute path as any
/// other proposal (Risk Engine re-checked inside).
class _PendingQueue extends ConsumerStatefulWidget {
  const _PendingQueue();

  @override
  ConsumerState<_PendingQueue> createState() => _PendingQueueState();
}

class _PendingQueueState extends ConsumerState<_PendingQueue> {
  String? _busyId;

  Future<void> _approve(AgentProposal p) async {
    final mode = ref.read(tradingModeProvider);
    setState(() => _busyId = '${p.symbol}${p.side.name}');
    try {
      final exec = await ref.read(tradingServiceProvider).execute(p, mode);
      if (!mounted) return;
      if (exec.executed) {
        ref
            .read(journalProvider.notifier)
            .add(
              ExecutedTrade(
                symbol: p.symbol,
                side: p.side,
                quantity: p.quantity,
                filledPrice: exec.fillPrice ?? p.marketPrice,
                at: DateTime.now(),
              ),
            );
        ref.invalidate(accountProvider);
        ref.invalidate(historyProvider);
        ref.read(pendingProposalsProvider.notifier).remove(p);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${p.side.wire} ${p.quantity} ${p.symbol} '
              'filled at ₹${(exec.fillPrice ?? p.marketPrice).toStringAsFixed(2)}',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Not executed: ${exec.reason ?? 'rejected'}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Execution failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(pendingProposalsProvider).cast<AgentProposal>();
    if (queue.isEmpty) return const SizedBox.shrink();
    final live = ref.watch(tradingModeProvider) == AccountMode.live;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        SectionHeader(
          'Autopilot queue',
          trailing: '${queue.length} awaiting you',
        ),
        for (final p in queue)
          ProposalCard(
            proposal: TradeProposal(
              symbol: p.symbol,
              side: p.side,
              quantity: p.quantity,
              entryPrice: p.marketPrice,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              rationale: p.rationale,
              confidence: p.confidence,
              source: 'autopilot',
            ),
            verdict: p.verdict,
            liveMode: live,
            onApprove: p.verdict.allowed && _busyId == null
                ? () => _approve(p)
                : null,
            onReject: () =>
                ref.read(pendingProposalsProvider.notifier).remove(p),
          ),
      ],
    );
  }
}
