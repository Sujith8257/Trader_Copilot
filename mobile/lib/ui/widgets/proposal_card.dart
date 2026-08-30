import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/engine/risk_engine.dart';
import '../theme.dart';

/// The approval gate in UI form: AI proposal + deterministic verdict,
/// with Approve/Reject actions. Execution is never automatic.
class ProposalCard extends StatelessWidget {
  const ProposalCard({
    super.key,
    required this.proposal,
    required this.verdict,
    required this.onApprove,
    required this.onReject,
    this.liveMode = false,
  });

  final TradeProposal proposal;
  final RiskVerdict verdict;
  final VoidCallback? onApprove;
  final VoidCallback onReject;

  /// True when approval will place a REAL Coinbase order.
  final bool liveMode;

  @override
  Widget build(BuildContext context) {
    final rr = proposal.riskReward;

    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Verdict banner -------------------------------------------------
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: (verdict.allowed ? TC.gain : TC.loss).withValues(
                  alpha: 0.12,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    verdict.allowed ? Icons.verified_outlined : Icons.block,
                    color: verdict.allowed ? TC.gain : TC.loss,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          verdict.allowed
                              ? (liveMode
                                    ? 'Risk Engine: Allowed — LIVE order'
                                    : 'Risk Engine: Allowed')
                              : 'Risk Engine: Blocked',
                          style: TextStyle(
                            color: verdict.allowed
                                ? (liveMode ? TC.warn : TC.gain)
                                : TC.loss,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          'Deterministic code — not an AI opinion.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Proposal headline ----------------------------------------------
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: (proposal.side == Side.buy ? TC.gain : TC.loss)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    proposal.side.wire,
                    style: TextStyle(
                      color: proposal.side == Side.buy ? TC.gain : TC.loss,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Flex + ellipsis: long qty/symbol pairs used to overflow
                // the narrower agent-chat card width.
                Expanded(
                  child: Text(
                    '${_qty(proposal.quantity)} ${proposal.symbol}',
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Key numbers ----------------------------------------------------
            Row(
              children: [
                if (proposal.entryPrice != null)
                  Expanded(
                    child: _NumBox(
                      label: 'Entry',
                      value: formatINR(proposal.entryPrice!, decimals: 2),
                      icon: Icons.login,
                      color: TC.info,
                    ),
                  ),
                if (proposal.stopLoss != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _NumBox(
                      label: 'Stop loss',
                      value: formatINR(proposal.stopLoss!, decimals: 2),
                      icon: Icons.arrow_downward,
                      color: TC.loss,
                    ),
                  ),
                ],
                if (proposal.takeProfit != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _NumBox(
                      label: 'Target',
                      value: formatINR(proposal.takeProfit!, decimals: 2),
                      icon: Icons.flag_outlined,
                      color: TC.gain,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (rr != null)
                  Expanded(
                    child: _NumBox(
                      label: 'Risk / Reward',
                      value: '1 : ${rr.toStringAsFixed(1)}',
                      icon: Icons.balance,
                      color: TC.warn,
                    ),
                  ),
                if (proposal.confidence != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _NumBox(
                      label: 'AI confidence',
                      value:
                          '${(proposal.confidence! * 100).toStringAsFixed(0)}%',
                      icon: Icons.psychology_alt_outlined,
                      color: TC.info,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),

            // Violations — hard blocks from the deterministic engine.
            for (final v in verdict.violations)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TC.loss.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.close, color: TC.loss, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          v,
                          style: const TextStyle(fontSize: 13, color: TC.loss),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Warnings — pass with notes.
            for (final w in verdict.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TC.warn.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: TC.warn,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          w,
                          style: const TextStyle(fontSize: 13, color: TC.warn),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (proposal.rationale.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Why the AI proposes this',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                proposal.rationale,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 14),
            ],

            // Actions ----------------------------------------------------------
            // Wrap (not Row): inside the agent-chat bubble the two buttons
            // exceed 260px and used to overflow ~19-38px. They now flow to a
            // second line on narrow widths instead.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: onReject,
                  child: const Text('Reject'),
                ),
                FilledButton.icon(
                  onPressed: verdict.allowed ? onApprove : null,
                  icon: const Icon(Icons.how_to_reg_outlined, size: 18),
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

class _NumBox extends StatelessWidget {
  const _NumBox({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TC.surfaceHi,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
