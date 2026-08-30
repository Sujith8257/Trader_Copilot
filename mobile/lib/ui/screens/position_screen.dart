import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chart_screen.dart';

/// Stop / target / potential-risk-vs-reward card.
class _RiskPlanCard extends StatelessWidget {
  const _RiskPlanCard({
    required this.stop,
    required this.target,
    required this.riskAmt,
    required this.rewardAmt,
    required this.rr,
  });

  final double? stop;
  final double? target;
  final double? riskAmt;
  final double? rewardAmt;
  final double? rr;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('Risk plan',
                trailing:
                    stop == null && target == null ? 'no stops recorded' : null),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Stop loss',
                    value: stop == null ? '—' : formatINR(stop!),
                    icon: Icons.shield_outlined,
                    valueColor: TC.loss,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Target',
                    value: target == null ? '—' : formatINR(target!),
                    icon: Icons.flag_outlined,
                    valueColor: TC.gain,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Potential risk',
                    value: riskAmt == null ? '—' : '-${formatINR(riskAmt!)}',
                    icon: Icons.trending_down,
                    valueColor: TC.loss,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Potential left',
                    value:
                        rewardAmt == null ? '—' : '+${formatINR(rewardAmt!)}',
                    icon: Icons.trending_up,
                    valueColor: TC.gain,
                  ),
                ),
              ],
            ),
            if (rr != null) ...[
              const SizedBox(height: 10),
              Text(
                'Risk / reward: 1 : ${rr!.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full detail for ONE open position: when it was opened, amount invested,
/// quantity, stop/target, potential risk vs reward left, live PnL — and a
/// force-exit button that sells the ENTIRE position at the live price.
class PositionScreen extends ConsumerStatefulWidget {
  const PositionScreen({super.key, required this.symbol});

  final String symbol;

  @override
  ConsumerState<PositionScreen> createState() => _PositionScreenState();
}

class _PositionScreenState extends ConsumerState<PositionScreen> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(tradingServiceProvider);
    final accountAsync = ref.watch(accountProvider);
    final pos = accountAsync.value?.positions[widget.symbol];

    if (pos == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.symbol)),
        body: const Center(
            child: Text('This position is closed or no longer exists.')),
      );
    }

    final meta = svc.paper.positionMeta[widget.symbol];
    final openedAt = meta == null
        ? null
        : DateTime.tryParse(meta['opened_at'] as String? ?? '');
    final stop = (meta?['stop_loss'] as num?)?.toDouble();
    final target = (meta?['take_profit'] as num?)?.toDouble();

    final invested = pos.quantity * pos.avgPrice;
    final value = pos.quantity * pos.lastPrice;
    final pnl = pos.unrealizedPnl;
    final riskAmt = stop == null ? null : (pos.avgPrice - stop) * pos.quantity;
    final rewardAmt =
        target == null ? null : (target - pos.avgPrice) * pos.quantity;
    final rr = (riskAmt != null && rewardAmt != null && riskAmt > 0)
        ? rewardAmt / riskAmt
        : null;

    final livePrice = FutureBuilder<double>(
      future: svc.ensureLoaded().then((_) => svc.market.last(widget.symbol)),
      builder: (context, snap) => Text(
        snap.hasData ? formatINR(snap.data!) : 'loading…',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text('${widget.symbol} position')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Live price',
                                style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 4),
                            livePrice,
                          ],
                        ),
                      ),
                      PnlChip(pnl, suffix: ' unrealized'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: StatTile(
                          label: 'Quantity',
                          value: pos.quantity.toStringAsFixed(8),
                          icon: Icons.scale_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: StatTile(
                          label: 'Avg entry',
                          value: formatINR(pos.avgPrice),
                          icon: Icons.login,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: StatTile(
                          label: 'Amount invested',
                          value: formatINR(invested),
                          icon: Icons.payments_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: StatTile(
                          label: 'Current value',
                          value: formatINR(value),
                          icon: Icons.account_balance_wallet_outlined,
                          valueColor: pnl >= 0 ? TC.gain : TC.loss,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _RiskPlanCard(
            stop: stop,
            target: target,
            riskAmt: riskAmt,
            rewardAmt: rewardAmt,
            rr: rr,
          ),
          const SizedBox(height: 16),
          if (openedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Opened ${openedAt.toLocal().toString().substring(0, 16)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.candlestick_chart, size: 18),
            label: Text('View ${widget.symbol} live chart'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => ChartScreen(symbol: widget.symbol)),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: TC.loss),
            icon: _closing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.logout, size: 18),
            label: Text(_closing
                ? 'Selling…'
                : 'Sell trade (force exit all ${widget.symbol})'),
            onPressed: _closing ? null : _forceExit,
          ),
          const SizedBox(height: 8),
          Text(
            'Force exit sells the ENTIRE position at the live market price. '
            'The Risk Engine verifies the order before it executes.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _forceExit() async {
    final mode = ref.read(tradingModeProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.logout, color: TC.loss, size: 30),
        title: Text('Sell all ${widget.symbol}?'),
        content: Text(
          'This places a MARKET SELL for your ENTIRE ${widget.symbol} '
          'position at the live price. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep position'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TC.loss),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sell everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    setState(() => _closing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final svc = ref.read(tradingServiceProvider);
      // Capture the REAL position size BEFORE the close. Journaling 0 here
      // (the old bug) wrote a phantom fill that poisoned the analytics.
      final soldQty = mode == AccountMode.live
          ? (ref.read(accountProvider).value?.positions[widget.symbol]?.quantity ??
              0)
          : (svc.paper.account.positions[widget.symbol]?.quantity ?? 0);
      final exec = await svc.closePosition(widget.symbol, mode);
      if (!exec.executed) {
        messenger.showSnackBar(SnackBar(
            content: Text('Not executed: ${exec.reason ?? 'rejected'}')));
        return;
      }
      HapticFeedback.mediumImpact();
      final fill = exec.fillPrice ?? 0;
      ref.read(journalProvider.notifier).add(ExecutedTrade(
            symbol: widget.symbol,
            side: Side.sell,
            quantity: soldQty,
            filledPrice: fill,
            fee: exec.fee,
            at: DateTime.now(),
            mode: mode.name,
            source: 'exit',
          ));
      ref.invalidate(accountProvider);
      ref.invalidate(historyProvider);
      messenger.showSnackBar(SnackBar(
        content: Text(
            'Closed ${widget.symbol} at ${formatINR(fill)} — position fully sold.'),
      ));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Exit failed: $e')));
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }
}
