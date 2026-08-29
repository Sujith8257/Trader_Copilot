import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/engine/trading_service.dart';
import '../core/models.dart';

/// Whether the user has already seen the first-launch onboarding. Async because
/// it is read from SharedPreferences on first boot; overridable in tests.
final startupPrefsProvider = FutureProvider<bool>((ref) async {
  final sp = await SharedPreferences.getInstance();
  return sp.getBool('seen_onboarding') ?? false;
});

/// The on-phone trading engine — the app IS the backend now.
/// Override this provider in tests with a stubbed service.
final tradingServiceProvider =
    Provider<TradingService>((ref) => TradingService.instance);

/// One-time engine hydration (paper account + settings from secure storage).
final engineReadyProvider =
    FutureProvider<void>((ref) => ref.watch(tradingServiceProvider).ensureLoaded());

/// TRADING MODE — Paper is the mandatory starting point.
/// Live unlocks once Coinbase credentials are configured in Settings.
class TradingModeNotifier extends Notifier<AccountMode> {
  @override
  AccountMode build() => AccountMode.paper;

  void set(AccountMode mode) => state = mode;
}

final tradingModeProvider =
    NotifierProvider<TradingModeNotifier, AccountMode>(
        TradingModeNotifier.new);

/// Crypto is the app's market: LIVE Coinbase data only, 24/7.
final marketProvider = Provider<Market>((ref) => Market.crypto);

/// Paper account snapshot, marked to LIVE Coinbase prices. Auto-dispose +
/// invalidate-driven refresh from the UI.
final accountProvider = FutureProvider.autoDispose<AccountState>((ref) async {
  await ref.watch(engineReadyProvider.future);
  final svc = ref.watch(tradingServiceProvider);
  final acct = svc.paper.account;
  for (final sym in acct.positions.keys.toList()) {
    try {
      acct.mark(sym, await svc.market.last(sym));
    } catch (_) {/* keep last known mark on fetch failure */}
  }
  return svc.paperAccount();
});

/// Session journal of executed trades.
class JournalNotifier extends Notifier<List<ExecutedTrade>> {
  @override
  List<ExecutedTrade> build() => const [];

  void add(ExecutedTrade trade) => state = [...state, trade];
}

final journalProvider =
    NotifierProvider<JournalNotifier, List<ExecutedTrade>>(
        JournalNotifier.new);

/// Selected tab of the shell (0 Portfolio, 1 Agent, 2 Copilot, 3 Journal).
/// A provider so empty-state CTAs can navigate (e.g. "Open Copilot").
class TabIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int i) => state = i;
}

final tabIndexProvider =
    NotifierProvider<TabIndexNotifier, int>(TabIndexNotifier.new);

/// Market overview rows for the AI Radar card — LIVE Coinbase data.
final marketOverviewProvider =
    FutureProvider.autoDispose<List<MarketRow>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(tradingServiceProvider).marketOverview();
});

/// Equity curve of the paper account (per fill + a live mark-to-market point).
final historyProvider =
    FutureProvider.autoDispose<List<EquityPoint>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  final svc = ref.watch(tradingServiceProvider);
  final points = [
    for (final p in svc.paper.account.equityHistory)
      EquityPoint(
        t: DateTime.tryParse(p['t'] as String? ?? '') ?? DateTime.now(),
        equity: (p['equity'] as num?)?.toDouble() ?? 0,
      ),
  ];
  points.add(EquityPoint(t: DateTime.now(), equity: svc.paper.account.equity));
  return points;
});

/// Kill switch — off blocks EVERY proposal, AI or manual.
final killSwitchProvider = Provider<bool>((ref) {
  ref.watch(engineReadyProvider).whenData((_) => null);
  return ref.watch(tradingServiceProvider).risk.config.enabled;
});

