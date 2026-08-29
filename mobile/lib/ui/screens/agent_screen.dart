import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_engine.dart';
import '../../core/engine/risk_engine.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/amount_dialog.dart';
import '../widgets/proposal_card.dart';

/// The agentic Copilot chat: the on-phone crew (Scanner → Analyst →
/// Strategist → Drafter) reasons over LIVE Coinbase tools and shows its
/// full trace. A proposal draft can be approved from right inside the
/// conversation — but only after the deterministic Risk Engine allows it.
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _Entry {
  _Entry.user(this.text) : isUser = true, result = null;

  _Entry.result(this.result) : isUser = false, text = '';

  final bool isUser;
  final String text;
  final AgentRunResult? result;
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <_Entry>[_Entry.result(_greeting())];
  bool _sending = false;

  static AgentRunResult _greeting() {
    final r = AgentRunResult(goal: 'hello');
    r.brain = 'rule';
    r.reply =
        "Hi! I'm your agentic trading crew running fully on this phone "
        'over LIVE Coinbase data. I scan the market, read the news, check '
        'indicators and your account, and draft Risk-Engine-checked '
        'proposals. Try "Scan the market" or set a goal like "grow the '
        'paper account with moderate risk".';
    return r;
  }

  static const _suggestions = [
    'Scan the market',
    'Find profit opportunities',
    'Analyze BTC',
    'Review my positions',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final msg = text.trim();
    if (msg.isEmpty || _sending) return;
    _controller.clear();
    setState(() {
      _sending = true;
      _entries.add(_Entry.user(msg));
      _entries.add(_Entry.result(AgentRunResult(goal: msg)));
    });
    _scrollDown();
    try {
      final result = await ref
          .read(tradingServiceProvider)
          .runCrew(
            msg,
            onStep: (_) {
              if (mounted) setState(() {}); // live tool trace
            },
          );
      if (mounted) setState(() => _entries.last = _Entry.result(result));
    } catch (e) {
      if (mounted) {
        final err = AgentRunResult(goal: msg)
          ..reply = 'The crew hit an error: $e'
          ..step('system', 'error', e.toString());
        setState(() => _entries.last = _Entry.result(err));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollDown();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _approveDraft(AgentRunResult result, AgentProposal p) async {
    final mode = ref.read(tradingModeProvider);
    // Ask HOW MUCH before executing — qty is derived from the live price.
    final amount = await showAmountDialog(
      context,
      symbol: p.symbol,
      side: p.side,
      marketPrice: p.marketPrice,
      suggestedAmount: p.quantity * p.marketPrice,
    );
    if (amount == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final svc = ref.read(tradingServiceProvider);
    final exec = await svc.executeWithAmount(p, amount, mode);
    // Persist the decision (approved or blocked) for the copilot history.
    svc.history.addDecision(
      symbol: p.symbol,
      side: p.side.wire,
      quantity: exec.executed ? amount / (exec.fillPrice ?? p.marketPrice) : p.quantity,
      price: exec.fillPrice ?? p.marketPrice,
      mode: mode.name,
      approved: exec.executed,
      reason: exec.reason,
      source: 'agent',
    );
    ref.invalidate(decisionsProvider);
    if (!exec.executed) {
      messenger.showSnackBar(
        SnackBar(content: Text('Not executed: ${exec.reason ?? 'rejected'}')),
      );
      return;
    }
    if (!mounted) return;
    ref
        .read(journalProvider.notifier)
        .add(
          ExecutedTrade(
            symbol: p.symbol,
            side: p.side,
            quantity: amount / (exec.fillPrice ?? p.marketPrice),
            filledPrice: exec.fillPrice ?? p.marketPrice,
            at: DateTime.now(),
          ),
        );
    ref.invalidate(accountProvider);
    ref.invalidate(historyProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${p.side.wire} ${p.quantity} ${p.symbol} filled on '
          '${mode == AccountMode.live ? "LIVE Coinbase" : "paper"} at '
          '₹${(exec.fillPrice ?? p.marketPrice).toStringAsFixed(2)}',
        ),
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextButton.icon(
                icon: const Icon(Icons.history, size: 18),
                label: const Text('Agent history'),
                onPressed: () => showAgentHistory(context, ref),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final e = _entries[i];
                return e.isUser
                    ? _UserBubble(text: e.text)
                    : _AgentCard(
                        result: e.result!,
                        onApprove: (p) => _approveDraft(e.result!, p),
                      );
              },
            ),
          ),
          _SuggestionBar(
            suggestions: _suggestions,
            enabled: !_sending,
            onTap: _send,
          ),
          _InputBar(
            controller: _controller,
            enabled: !_sending,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: TC.info.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16)
              .copyWith(bottomRight: const Radius.circular(4)),
          border: Border.all(color: TC.info.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

/// Crew badge icons/colors per role.
const Map<String, (IconData, Color)> _agentBadge = {
  'scanner': (Icons.radar, TC.info),
  'analyst': (Icons.query_stats, TC.gain),
  'strategist': (Icons.psychology, TC.warn),
  'drafter': (Icons.gavel, TC.loss),
  'system': (Icons.settings, TC.onBgDim),
};

class _AgentCard extends ConsumerWidget {
  const _AgentCard({required this.result, required this.onApprove});

  final AgentRunResult result;
  final void Function(AgentProposal) onApprove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(tradingModeProvider);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.88,
        ),
        decoration: BoxDecoration(
          color: TC.surface,
          borderRadius: BorderRadius.circular(16)
              .copyWith(bottomLeft: const Radius.circular(4)),
          border: Border.all(color: TC.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smart_toy, size: 15, color: TC.gain),
                const SizedBox(width: 6),
                Text(
                  'crew · ${result.brain}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: TC.onBgDim,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final s in result.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Builder(
                        builder: (context) {
                          final badge =
                              _agentBadge[s.agent] ??
                              (Icons.circle, TC.onBgDim);
                          return Icon(badge.$1, size: 13, color: badge.$2);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.tool,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: TC.onBgDim,
                            ),
                          ),
                          Text(
                            s.detail,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (result.steps.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 6),
            ],
            Text(result.reply, style: Theme.of(context).textTheme.bodyMedium),
            for (final p in result.proposals) ...[
              const SizedBox(height: 8),
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
                  source: 'ai',
                ),
                verdict: RiskVerdict(
                  allowed: p.verdict.allowed,
                  violations: p.verdict.violations,
                  warnings: p.verdict.warnings,
                ),
                onApprove: p.allowed ? () => onApprove(p) : null,
                onReject: () {},
                liveMode: mode == AccountMode.live,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionBar extends StatelessWidget {
  const _SuggestionBar({
    required this.suggestions,
    required this.enabled,
    required this.onTap,
  });

  final List<String> suggestions;
  final bool enabled;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final s in suggestions)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 12)),
                backgroundColor: TC.surfaceHi,
                side: const BorderSide(color: TC.outline),
                onPressed: enabled ? () => onTap(s) : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool sending;
  final void Function(String) onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: onSend,
                decoration: const InputDecoration(
                  hintText: 'Give the crew a goal…',
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 48,
              height: 48,
              child: FilledButton(
                onPressed: enabled ? () => onSend(controller.text) : null,
                style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                child: sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Agent history: every persisted crew session (goal, trace, reply,
/// proposals) — loaded from storage, newest first.
void showAgentHistory(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _AgentHistorySheet(),
  );
}

class _AgentHistorySheet extends ConsumerWidget {
  const _AgentHistorySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(agentSessionsProvider);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Agent history',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Persisted crew sessions, newest first.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Flexible(
              child: sessions.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('$e'),
                data: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No sessions yet. Run the crew first.',
                            textAlign: TextAlign.center),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: list.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final s = list[list.length - 1 - i];
                          final at = DateTime.tryParse(
                                  s['at'] as String? ?? '') ??
                              DateTime.now();
                          final proposals =
                              (s['proposals'] as List? ?? [])
                                  .cast<Map>();
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: TC.surface,
                              borderRadius:
                                  BorderRadius.circular(14),
                              border: Border.all(color: TC.outline),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.smart_toy,
                                        size: 14, color: TC.gain),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        s['goal'] as String? ?? '',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                        overflow:
                                            TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      at.toLocal().toString().substring(
                                          0, 16),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'brain: ${s['brain']} · '
                                  '${(s['steps'] as List? ?? []).length} steps · '
                                  '${proposals.length} proposal(s)',
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                                if ((s['reply'] as String? ?? '')
                                    .isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(s['reply'] as String,
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ],
                                for (final p in proposals)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '→ ${p['side']} ${p['quantity']} ${p['symbol']} @ ₹${p['price']} · ${p['allowed'] == true ? 'ALLOWED' : 'BLOCKED'}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: p['allowed'] == true
                                            ? TC.gain
                                            : TC.loss,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}