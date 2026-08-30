import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chart_screen.dart';
import 'position_screen.dart';

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
            const _LiveSourceChip(),
            _HeroCard(account),
            const SizedBox(height: 16),
            const _WatchlistCard(),
            _AllocationCard(account),
            const _RadarCard(),
            const _NewsCard(),
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

/// Crypto-only, LIVE-only: provenance chip for the data powering this app.
class _LiveSourceChip extends ConsumerWidget {
  const _LiveSourceChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(tradingServiceProvider).market.lastError;
    return Align(
      alignment: Alignment.centerLeft,
      child: Chip(
        avatar: Icon(
          error == null ? Icons.bolt : Icons.wifi_off,
          size: 14,
          color: error == null ? TC.gain : TC.loss,
        ),
        label: Text(
          error == null
              ? 'LIVE CoinSwitch · crypto 24/7'
              : 'Reconnecting to CoinSwitch…',
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
        visualDensity: VisualDensity.compact,
        backgroundColor: TC.surface,
        side: const BorderSide(color: TC.outline),
      ),
    );
  }
}

class _HeroCard extends ConsumerWidget {
  const _HeroCard(this.account);

  final AccountState account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider).value;
    final equitySeries = (history ?? const <EquityPoint>[])
        .map((p) => p.equity)
        .toList(growable: false);
    final delta = account.dayStart == null
        ? null
        : account.equity - account.dayStart!;
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
                child: const Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: TC.gain,
                ),
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
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
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
          ),
          if (equitySeries.length >= 2) ...[
            const SizedBox(height: 12),
            Sparkline(values: equitySeries, height: 44),
          ],
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
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
                builder: (_) => PositionScreen(symbol: p.symbol)),
          ),
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
                      Text(
                        p.symbol,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
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
                    Text(
                      formatINR(p.marketValue),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    PnlChip(p.unrealizedPnl),
                  ],
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 20, color: TC.outline),
              ],
            ),
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
            Text(
              'Cannot reach CoinSwitch',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Check your internet connection — every price and chart in this '
              'app comes from the LIVE CoinSwitch API.',
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

/// AI Radar — live market overview strip. Tapping a symbol opens the
/// agentic chat so the user can dig in ("analyze RELIANCE").
class _RadarCard extends ConsumerWidget {
  const _RadarCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(marketOverviewProvider).value;
    if (rows == null || rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        SectionHeader('AI Radar', trailing: 'tap for charts · pin to watch'),
        SizedBox(
          height: 124,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final r = rows[i];
              return _SymbolTile(
                row: r,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChartScreen(symbol: r.symbol),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One pinned or radar symbol tile with a watchlist pin.
class _SymbolTile extends ConsumerWidget {
  const _SymbolTile({required this.row, required this.onTap});

  final MarketRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(watchlistProvider).contains(row.symbol);
    final up = row.changePct >= 0;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      onLongPress: () async {
        HapticFeedback.selectionClick();
        await ref.read(watchlistProvider.notifier).toggle(row.symbol);
      },
      child: Container(
        width: 134,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TC.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: pinned ? TC.gain.withValues(alpha: 0.5) : TC.outline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.symbol,
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    await ref
                        .read(watchlistProvider.notifier)
                        .toggle(row.symbol);
                  },
                  child: Icon(
                    pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 14,
                    color: pinned ? TC.gain : TC.onBgDim,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  row.trend == 'UP' ? Icons.trending_up : Icons.trending_down,
                  size: 15,
                  color: row.trend == 'UP' ? TC.gain : TC.loss,
                ),
              ],
            ),
            const Spacer(),
            Text(
              formatINR(row.last),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              '${up ? '+' : ''}${row.changePct.toStringAsFixed(1)}%  '
              'RSI ${row.rsi?.toStringAsFixed(0) ?? '-'}',
              style: TextStyle(fontSize: 11.5, color: up ? TC.gain : TC.loss),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pinned symbols at live prices — the watchlist section.
class _WatchlistCard extends ConsumerWidget {
  const _WatchlistCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(watchlistProvider);
    final rows = ref.watch(marketOverviewProvider).value ?? const [];
    if (pinned.isEmpty) return const SizedBox.shrink();
    final watched = rows.where((r) => pinned.contains(r.symbol)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('Watchlist', trailing: 'pinned symbols'),
        SizedBox(
          height: 124,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: watched.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final r = watched[i];
              return _SymbolTile(
                row: r,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChartScreen(symbol: r.symbol),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Real crypto headlines via DuckDuckGo (the agent's own web_search tool).
class _NewsCard extends ConsumerWidget {
  const _NewsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final news = ref.watch(newsProvider).value;
    if (news == null || news.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SectionHeader('Market news', trailing: 'via web search'),
        ...news
            .take(3)
            .map(
              (n) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TC.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TC.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n['title'] ?? '',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if ((n['snippet'] ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        n['snippet']!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
