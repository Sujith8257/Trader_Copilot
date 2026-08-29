import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Portfolio screen: net worth, allocation and open positions from the
/// paper broker. Everything here is deterministic backend state.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountProvider);
    return accountAsync.when(
      loading: () => const _LoadingView(),
      error: (e, _) => _ErrorView(
        error: e.toString(),
        onRetry: () => ref.invalidate(accountProvider),
      ),
      data: (account) => RefreshIndicator(
        color: TC.gain,
        backgroundColor: TC.surfaceHi,
        onRefresh: () async => ref.invalidate(accountProvider),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _HeroCard(account),
            const SizedBox(height: 16),
            _AllocationCard(account),
            const SizedBox(height: 20),
            SectionHeader(
              'Open positions',
              trailing: account.positions.isEmpty
                  ? null
                  : '${account.positions.length}',
            ),
            if (account.positions.isEmpty)
              EmptyState(
                icon: Icons.insights_outlined,
                title: 'No open positions',
                message:
                    'Ask your Copilot for a trade idea — the Risk Engine checks '
                    'every proposal before you decide anything.',
                ctaLabel: 'Open Copilot',
                onCta: () => ref.read(tabIndexProvider.notifier).set(2),
              )
            else
              ...account.positions.values.map(_PositionTile.new),
          ],
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard(this.account);

  final AccountState account;

  @override
  Widget build(BuildContext context) {
    final delta =
        account.dayStart == null ? null : account.equity - account.dayStart!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: TC.heroGradient,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: TC.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.shield_outlined, size: 18, color: TC.gain),
              ),
              const SizedBox(width: 10),
              Text(
                account.mode == AccountMode.paper
                    ? 'Paper Trading Account'
                    : 'Live Account',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('Net worth', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  formatINR(account.equity),
                  key: ValueKey(account.equity),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
              if (delta != null) ...[
                const SizedBox(width: 10),
                PnlChip(delta, suffix: ' today'),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  solid: true,
                  label: 'Cash',
                  value: formatINR(account.cash),
                  icon: Icons.savings_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  solid: true,
                  label: 'Exposure',
                  value: formatINR(account.grossExposure),
                  icon: Icons.donut_large_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  solid: true,
                  label: 'Positions',
                  value: '${account.positions.length}',
                  icon: Icons.pie_chart_outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AllocationCard extends StatelessWidget {
  const _AllocationCard(this.account);

  final AccountState account;

  @override
  Widget build(BuildContext context) {
    final slices = <AllocationSlice>[
      AllocationSlice('Cash', account.cash, TC.info),
      ...account.positions.values.toList().asMap().entries.map(
            (e) => AllocationSlice(
              e.value.symbol,
              e.value.marketValue,
              TC.accents[e.key % TC.accents.length],
            ),
          ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('Allocation'),
            AllocationBar(slices: slices),
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
    final accent = TC.accents[p.symbol.hashCode.abs() % TC.accents.length];
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
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  p.symbol.isNotEmpty ? p.symbol[0] : '?',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.symbol,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${p.quantity} @ ${formatINR(p.avgPrice, decimals: 2)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatINR(p.marketValue),
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  PnlChip(p.unrealizedPnl),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        const Skeleton(height: 170, radius: 24),
        const SizedBox(height: 16),
        const Skeleton(height: 96, radius: 20),
        const SizedBox(height: 20),
        const Skeleton(width: 140, height: 18, radius: 8),
        const SizedBox(height: 12),
        for (var i = 0; i < 3; i++) ...[
          const Skeleton(height: 76, radius: 20),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: TC.loss.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.cloud_off, size: 32, color: TC.loss),
            ),
            const SizedBox(height: 16),
            Text('Cannot reach the backend',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Start it with:  cd backend && uvicorn app.main:app --reload',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}


