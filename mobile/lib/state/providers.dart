import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/engine/alerts.dart';
import '../core/engine/trading_service.dart';
import '../core/agent/agent_engine.dart';
import '../core/models.dart';

/// Whether the user has already seen the first-launch onboarding. Async because
/// it is read from SharedPreferences on first boot; overridable in tests.
final startupPrefsProvider = FutureProvider<bool>((ref) async {
  final sp = await SharedPreferences.getInstance();
  return sp.getBool('seen_onboarding') ?? false;
});

/// The on-phone trading engine — the app IS the backend now.
/// Override this provider in tests with a stubbed service.
final tradingServiceProvider = Provider<TradingService>(
  (ref) => TradingService.instance,
);

/// One-time engine hydration (paper account + settings from secure storage).
final engineReadyProvider = FutureProvider<void>(
  (ref) => ref.watch(tradingServiceProvider).ensureLoaded(),
);

/// TRADING MODE — Paper is the mandatory starting point.
/// Live unlocks once Coinbase credentials are configured in Settings.
class TradingModeNotifier extends Notifier<AccountMode> {
  @override
  AccountMode build() => AccountMode.paper;

  void set(AccountMode mode) {
    state = mode;
    // Toggling modes re-renders EVERYTHING mode-scoped: the account
    // (paper cash vs real Coinbase equity), positions, the journal and
    // the copilot decision history.
    ref.invalidate(accountProvider);
    ref.invalidate(historyProvider);
    ref.invalidate(journalProvider);
    ref.invalidate(decisionsProvider);
  }
}

final tradingModeProvider = NotifierProvider<TradingModeNotifier, AccountMode>(
  TradingModeNotifier.new,
);

/// Crypto is the app's market: LIVE Coinbase data only, 24/7.
final marketProvider = Provider<Market>((ref) => Market.crypto);

/// Paper account snapshot, marked to LIVE Coinbase prices. Auto-dispose +
/// invalidate-driven refresh from the UI.
final accountProvider = FutureProvider.autoDispose<AccountState>((ref) async {
  await ref.watch(engineReadyProvider.future);
  final svc = ref.watch(tradingServiceProvider);
  // Mode-scoped: PAPER marks the paper book to live prices; LIVE shows
  // your REAL Coinbase balances and holdings. No cross-contamination.
  if (ref.watch(tradingModeProvider) == AccountMode.live) {
    return svc.liveAccount();
  }
  final acct = svc.paper.account;
  for (final sym in acct.positions.keys.toList()) {
    try {
      acct.mark(sym, await svc.market.last(sym));
    } catch (_) {
      /* keep last known mark on fetch failure */
    }
  }
  return svc.paperAccount();
});

/// Session journal of executed trades — PERSISTED. Every fill (manual, AI,
/// autopilot, limit) is stored via HistoryStore and reloaded on startup.
class JournalNotifier extends Notifier<List<ExecutedTrade>> {
  @override
  List<ExecutedTrade> build() {
    _hydrate();
    return const [];
  }

  Future<void> _hydrate() async {
    final svc = ref.read(tradingServiceProvider);
    await svc.ensureLoaded();
    final trades = await svc.history.loadTrades();
    if (trades.isNotEmpty) state = trades;
  }

  void add(ExecutedTrade trade) {
    state = [...state, trade];
    ref.read(tradingServiceProvider).history.addTrade(trade);
  }
}

final journalProvider = NotifierProvider<JournalNotifier, List<ExecutedTrade>>(
  JournalNotifier.new,
);

/// Selected tab of the shell (0 Portfolio, 1 Agent, 2 Copilot, 3 Journal).
/// A provider so empty-state CTAs can navigate (e.g. "Open Copilot").
class TabIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int i) => state = i;
}

final tabIndexProvider = NotifierProvider<TabIndexNotifier, int>(
  TabIndexNotifier.new,
);

