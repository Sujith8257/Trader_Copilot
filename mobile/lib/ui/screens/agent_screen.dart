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
/// full trace. The conversation lives in `agentChatProvider` (app scope),
/// so it survives tab switches and navigation — it only clears when the
/// app process itself is killed (swipe from recents). Past conversations
/// can be reopened from the agent history and CONTINUED; the crew can also
/// proactively suggest 5-6 cryptos to trade with one tap.
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  static const _suggestions = [
    'Scan the market',
    'Suggest a good position',
    'I want to invest 5000',
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
    if (msg.isEmpty) return;
    final chat = ref.read(agentChatProvider.notifier);
    final chatId = ref.read(agentChatProvider).chatId;
    _controller.clear();
    chat.addUser(msg);
    chat.pushOrReplaceResult(AgentRunResult(goal: msg)); // placeholder card
    chat.setSending(true);
    _scrollDown();
    try {
      final result = await ref
          .read(tradingServiceProvider)
          .runCrew(msg, chatId: chatId);
      chat.pushOrReplaceResult(result);
    } catch (e) {
      final err = AgentRunResult(goal: msg)
        ..reply = 'The crew hit an error: $e'
        ..step('system', 'error', e.toString());
      chat.pushOrReplaceResult(err);
    } finally {
      chat.setSending(false);
      _scrollDown();
    }
  }

  /// Trade button on a proactive suggestion: draft the proposal with the
  /// deterministic sizer, ask the amount, then the Risk Engine gates it.
  Future<void> _tradeSuggestion(AgentSuggestion s, double? amount) async {
    final svc = ref.read(tradingServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    final p = await svc.draftProposal(s.symbol);
    if (!mounted) return;
    if (p == null) {
      messenger.showSnackBar(SnackBar(
          content: Text('Could not fetch the live price for ${s.symbol}.')));
      return;
    }
    final chosen = await showAmountDialog(
      context,
      symbol: s.symbol,
      side: Side.buy,
      marketPrice: p.marketPrice,
      suggestedAmount: amount ?? p.quantity * p.marketPrice,
    );
    if (chosen == null || !mounted) return;
    final mode = ref.read(tradingModeProvider);
    final exec = await svc.executeWithAmount(p, chosen, mode);
    svc.history.addDecision(
      symbol: s.symbol,
      side: Side.buy.wire,
      quantity: exec.executed
          ? chosen / (exec.fillPrice ?? p.marketPrice)
          : p.quantity,
      price: exec.fillPrice ?? p.marketPrice,
      mode: mode.name,
      approved: exec.executed,
      reason: exec.reason,
      source: 'agent-idea',
    );
    ref.invalidate(decisionsProvider);
    if (!exec.executed) {
      messenger.showSnackBar(SnackBar(
          content: Text('Not executed: ${exec.reason ?? 'rejected'}')));
      return;
    }
    if (!mounted) return;
    ref.read(journalProvider.notifier).add(ExecutedTrade(
          symbol: s.symbol,
          side: Side.buy,
          mode: mode.name,
          source: 'agent-idea',
          quantity: chosen / (exec.fillPrice ?? p.marketPrice),
          filledPrice: exec.fillPrice ?? p.marketPrice,
          at: DateTime.now(),
        ));
    ref.invalidate(accountProvider);
    ref.invalidate(historyProvider);
    messenger.showSnackBar(SnackBar(
      content: Text(
          'buy ${chosen / (exec.fillPrice ?? p.marketPrice)} ${s.symbol} '
          'filled at ₹${(exec.fillPrice ?? p.marketPrice).toStringAsFixed(2)}'),
    ));
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
    svc.history.addDecision(
      symbol: p.symbol,
      side: p.side.wire,
      quantity: exec.executed
          ? amount / (exec.fillPrice ?? p.marketPrice)
          : p.quantity,
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
    ref.read(journalProvider.notifier).add(
          ExecutedTrade(
            symbol: p.symbol,
            side: p.side,
            mode: mode.name,
            source: 'agent',
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
    ref.listen(agentChatProvider, (_, _) => _scrollDown());
    final chat = ref.watch(agentChatProvider);
    final mode = ref.watch(tradingModeProvider);
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Agent history'),
                  onPressed: () => showAgentHistory(context, ref),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add_comment_outlined, size: 18),
                  label: const Text('New chat'),
                  onPressed: chat.sending
                      ? null
                      : () => ref.read(agentChatProvider.notifier).newChat(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: chat.entries.length,
              itemBuilder: (context, i) {
                final e = chat.entries[i];
                if (e.isUser) return _UserBubble(text: e.text);
                if (e.restored != null) {
                  return _AgentCard(
                    result: _resultFromSession(e.restored!),
                    onApprove: (_) {},
                    onTrade: null,
                    suggestedAmount: null,
                  );
                }
                return _AgentCard(
                  result: e.result!,
                  onApprove: (p) => _approveDraft(e.result!, p),
                  onTrade: (s) =>
                      _tradeSuggestion(s, e.result!.suggestedAmount),
                  suggestedAmount: e.result!.suggestedAmount,
                  working: chat.sending && i == chat.entries.length - 1,
                  liveMode: mode == AccountMode.live,
                );
              },
            ),
          ),
          _InputBar(
            controller: _controller,
            enabled: !chat.sending,
            onSend: _send,
            chips: _suggestions,
          ),
        ],
      ),
    );
  }

  /// Rebuilds a read-only view of a persisted session (no live proposals —
  /// historical ones must never be re-executed at stale prices).
  static AgentRunResult _resultFromSession(Map<String, dynamic> s) {
    final r = AgentRunResult(goal: s['goal'] as String? ?? '');
    r.brain = s['brain'] as String? ?? 'rule';
    r.reply = s['reply'] as String? ?? '';
    for (final st in (s['steps'] as List? ?? [])) {
      final parts = (st as List).cast<String>();
      if (parts.length >= 3) r.step(parts[0], parts[1], parts[2]);
    }
    final props = (s['proposals'] as List? ?? []);
    if (props.isNotEmpty) {
      r.reply = '${r.reply}\n\n${props.length} proposal(s) were drafted in '
          'this turn — open a fresh goal to act on current prices.';
    }
    return r;
  }
}


