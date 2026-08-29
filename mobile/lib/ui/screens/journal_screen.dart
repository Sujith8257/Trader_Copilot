import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/providers.dart';

/// Trading journal: every approved (or rejected) proposal is recorded with
/// what was executed. SQLite persistence and post-trade AI analysis arrive
/// in a later phase.
class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trades = ref.watch(journalProvider);

    if (trades.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('No trades yet.'),
              const Text(
                'Approved paper trades will be journaled here — proposal, '
                'approval, fill, and later post-trade analysis.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: trades.length,
      itemBuilder: (context, i) {
        final t = trades[trades.length - 1 - i]; // newest first
        return Card(
          child: ListTile(
            leading: Icon(
              t.side == Side.buy ? Icons.arrow_downward : Icons.arrow_upward,
              color: t.side == Side.buy ? Colors.green : Colors.red,
            ),
            title: Text(
                '${t.side == Side.buy ? 'BOUGHT' : 'SOLD'} ${t.quantity} ${t.symbol}'),
            subtitle: Text(
                'at ${t.filledPrice.toStringAsFixed(2)} · '
                'notional ${t.notional.toStringAsFixed(2)} · '
                '${t.at.toLocal().toString().substring(0, 19)}'),
          ),
        );
      },
    );
  }
}

