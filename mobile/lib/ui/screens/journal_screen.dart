import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Trading journal: every approved (or rejected) proposal is recorded with
/// what was executed. SQLite persistence and post-trade AI analysis arrive
/// in a later phase.
class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trades = ref.watch(journalProvider);

    if (trades.isEmpty) {
      return EmptyState(
        icon: Icons.menu_book_outlined,
        title: 'No trades yet',
        message:
            'Approved paper trades land here — proposal, approval, fill, and '
            'later post-trade analysis. Try the Copilot to place your first.',
        ctaLabel: 'Open Copilot',
        onCta: () => ref.read(tabIndexProvider.notifier).set(2),
      );
    }

    final buys = trades.where((t) => t.side == Side.buy).length;
    final notional = trades.fold<double>(0, (s, t) => s + t.notional);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader('Session journal'),
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        label: 'Executed trades',
                        value: '${trades.length}',
                        icon: Icons.receipt_long_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'Total notional',
                        value: formatINR(notional),
                        icon: Icons.payments_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _SideCountChip(
                        label: '$buys buys', color: TC.gain, up: true),
                    const SizedBox(width: 8),
                    _SideCountChip(
                      label: '${trades.length - buys} sells',
                      color: TC.loss,
                      up: false,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SectionHeader('History'),
        ...trades.reversed.map(_TradeTile.new),
      ],
    );
  }
}

class _SideCountChip extends StatelessWidget {
  const _SideCountChip(
      {required this.label, required this.color, required this.up});

  final String label;
  final Color color;
  final bool up;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
              size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _fmtTime(DateTime d) =>
    '${d.day} ${_months[d.month - 1]} · '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _TradeTile extends StatelessWidget {
  const _TradeTile(this.t);

  final ExecutedTrade t;

  @override
  Widget build(BuildContext context) {
    final isBuy = t.side == Side.buy;
    final color = isBuy ? TC.gain : TC.loss;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  isBuy ? Icons.arrow_downward : Icons.arrow_upward,
                  color: color,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${isBuy ? 'BOUGHT' : 'SOLD'} ${t.quantity} ${t.symbol}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Filled @ ${formatINR(t.filledPrice, decimals: 2)} · '
                      'Notional ${formatINR(t.notional)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Text(_fmtTime(t.at),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