class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
    required this.chips,
  });

  final TextEditingController controller;
  final bool enabled;
  final void Function(String) onSend;
  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: onSend,
                    decoration: InputDecoration(
                      hintText: 'Ask the crew, or say "invest 5000"…',
                      filled: true,
                      fillColor: TC.surface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: const BorderSide(color: TC.outline),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 22,
                  backgroundColor: TC.gain,
                  child: IconButton(
                    icon: const Icon(Icons.send,
                        size: 18, color: Colors.black),
                    onPressed:
                        enabled ? () => onSend(controller.text) : null,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final s in chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(s, style: const TextStyle(fontSize: 12)),
                      onPressed: enabled ? () => onSend(s) : null,
                    ),
                  ),
              ],
            ),
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
        margin: const EdgeInsets.only(bottom: 10, left: 60),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: TC.gain.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: TC.gain.withValues(alpha: 0.3)),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

const Map<String, (IconData, Color)> agentBadge = {
  'scanner': (Icons.radar, TC.gain),
  'analyst': (Icons.query_stats, TC.gain),
  'strategist': (Icons.psychology, TC.gain),
  'drafter': (Icons.gavel, TC.gain),
  'system': (Icons.settings, TC.onBgDim),
};

class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.result,
    required this.onApprove,
    required this.onTrade,
    required this.suggestedAmount,
    this.working = false,
    this.liveMode = false,
  });

  final AgentRunResult result;
  final void Function(AgentProposal) onApprove;
  final void Function(AgentSuggestion)? onTrade;
  final double? suggestedAmount;
  final bool working;
  final bool liveMode;

  @override
  Widget build(BuildContext context) {
    final busy = working || (result.reply.isEmpty && result.steps.isEmpty);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, right: 40),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: TC.surface,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
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
                if (busy) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            for (final s in result.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: Icon(Icons.circle,
                          size: 8, color: TC.gain),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${s.agent} · ${s.tool}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: TC.onBgDim,
                            ),
                          ),
                          Text(
                            s.detail,
                            style:
                                Theme.of(context).textTheme.bodySmall,
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
            Text(result.reply,
                style: Theme.of(context).textTheme.bodyMedium),
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
                liveMode: liveMode,
              ),
            ],
            if (result.suggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 132,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: result.suggestions.length,
                  itemBuilder: (context, i) {
                    final s = result.suggestions[i];
                    return _SuggestionCard(
                      suggestion: s,
                      onTrade:
                          onTrade == null ? null : () => onTrade!(s),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion, required this.onTrade});

  final AgentSuggestion suggestion;
  final VoidCallback? onTrade;

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    return Container(
      width: 168,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TC.surfaceHi,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TC.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.symbol,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                s.trend == 'UP' ? Icons.trending_up : Icons.trending_flat,
                size: 16,
                color: s.trend == 'UP' ? TC.gain : TC.onBgDim,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '₹${s.price.toStringAsFixed(2)}'
            ' · ${s.changePct >= 0 ? '+' : ''}${s.changePct.toStringAsFixed(1)}%',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            'RSI ${s.rsi?.toStringAsFixed(0) ?? '-'} · '
            'score ${s.score.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 30,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: TC.gain,
                padding: EdgeInsets.zero,
              ),
              onPressed: onTrade,
              child: const Text('TRADE',
                  style:
                      TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Agent history: persisted conversations grouped by chat id, newest first.
/// Tapping one opens that conversation in the chat view (display-only
/// turns) and CONTINUES it — new messages append to the same chat id.
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
            Text('Tap a conversation to open and continue it.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Flexible(
              child: sessions.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('$e'),
                data: (list) {
                  final chats = <String, List<Map<String, dynamic>>>{};
                  for (var i = 0; i < list.length; i++) {
                    final s = list[i];
                    final id = (s['chat_id'] as String?) ?? 'legacy-$i';
                    chats.putIfAbsent(id, () => []).add(s);
                  }
                  final ids = chats.keys.toList().reversed.toList();
                  if (ids.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No conversations yet.',
                          textAlign: TextAlign.center),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: ids.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final id = ids[i];
                      final turns = chats[id]!;
                      final last = turns.last;
                      final at = DateTime.tryParse(
                              last['at'] as String? ?? '') ??
                          DateTime.now();
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          ref
                              .read(agentChatProvider.notifier)
                              .openChat(turns, id);
                          Navigator.of(context).pop();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: TC.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: TC.outline),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.chat_bubble_outline,
                                  size: 16, color: TC.gain),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      turns.first['goal'] as String? ?? '',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${turns.length} turn(s) · '
                                      '${at.toLocal().toString().substring(0, 16)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right,
                                  size: 18, color: TC.onBgDim),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