/// Market overview rows for the AI Radar card — LIVE Coinbase data.
final marketOverviewProvider = FutureProvider.autoDispose<List<MarketRow>>((
  ref,
) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(tradingServiceProvider).marketOverview();
});

/// Equity curve of the paper account (per fill + a live mark-to-market point).
final historyProvider = FutureProvider.autoDispose<List<EquityPoint>>((
  ref,
) async {
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

// ---------------------------------------------------------------------------
// LIVE heartbeat: auto-refresh + limit fills + alerts
// ---------------------------------------------------------------------------

/// Fires every 30s while the shell is mounted. Each tick marks the paper
/// account to LIVE prices, fills any resting limit orders that crossed, and
/// evaluates alerts against real fetched data.
class AutoRefreshNotifier extends Notifier<DateTime?> {
  Timer? _timer;
  bool _ticking = false;

  @override
  DateTime? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    _tick(); // immediate first tick
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_ticking) return; // never overlap: live fetches can be slow
    _ticking = true;
    final svc = ref.read(tradingServiceProvider);
    try {
      final tick = await svc.refreshTick();
      ref.invalidate(accountProvider);
      ref.invalidate(marketOverviewProvider);
      ref.invalidate(historyProvider);
      final journal = ref.read(journalProvider.notifier);
      for (final (order, price) in tick.limitFills) {
        journal.add(
          ExecutedTrade(
            symbol: order.symbol,
            side: order.side,
            quantity: order.quantity,
            filledPrice: price,
            at: DateTime.now(),
          ),
        );
      }
      if (tick.alertsFired.isNotEmpty) {
        ref.read(unreadAlertsProvider.notifier).bump(tick.alertsFired.length);
        ref.read(lastFiredAlertsProvider.notifier).set(tick.alertsFired);
      }
      state = DateTime.now();
    } catch (_) {
      // network hiccup — next tick retries; never crash the heartbeat
    } finally {
      _ticking = false;
    }
  }
}

final autoRefreshProvider = NotifierProvider<AutoRefreshNotifier, DateTime?>(
  AutoRefreshNotifier.new,
);

/// Count of alert fires the user has not seen (bell badge).
class UnreadAlertsNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump(int n) => state += n;
  void clear() => state = 0;
}

final unreadAlertsProvider = NotifierProvider<UnreadAlertsNotifier, int>(
  UnreadAlertsNotifier.new,
);

/// Alerts that fired in the most recent tick (drives the snackbar).
class LastFiredAlertsNotifier extends Notifier<List<AlertRule>> {
  @override
  List<AlertRule> build() => const [];
  void set(List<AlertRule> v) => state = v;
}

final lastFiredAlertsProvider =
    NotifierProvider<LastFiredAlertsNotifier, List<AlertRule>>(
      LastFiredAlertsNotifier.new,
    );

/// The alert rule list (persisted via AlertEngine).
class AlertsNotifier extends Notifier<List<AlertRule>> {
  @override
  List<AlertRule> build() {
    _hydrate();
    return const [];
  }

  Future<void> _hydrate() async {
    final svc = ref.read(tradingServiceProvider);
    await svc.ensureLoaded();
    await svc.alerts.load();
    state = List.of(svc.alerts.rules);
  }

  Future<void> add({
    required String symbol,
    required AlertMetric metric,
    required AlertOp op,
    required double value,
  }) async {
    final svc = ref.read(tradingServiceProvider);
    await svc.alerts.add(symbol: symbol, metric: metric, op: op, value: value);
    state = List.of(svc.alerts.rules);
  }

  Future<void> remove(String id) async {
    final svc = ref.read(tradingServiceProvider);
    await svc.alerts.remove(id);
    state = List.of(svc.alerts.rules);
  }
}

final alertsProvider = NotifierProvider<AlertsNotifier, List<AlertRule>>(
  AlertsNotifier.new,
);

// ---------------------------------------------------------------------------
// Watchlist — pinned symbols on the dashboard (persisted).
// ---------------------------------------------------------------------------

