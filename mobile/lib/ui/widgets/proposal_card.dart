import 'package:flutter/material.dart';

import '../../core/models.dart';

/// The approval gate in UI form: AI proposal + deterministic verdict,
/// with Approve/Reject actions. Execution is never automatic.
class ProposalCard extends StatelessWidget {
  const ProposalCard({
    super.key,
    required this.proposal,
    required this.verdict,
    required this.onApprove,
    required this.onReject,
  });

  final TradeProposal proposal;
  final RiskVerdict verdict;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rr = proposal.riskReward;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  verdict.allowed
                      ? Icons.check_circle_outline
                      : Icons.block,
                  color: verdict.allowed ? Colors.green : scheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  '${proposal.side.wire} ${_qty(proposal.quantity)} ${proposal.symbol}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(height: 24),
            if (proposal.entryPrice != null)
              _Row('Entry', proposal.entryPrice!.toStringAsFixed(2)),
            if (proposal.stopLoss != null)
              _Row('Stop loss', proposal.stopLoss!.toStringAsFixed(2)),
            if (proposal.takeProfit != null)
              _Row('Target', proposal.takeProfit!.toStringAsFixed(2)),
            if (rr != null) _Row('Risk/Reward', '1 : ${rr.toStringAsFixed(1)}'),
            if (proposal.confidence != null)
              _Row('AI confidence',
                  '${(proposal.confidence! * 100).toStringAsFixed(0)}%'),
            const SizedBox(height: 12),

            // Violations — hard blocks from the deterministic engine.
            for (final v in verdict.violations)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  const Icon(Icons.close, color: Colors.red, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(v)),
                ]),
              ),

            // Warnings — pass with notes.
            for (final w in verdict.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(w)),
                ]),
              ),

            const Divider(height: 24),
            if (proposal.rationale.isNotEmpty) ...[
              Text(proposal.rationale,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: onReject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: verdict.allowed ? onApprove : null,
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Approve & Execute'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
