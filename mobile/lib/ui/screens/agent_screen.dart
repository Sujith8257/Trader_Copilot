import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/proposal_card.dart';

/// The agentic Copilot chat: the agent reasons over tools (market scan,
/// indicators, account, propose + risk check) and shows its full trace.
/// A proposal draft can be approved from right inside the conversation —
/// but only after the deterministic Risk Engine allows it.
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _ChatMessage {
  _ChatMessage.user(this.text)
      : isUser = true,
        reply = null;

  factory _ChatMessage.agent(AgentReply reply) =>
      _ChatMessage._(false, reply.reply, reply);

  _ChatMessage._(this.isUser, this.text, this.reply);

  final bool isUser;
  final String text;
  final AgentReply? reply;
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_ChatMessage>[
    _ChatMessage.agent(AgentReply(
      brain: 'local',
      reply: 'Hi! I\'m your agentic trading copilot. I reason over real tools '
          '— market scanner, technical indicators, your account, and the '
          'Risk Engine. Ask me to scan the market, analyze a symbol, or '
          'draft a checked proposal.',
      steps: [],
    )),
  ];
  bool _sending = false;

  static const _suggestions = [
    'Scan the market',
    'Analyze RELIANCE',
    'Buy TCS',
    'Show my portfolio',
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
      _messages.add(_ChatMessage.user(msg));
    });
    _scrollDown();
    try {
      final reply = await ref.read(apiClientProvider).agentChat(msg);
      setState(() => _messages.add(_ChatMessage.agent(reply)));
    } catch (e) {
      setState(() => _messages.add(_ChatMessage.agent(AgentReply(
            brain: 'local',
            reply: 'I couldn\'t reach my tools: $e\nIs the backend running? '
                '(cd backend && uvicorn app.main:app --reload)',
            steps: [],
          ))));
    } finally {
      setState(() => _sending = false);
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

  Future<void> _approveDraft(AgentReply reply) async {
    final p = reply.proposal!;
    try {
      final result = await ref.read(apiClientProvider).placePaperOrder(
            symbol: p.symbol,
            side: p.side,
            quantity: p.quantity,
            marketPrice: p.entryPrice ?? 0,
          );
      if (!mounted) return;
      ref.read(journalProvider.notifier).add(ExecutedTrade(
            symbol: p.symbol,
            side: p.side,
            quantity: p.quantity,
            filledPrice: result.filledPrice ?? 0,
            at: DateTime.now(),
          ));
      ref.invalidate(accountProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Paper order FILLED: ${p.side.wire} ${p.quantity} '
            '${p.symbol} @ ${formatINR(result.filledPrice ?? 0, decimals: 2)}'),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brainLabel = _messages.any((m) => m.reply?.brain == 'llm')
        ? 'LLM brain'
        : 'Local brain';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text('Agentic Copilot',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: TC.gain.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: TC.gain.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bolt, size: 12, color: TC.gain),
                    const SizedBox(width: 4),
                    Text(brainLabel,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: TC.gain)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            itemCount: _messages.length,
            itemBuilder: (context, i) => _messages[i].isUser
                ? _UserBubble(_messages[i].text)
                : _AgentBubble(message: _messages[i], onApprove: _approveDraft),
          ),
        ),
        _SuggestionBar(
            suggestions: _suggestions, enabled: !_sending, onTap: _send),
        _InputBar(
            controller: _controller,
            enabled: !_sending,
            sending: _sending,
            onSend: _send),
      ],
    );
  }
}
class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 10, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: TC.info.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

class _AgentBubble extends StatelessWidget {
  const _AgentBubble({required this.message, required this.onApprove});

  final _ChatMessage message;
  final void Function(AgentReply) onApprove;

  @override
  Widget build(BuildContext context) {
    final reply = message.reply!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 10, right: 24),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: TC.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TC.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in reply.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: TC.gain.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(s.tool,
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: TC.gain)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(s.detail,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            if (reply.steps.isNotEmpty) ...[
              const SizedBox(height: 4),
              const Divider(),
              const SizedBox(height: 8),
            ],
            Text(reply.reply, style: Theme.of(context).textTheme.bodyMedium),
            if (reply.hasDraft) ...[
              const SizedBox(height: 8),
              ProposalCard(
                proposal: reply.proposal!,
                verdict: reply.verdict!,
                onApprove: () => onApprove(reply),
                onReject: () {},
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
                decoration: const InputDecoration(hintText: 'Ask your copilot…'),
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
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_upward, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