class WatchlistNotifier extends Notifier<Set<String>> {
  static const _pref = 'watchlist';

  @override
  Set<String> build() {
    _hydrate();
    return const {};
  }

  Future<void> _hydrate() async {
    final sp = await SharedPreferences.getInstance();
    state = (sp.getStringList(_pref) ?? const []).toSet();
  }

  Future<void> toggle(String symbol) async {
    final next = Set<String>.from(state);
    if (!next.add(symbol)) next.remove(symbol);
    state = next;
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_pref, next.toList());
  }
}

final watchlistProvider = NotifierProvider<WatchlistNotifier, Set<String>>(
  WatchlistNotifier.new,
);

// ---------------------------------------------------------------------------
// News — real headlines via DuckDuckGo (the agent's own web_search tool).
// ---------------------------------------------------------------------------

final newsProvider = FutureProvider.autoDispose<List<Map<String, String>>>((
  ref,
) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(tradingServiceProvider).news();
});

// ---------------------------------------------------------------------------
// Autopilot — the crew re-runs on a timer while the app is open. Proposals
// still queue for YOUR approval; the Risk Engine still gates execution.
// ---------------------------------------------------------------------------

class AutopilotState {
  const AutopilotState({
    this.enabled = false,
    this.intervalMinutes = 15,
    this.goal =
        'Grow the paper portfolio with disciplined, moderate-risk entries.',
    this.running = false,
    this.lastRun,
  });
  final bool enabled;
  final int intervalMinutes;
  final String goal;
  final bool running;
  final DateTime? lastRun;

  AutopilotState copyWith({
    bool? enabled,
    int? intervalMinutes,
    String? goal,
    bool? running,
    DateTime? lastRun,
  }) => AutopilotState(
    enabled: enabled ?? this.enabled,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    goal: goal ?? this.goal,
    running: running ?? this.running,
    lastRun: lastRun ?? this.lastRun,
  );
}

class AutopilotNotifier extends Notifier<AutopilotState> {
  Timer? _timer;

  @override
  AutopilotState build() {
    ref.onDispose(() => _timer?.cancel());
    return const AutopilotState();
  }

  void setEnabled(bool on) {
    _timer?.cancel();
    _timer = null;
    state = state.copyWith(enabled: on, running: false);
    if (on) {
      _timer = Timer.periodic(
        Duration(minutes: state.intervalMinutes),
        (_) => runOnce(),
      );
      Future.delayed(const Duration(seconds: 2), runOnce);
    }
  }

  void setInterval(int minutes) {
    state = state.copyWith(intervalMinutes: minutes);
    if (state.enabled) setEnabled(true); // restart with the new interval
  }

  void setGoal(String goal) => state = state.copyWith(goal: goal);

  Future<void> runOnce() async {
    if (state.running || !state.enabled) return;
    state = state.copyWith(running: true);
    final svc = ref.read(tradingServiceProvider);
    try {
      final result = await svc.runCrew(
        state.goal,
        mode: ref.read(tradingModeProvider),
      );
      ref.read(pendingProposalsProvider.notifier).addAll(result.proposals);
      ref.invalidate(accountProvider);
    } catch (_) {
      /* keep autopilot alive on network errors */
    } finally {
      state = state.copyWith(running: false, lastRun: DateTime.now());
    }
  }
}

final autopilotProvider = NotifierProvider<AutopilotNotifier, AutopilotState>(
  AutopilotNotifier.new,
);

/// Proposals waiting for the user's decision (autopilot queue).
class PendingProposalsNotifier extends Notifier<List<Object>> {
  @override
  List<Object> build() => const [];

  void addAll(List<Object> proposals) => state = [...state, ...proposals];

  void remove(Object p) =>
      state = state.where((e) => !identical(e, p)).toList();
}

final pendingProposalsProvider =
    NotifierProvider<PendingProposalsNotifier, List<Object>>(
      PendingProposalsNotifier.new,
    );

