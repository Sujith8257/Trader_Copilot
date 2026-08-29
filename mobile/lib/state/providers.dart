import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/models.dart';

/// Whether the user has already seen the first-launch onboarding. Async because
/// it is read from SharedPreferences on first boot; overridable in tests.
final startupPrefsProvider = FutureProvider<bool>((ref) async {
  final sp = await SharedPreferences.getInstance();
  return sp.getBool('seen_onboarding') ?? false;
});

/// Backend API client (overridable in tests).
final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// TRADING MODE — Paper is the mandatory starting point.
/// Live stays locked until a broker pack + explicit user setup exist.
class TradingModeNotifier extends Notifier<AccountMode> {
  @override
  AccountMode build() => AccountMode.paper;

  void set(AccountMode mode) => state = mode;
}

final tradingModeProvider =
    NotifierProvider<TradingModeNotifier, AccountMode>(
        TradingModeNotifier.new);

/// Selected market: NSE stocks or the 24/7 crypto paper market.
class MarketSelectionNotifier extends Notifier<Market> {
  @override
  Market build() => Market.stocks;

  void set(Market m) => state = m;
}

final marketProvider =
    NotifierProvider<MarketSelectionNotifier, Market>(
        MarketSelectionNotifier.new);

/// Account snapshot from the backend paper broker.
final accountProvider = FutureProvider.autoDispose<AccountState>((ref) async {
  final market = ref.watch(marketProvider);
  return ref.watch(apiClientProvider).fetchAccount(market: market);
});

/// Session journal of executed trades (persisted to SQLite in a later phase).
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

/// Market overview rows for the AI Radar card on the dashboard.
final marketOverviewProvider =
    FutureProvider.autoDispose<List<MarketRow>>((ref) async {
  final market = ref.watch(marketProvider);
  return ref.watch(apiClientProvider).marketOverview(market: market);
});

/// Equity curve of the paper account (for the dashboard sparkline).
final historyProvider =
    FutureProvider.autoDispose<List<EquityPoint>>((ref) async {
  final market = ref.watch(marketProvider);
  return ref.watch(apiClientProvider).fetchAccountHistory(market: market);
});

