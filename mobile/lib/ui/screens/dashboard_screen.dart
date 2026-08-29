import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/providers.dart';

/// Portfolio screen: account cash/equity + open positions from the
/// paper broker. Everything here is deterministic backend state.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountProvider);
    final mode = ref.watch(tradingModeProvider);

    return accountAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorView(error: e.toString()),
      data: (account) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(accountProvider),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _AccountCard(account: account, mode: mode),
            const SizedBox(height: 16),
            Text('Positions',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (account.positions.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'No open positions. Go to Copilot and evaluate a trade idea.'),
                ),
              )
            else
              ...account.positions.values.map((p) => _PositionTile(p)),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.mode});

  final AccountState account;
  final AccountMode mode;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(mode == AccountMode.paper
                    ? Icons.science_outlined
                    : Icons.warning_amber_rounded),
                const SizedBox(width: 8),
                Text(
                  mode == AccountMode.paper
                      ? 'PAPER ACCOUNT'
                      : 'LIVE ACCOUNT (not connected)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(height: 24),
            _Row('Equity', _money(account.equity)),
            _Row('Cash', _money(account.cash)),
            _Row(
                'Exposure',
                account.positions.values
                    .fold(0.0, (s, p) => s + p.marketValue)
                    .toStringAsFixed(2)),
          ],
        ),
      ),
    );
  }
}

class _PositionTile extends StatelessWidget {
  const _PositionTile(this.p);

  final Position p;

  @override
  Widget build(BuildContext context) {
    final pnl = p.unrealizedPnl;
    final color = pnl >= 0 ? Colors.green : Colors.red;
    return Card(
      child: ListTile(
        title: Text(p.symbol),
        subtitle: Text(
            '${p.quantity} @ ${p.avgPrice.toStringAsFixed(2)} → ${p.lastPrice.toStringAsFixed(2)}'),
        trailing: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(p.marketValue.toStringAsFixed(2)),
            Text('${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}',
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('Cannot reach the backend.'),
            const SizedBox(height: 8),
            Text(
              'Start it with:  cd backend && uvicorn app.main:app --reload',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(error, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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

String _money(double v) => '₹${v.toStringAsFixed(2)}';