/// Persisted copilot/agent decision log (approve & reject records).
final decisionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(tradingServiceProvider).history.loadDecisions();
});

/// Persisted agent crew sessions (goal → trace → reply → proposals).
final agentSessionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(tradingServiceProvider).history.loadSessions();
});

/// One message in the agent conversation. Either a user line, a live crew
/// result, or a turn restored from persisted history (display-only — old
/// proposals are never re-executable at stale prices).
class ChatEntry {
  ChatEntry.user(this.text)
      : isUser = true,
        result = null,
        restored = null;

  ChatEntry.result(this.result)
      : isUser = false,
        text = '',
        restored = null;

  ChatEntry.restored(this.restored)
      : isUser = false,
        text = '',
        result = null;

  final bool isUser;
  final String text;
  final AgentRunResult? result;
  final Map<String, dynamic>? restored; // persisted session map
}

/// The agent conversation — held at PROVIDER scope so it survives tab
/// switches and navigation for as long as the app process is alive (only
/// swiping the app away from recents clears it).
class AgentChatState {
  const AgentChatState({
    required this.entries,
    required this.chatId,
    this.sending = false,
  });

  final List<ChatEntry> entries;
  final String chatId; // groups the turns of THIS conversation in history
  final bool sending;
}

String _newChatId() =>
    'chat-${DateTime.now().millisecondsSinceEpoch}';

AgentRunResult _agentGreeting() {
  final r = AgentRunResult(goal: 'hello');
  r.brain = 'system'; // UI intro, NOT a crew answer — the crew replies
  // agentic/LLM-generated once you actually ask something.
  r.reply =
      "Hi! I'm your agentic trading crew running fully on this phone "
      'over LIVE Coinbase data. I scan the market, read the news, check '
      'indicators and your account, and draft Risk-Engine-checked '
      'proposals. Try "Scan the market", ask me to suggest a good '
      'position with an amount like "invest 5000", or set a goal.';
  return r;
}

class AgentChatNotifier extends Notifier<AgentChatState> {
  @override
  AgentChatState build() => AgentChatState(
        entries: [ChatEntry.result(_agentGreeting())],
        chatId: _newChatId(),
      );

  void addUser(String msg) {
    state = AgentChatState(
      entries: [...state.entries, ChatEntry.user(msg)],
      chatId: state.chatId,
      sending: state.sending,
    );
  }

  /// Adds an empty result entry while the crew runs (live trace), or
  /// replaces the last (still-running) entry with the final result.
  void pushOrReplaceResult(AgentRunResult result) {
    final entries = [...state.entries];
    if (entries.isNotEmpty &&
        !entries.last.isUser &&
        entries.last.result != null &&
        entries.last.result!.reply.isEmpty &&
        entries.last.result!.steps.isEmpty) {
      entries[entries.length - 1] = ChatEntry.result(result);
    } else {
      entries.add(ChatEntry.result(result));
    }
    state = AgentChatState(
      entries: entries,
      chatId: state.chatId,
      sending: state.sending,
    );
  }

  void setSending(bool v) => state = AgentChatState(
        entries: state.entries,
        chatId: state.chatId,
        sending: v,
      );

  /// Opens a past conversation from the agent history: reconstructs the
  /// turns (display-only) and continues under the SAME chat id, so new
  /// messages append to that conversation in history too.
  void openChat(List<Map<String, dynamic>> sessions, String chatId) {
    final entries = <ChatEntry>[ChatEntry.result(_agentGreeting())];
    for (final s in sessions) {
      entries.add(ChatEntry.user(s['goal'] as String? ?? ''));
      entries.add(ChatEntry.restored(s));
    }
    state = AgentChatState(entries: entries, chatId: chatId);
  }

  void newChat() => state = AgentChatState(
        entries: [ChatEntry.result(_agentGreeting())],
        chatId: _newChatId(),
      );
}

final agentChatProvider =
    NotifierProvider<AgentChatNotifier, AgentChatState>(
  AgentChatNotifier.new,
);
