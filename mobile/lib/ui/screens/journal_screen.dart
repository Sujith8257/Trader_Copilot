import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/analytics.dart';
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
    // Mode-scoped journal: PAPER shows paper fills, LIVE shows real
    // Coinbase fills — never mixed.
    final mode = ref.watch(tradingModeProvider);
    final trades = ref
        .watch(journalProvider)
        .where((t) => t.mode == mode.name)
        .toList();

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
    final pnlByTrade = realizedPnlByTrade(trades);

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
                      label: '$buys buys',
                      color: TC.gain,
                      up: true,
                    ),
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
        const _AnalyticsCard(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.table_view, size: 18),
                label: const Text('Export CSV'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: tradesCsv(trades)));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Journal CSV copied to clipboard.'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SectionHeader(
          'History',
          trailing: '${mode.name.toUpperCase()} account',
        ),
        for (var i = trades.length - 1; i >= 0; i--)
          _TradeTile(trades[i], realizedPnl: pnlByTrade[i]),
      ],
    );
  }
}

class _SideCountChip extends StatelessWidget {
  const _SideCountChip({
    required this.label,
    required this.color,
    required this.up,
  });

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
          Icon(
            up ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _fmtTime(DateTime d) =>
    '${d.day} ${_months[d.month - 1]} · '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _TradeTile extends StatelessWidget {
  const _TradeTile(this.t, {required this.realizedPnl});

  final ExecutedTrade t;

  /// Realized PnL of THIS fill (avg entry vs this sell), or null when it
  /// cannot be honestly computed (buys, sells without a tracked lot).
  final double? realizedPnl;

  String get _sourceLabel => switch (t.source) {
        'agent-idea' => 'Agent idea',
        'agent' => 'Agent crew',
        'autopilot' => 'Autopilot',
        'exit' => 'Manual exit',
        _ => 'Manual',
      };

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
                      '${isBuy ? 'BOUGHT' : 'SOLD'} ${formatQty(t.quantity)} '
                      '${t.symbol}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Filled @ ${formatINR(t.filledPrice, decimals: 2)} · '
                      'Notional ${formatINR(t.notional)}'
                      '${t.fee > 0 ? " · Fee ${formatINR(t.fee, decimals: 2)}" : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _TagChip(
                          label: t.mode.toUpperCase(),
                          color: t.mode == 'live' ? TC.warn : TC.info,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: _TagChip(
                            label: _sourceLabel,
                            color: TC.onBgDim,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _fmtTime(t.at),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (!isBuy && realizedPnl != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      formatSignedINR(realizedPnl!, decimals: 2),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: realizedPnl! >= 0 ? TC.gain : TC.loss,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny label chip for journal metadata (mode / source).
class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Performance analytics computed from the REAL equity curve and journal.
class _AnalyticsCard extends ConsumerWidget {
  const _AnalyticsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trades = ref.watch(journalProvider);
    final equity = ref.watch(historyProvider).value ?? const <EquityPoint>[];
    final s = computeStats(trades: trades, equity: equity);

    String pf(double v) => v >= 99 ? '∞' : v.toStringAsFixed(v >= 10 ? 1 : 2);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('Performance', trailing: 'live-marked equity'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Win rate',
                    value: s.hasTrades
                        ? '${s.winRatePct.toStringAsFixed(0)}%'
                        : '–',
                    icon: Icons.emoji_events_outlined,
                    valueColor: s.winRatePct >= 50 ? TC.gain : TC.warn,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Profit factor',
                    value: s.hasTrades ? pf(s.profitFactor) : '–',
                    icon: Icons.balance,
                    valueColor: s.profitFactor >= 1 ? TC.gain : TC.loss,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Max drawdown',
                    value: s.maxDrawdownPct > 0
                        ? '-${s.maxDrawdownPct.toStringAsFixed(1)}%'
                        : '–',
                    icon: Icons.trending_down,
                    valueColor: TC.loss,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Net realized PnL',
                    value: formatSignedINR(s.netRealizedPnl),
                    icon: Icons.savings_outlined,
                    valueColor: s.netRealizedPnl >= 0 ? TC.gain : TC.loss,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Best trade',
                    value: s.hasTrades ? formatSignedINR(s.bestTrade) : '–',
                    icon: Icons.north_east,
                    valueColor: TC.gain,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Worst trade',
                    value: s.hasTrades ? formatSignedINR(s.worstTrade) : '–',
                    icon: Icons.south_east,
                    valueColor: TC.loss,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Win rate & PnL come from your closed lots (avg entry vs sell '
              'fill); drawdown from the equity curve marked to live prices.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
