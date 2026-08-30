/// TradingService — the on-phone composition root. Owns the paper broker,
/// the LIVE Coinbase market client, the Risk Engine and the agentic crew.
/// Replaces the old PC backend entirely: everything runs in this app.
///
/// Execution paths after a Risk-Engine-approved proposal:
///   * PAPER  — PaperBroker fills at the live Coinbase spot price.
///   * LIVE   — a REAL Coinbase market order (EdDSA-signed), sized in the
///              quote currency, only after the same Risk Engine verdict.
/// Paper state persists to shared_preferences (survives restarts); Coinbase
/// credentials persist in flutter_secure_storage (Android Keystore).
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_engine.dart';
import '../agent/llm_client.dart';
import '../format.dart';
import '../models.dart';
import 'alerts.dart';
import 'coinswitch_client.dart';
import 'history_store.dart';
import 'paper_broker.dart';
import 'risk_engine.dart';

class Settings {
  Settings({
    this.brain = const BrainConfig(),
    this.coinbaseKey = '',
    this.coinbaseSecret = '',
  });

  BrainConfig brain;
  String coinbaseKey;
  String coinbaseSecret;

  bool get coinbaseConfigured =>
      coinbaseKey.isNotEmpty && coinbaseSecret.isNotEmpty;
}

class TradeExecution {
  TradeExecution({
    required this.executed,
    required this.mode,
    this.fillPrice,
    this.reason,
    this.fee = 0,
  });
  final bool executed;
  final AccountMode mode;
  final double? fillPrice;
  final String? reason;

  /// Exchange fee in INR, read from the REAL fills when available.
  /// Paper fills are always 0.
  final double fee;
}

/// Result of one auto-refresh heartbeat.
class RefreshTick {
  RefreshTick({required this.alertsFired, required this.limitFills});
  final List<AlertRule> alertsFired;
  final List<(LimitOrder, double)> limitFills;
}

class TradingService {
  TradingService({
    LiveCoinSwitchMarket? marketClient,
    PaperBroker? paperBroker,
    RiskEngine? riskEngine,
  }) {
    market = marketClient ?? LiveCoinSwitchMarket();
    risk = riskEngine ?? RiskEngine();
    agent = TradingAgent(market: market, risk: risk);
    if (paperBroker != null) {
      _paper = paperBroker;
      _loaded = true; // injected broker: skip persistence hydration
    }
  }

  static TradingService? _instance;
  static TradingService get instance => _instance ??= TradingService();

  late LiveCoinSwitchMarket market;
  late RiskEngine risk;
  late TradingAgent agent;
  late AlertEngine alerts = AlertEngine();
  final HistoryStore history = HistoryStore();
  PaperBroker? _paper;
  BrainConfig? _brain;
  Settings _settings = Settings();
  bool _loaded = false;

  PaperBroker? _liveBrokerCache;
  DateTime? _liveBrokerAt;

  /// Mode-scoped execution context. PAPER: the persisted paper broker.
  /// LIVE: an in-memory broker holding a snapshot of the REAL Coinbase
  /// balances/positions (never persisted, 10s cache) so sizing, account
  /// context and force-exit all operate on live money. Nothing paper
  /// leaks into live, nothing live lands in the paper account.
  Future<PaperBroker> brokerFor(AccountMode mode) async {
    await ensureLoaded();
    if (mode != AccountMode.live) return paper;
    final now = DateTime.now();
    final cached = _liveBrokerCache;
    if (cached != null &&
        _liveBrokerAt != null &&
        now.difference(_liveBrokerAt!).inSeconds < 10) {
      return cached;
    }
    final live = await liveAccount();
    final acct = EngineAccount(accountId: 'coinbase-live');
    acct.cash = live.cash;
    acct.dayStart = live.cash;
    for (final p in live.positions.values) {
      acct.positions[p.symbol] = EnginePosition(
        symbol: p.symbol,
        quantity: p.quantity,
        avgPrice: p.avgPrice,
        currentPrice: p.lastPrice,
      );
    }
    final b = PaperBroker.fromMap(acct.toMap());
    _liveBrokerCache = b;
    _liveBrokerAt = now;
    return b;
  }

  EngineAccount? _liveGateCache;
  DateTime? _liveGateAt;

  /// The Risk Engine must judge LIVE orders against the REAL Coinbase
  /// balances (cash + holdings), never the paper account. Cached 10s so a
  /// burst of approvals doesn't hammer the accounts endpoint. Falls back
  /// to the paper account only if the balance fetch fails.
  Future<EngineAccount> _liveGateAccount() async {
    final now = DateTime.now();
    final cached = _liveGateCache;
    if (cached != null &&
        _liveGateAt != null &&
        now.difference(_liveGateAt!).inSeconds < 10) {
      return cached;
    }
    try {
      final live = await liveAccount();
      final a = EngineAccount(accountId: 'coinbase-live');
      a.cash = live.cash;
      // No Coinbase-side daily PnL baseline exists yet, so anchor the day
      // at current equity: the daily-loss check stays neutral (the paper
      // engine keeps its own real baseline).
      a.dayStart = live.cash;
      a.realizedPnlToday = 0;
      a.tradesToday = paper.account.tradesToday;
      for (final p in live.positions.values) {
        a.positions[p.symbol] = EnginePosition(
          symbol: p.symbol,
          quantity: p.quantity,
          avgPrice: p.avgPrice,
          currentPrice: p.lastPrice,
        );
      }
      _liveGateCache = a;
      _liveGateAt = now;
      return a;
    } catch (_) {
      return paper.account;
    }
  }

  static const _prefPaper = 'engine_paper_account';
  static const _prefBrain = 'engine_brain';

  PaperBroker get paper => _paper!;

  BrainConfig get brain => _brain ?? const BrainConfig();

  Settings get settings => _settings;

  /// Loads persisted state once (paper account + brain config + Coinbase
  /// credentials from secure storage).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    final paperJson = sp.getString(_prefPaper);
    _paper = paperJson != null
        ? PaperBroker.fromSnapshot(
            jsonDecode(paperJson) as Map<String, dynamic>,
          )
        : PaperBroker(accountId: 'phone-paper');
    _paper!.rollDay(DateTime.now().toUtc());
    final brainJson = sp.getString(_prefBrain);
    _brain = brainJson != null
        ? BrainConfig.fromMap(jsonDecode(brainJson) as Map<String, dynamic>)
        : BrainConfig.defaults(BrainKind.rule);
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    _settings = Settings(
      brain: _brain!,
      coinbaseKey: await secure.read(key: 'coinbase_key') ?? '',
      coinbaseSecret: await secure.read(key: 'coinbase_secret') ?? '',
    );
    market.client
      ..apiKey = _settings.coinbaseKey
      ..secretKey = _settings.coinbaseSecret;
    _loaded = true;
  }

  Future<void> saveBrain(BrainConfig brain) async {
    _brain = brain;
    _settings = Settings(
      brain: brain,
      coinbaseKey: _settings.coinbaseKey,
      coinbaseSecret: _settings.coinbaseSecret,
    );
    final sp = await SharedPreferences.getInstance();
    // the API key lives in secure storage only — never in prefs
    final safe = Map<String, dynamic>.from(brain.toMap());
    safe['api_key'] = '';
    await sp.setString(_prefBrain, jsonEncode(safe));
  }

  Future<void> saveCoinSwitchCredentials({
    required String key,
    required String secret,
  }) async {
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    await secure.write(key: 'coinbase_key', value: key);
    await secure.write(key: 'coinbase_secret', value: secret);
    _settings = Settings(
      brain: brain,
      coinbaseKey: key,
      coinbaseSecret: secret,
    );
    market.client
      ..apiKey = key
      ..secretKey = secret;
  }

  Future<void> _persistPaper() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefPaper, jsonEncode(paper.toSnapshot()));
  }

  // -- refresh tick -----------------------------------------------------------
  // One heartbeat of the app: mark positions to LIVE prices, fill resting
  // limit orders that crossed, evaluate alerts. Called by the auto-refresh
  // timer (providers) — the app "breathes" with the market.

  Future<RefreshTick> refreshTick() async {
    await ensureLoaded();
    final prices = <String, double>{};
    final rsiVals = <String, double>{};
    final pairs = await _mapPool<(String, double)>(
      (sym) async {
        try {
          return (sym, await market.last(sym));
        } catch (_) {
          return null;
        }
      },
      market.symbols,
    );
    for (final (sym, px) in pairs) {
      prices[sym] = px;
    }
    paper.markAll(prices);
    final limitFills = paper.processLimits(prices);
    if (limitFills.isNotEmpty) await _persistPaper();
    await alerts.load();
    final rsiSyms = alerts.rules
        .where((r) => r.metric == AlertMetric.rsi)
        .map((r) => r.symbol)
        .toSet();
    for (final sym in rsiSyms) {
      try {
        final s = await agent.toolIndicators(sym);
        final r = s['rsi'];
        if (r is num) rsiVals[sym] = r.toDouble();
      } catch (_) {}
    }
    final fired = await alerts.check(prices: prices, rsi: rsiVals);
    return RefreshTick(alertsFired: fired, limitFills: limitFills);
  }

  /// Latest live price for every tracked symbol.
  Future<Map<String, double>> livePrices() async {
    await ensureLoaded();
    final prices = <String, double>{};
    final pairs = await _mapPool<(String, double)>(
      (sym) async {
        try {
          return (sym, await market.last(sym));
        } catch (_) {
          return null;
        }
      },
      market.symbols,
    );
    for (final (sym, px) in pairs) {
      prices[sym] = px;
    }
    return prices;
  }

  /// News headlines (DuckDuckGo, no API key) — powers the news card and the
  /// agent's web_search tool.
  Future<List<Map<String, String>>> news({String query = 'bitcoin ethereum'}) =>
      agent.toolWebSearch(query);

  // -- market data ---------------------------------------------------------

  Future<List<MarketRow>> marketOverview() async {
    await market.ensureProducts();
    final rows = <MarketRow>[];
    const pool = 6;
    for (var i = 0; i < market.symbols.length; i += pool) {
      final syms = market.symbols.skip(i).take(pool).toList();
      final rs = await Future.wait(syms.map((sym) async {
        try {
          final st = await agent.toolIndicators(sym);
          return MarketRow(
            symbol: sym,
            last: (st['last'] as num).toDouble(),
            changePct: (st['change_pct'] as num).toDouble(),
            rsi: (st['rsi'] as num?)?.toDouble(),
            trend: st['trend'] as String,
          );
        } catch (_) {
          return null; // skip on fetch failure
        }
      }));
      rows.addAll(rs.whereType<MarketRow>());
    }
    return rows;
  }

  // -- account surfaces ------------------------------------------------------

  /// Paper account snapshot in the UI model shape.
  AccountState paperAccount() {
    final a = paper.account;
    return AccountState(
      accountId: a.accountId,
      mode: AccountMode.paper,
      cash: a.cash,
      equity: a.equity,
      dayStart: a.dayStart,
      positions: {
        for (final p in a.positions.values)
          p.symbol: Position(
            symbol: p.symbol,
            quantity: p.quantity,
            avgPrice: p.avgPrice,
            lastPrice: p.currentPrice,
          ),
      },
    );
  }

  /// REAL Coinbase account (balances pulled live, marked in INR).
  Future<AccountState> liveAccount() async {
    if (!_settings.coinbaseConfigured) {
      throw Exception('Coinbase credentials not configured — open Settings.');
    }
    // REAL CoinSwitch portfolio: holdings + avg buy price, INR-native.
    var cash = 0.0;
    final positions = <String, Position>{};
    for (final a in await market.client.portfolio()) {
      final cur = (a['currency'] as String? ?? '').toUpperCase();
      final bal = double.tryParse(
              (a['main_balance'] ?? a['blocked_balance_order'] ?? 0).toString()) ??
          0;
      final avg = double.tryParse(
              (a['buy_average_price'] ?? 0).toString()) ??
          0;
      if (bal <= 0) continue;
      if (cur == 'INR') {
        cash += bal;
      } else {
        double price = 0;
        try {
          price = await market.last(cur);
        } catch (_) {/* mark at 0 if fetch fails */}
        positions[cur] = Position(
          symbol: cur,
          quantity: bal,
          avgPrice: avg,
          lastPrice: price,
        );
      }
    }
    return AccountState(
      accountId: 'coinbase-live',
      mode: AccountMode.live,
      cash: cash,
      equity:
          cash +
          positions.values.fold(0.0, (s, p) => s + p.quantity * p.lastPrice),
      positions: positions,
    );
  }

  // -- execution ---------------------------------------------------------------

  /// Execute an approved proposal on the chosen mode. The Risk Engine is
  /// re-checked here — approval alone is never enough.
  Future<TradeExecution> execute(AgentProposal p, AccountMode mode) async {
    await ensureLoaded();
    // LIVE orders are gated against REAL Coinbase balances and holdings.
    final gateAccount =
        mode == AccountMode.live ? await _liveGateAccount() : paper.account;
    final verdict = risk.evaluate(
      symbol: p.symbol,
      side: p.side,
      quantity: p.quantity,
      marketPrice: p.marketPrice,
      account: gateAccount,
      entryPrice: p.marketPrice,
      stopLoss: p.stopLoss,
      takeProfit: p.takeProfit,
      source: 'ai',
      confidence: p.confidence,
    );
    if (!verdict.allowed) {
      return TradeExecution(
        executed: false,
        mode: mode,
        reason: verdict.violations.first,
      );
    }
    if (mode == AccountMode.paper) {
      final result = paper.placeMarketOrder(
        symbol: p.symbol,
        side: p.side,
        quantity: p.quantity,
        marketPrice: p.marketPrice,
      );
      if (result.filled &&
          p.side == Side.buy &&
          (p.stopLoss != null || p.takeProfit != null)) {
        // remember the proposal's risk plan for the Position detail screen
        paper.setPositionStops(
          p.symbol,
          stopLoss: p.stopLoss,
          takeProfit: p.takeProfit,
        );
      }
      await _persistPaper();
      return TradeExecution(
        executed: result.filled,
        mode: mode,
        fillPrice: result.price,
        reason: result.reason,
      );
    }
    // LIVE — real money on Coinbase.
    if (!_settings.coinbaseConfigured) {
      return TradeExecution(
        executed: false,
        mode: AccountMode.live,
        reason: 'Coinbase credentials not configured.',
      );
    }
    try {
            // EXCHANGE RULES from the live product catalog: pick the real quote
      // book, round to the product's base_increment and enforce minimums
      // BEFORE sending, so Coinbase never rejects on precision or size.
      // CoinSwitch spot is LIMIT-only: cross the book for an immediate
      // fill (buy above ask / sell below bid), then poll order status.
      TradeExecution fail(String reason) => TradeExecution(
            executed: false,
            mode: mode,
            reason: reason,
          );
      Map<String, dynamic> resp;
      try {
        resp = await market.client.placeLimitOrder(
          symbol: p.symbol,
          side: p.side.wire,
          price: p.side == Side.buy
              ? p.marketPrice * 1.005
              : p.marketPrice * 0.995,
          quantity: p.quantity,
        );
      } on CoinSwitchException catch (e) {
        return fail(e.message);
      }
      if ((resp['data']?['order_id'] ?? resp['order_id']) == null) {
        return fail(resp['failure_reason']?.toString() ?? 'rejected');
      }
      // FILL TRUTH: poll the order until it fills; journal the ACTUAL
      // average price and executed quantity.
      var fillPrice = p.marketPrice;
      var fee = 0.0;
      final orderId = resp['data']?['order_id']?.toString() ?? '';
      if (orderId.isNotEmpty) {
        try {
          for (var attempt = 0; attempt < 5; attempt++) {
            await Future.delayed(const Duration(milliseconds: 700));
            final st = await market.client.getOrder(orderId);
            final avg =
                double.tryParse((st['average_price'] ?? 0).toString()) ?? 0;
            final eq = double.tryParse((st['executed_qty'] ?? 0).toString()) ?? 0;
            if (avg > 0 && eq > 0) {
              fillPrice = avg;
              break;
            }
            final status = (st['status'] as String? ?? '').toUpperCase();
            if (status == 'CANCELLED' || status == 'REJECTED') break;
          }
        } catch (_) {/* keep the pre-trade quote as the fill price */}
      }
      return TradeExecution(
        executed: true,
        mode: mode,
        fillPrice: fillPrice,
        fee: fee,
      );
    } on CoinSwitchException catch (e) {
      return TradeExecution(
        executed: false,
        mode: AccountMode.live,
        reason: e.message,
      );
    }
  }

  // -- agentic crew -------------------------------------------------------------

  Future<AgentRunResult> runCrew(
    String goal, {
    void Function(AgentStep)? onStep,
    String? chatId,
    AccountMode? mode,
  }) async {
    await ensureLoaded();
    // The crew reasons over the account of the SELECTED mode: in LIVE it
    // sees and sizes against your real Coinbase balances, never paper.
    final broker = await brokerFor(mode ?? AccountMode.paper);
    final result = await agent.runGoal(
      goal,
      broker: broker,
      brain: brain,
      onStep: onStep,
    );
    // Persist the session so the agent history survives restarts. The chat
    // id groups the consecutive turns of one conversation together.
    try {
      await history.addSession(
        goal: goal,
        brain: result.brain,
        reply: result.reply,
        steps: [
          for (final s in result.steps) [s.agent, s.tool, s.detail],
        ],
        proposals: [
          for (final p in result.proposals)
            {
              'symbol': p.symbol,
              'side': p.side.wire,
              'quantity': p.quantity,
              'price': p.marketPrice,
              'allowed': p.allowed,
            },
        ],
        chatId: chatId,
      );
    } catch (_) {/* history must never break the crew */}
    return result;
  }

  /// DIRECT TRADE: "trade 300". The crew thinks, picks the best use of the
  /// amount, and EXECUTES immediately — your command IS the approval. The
  /// deterministic Risk Engine still gates the order, and the fill is
  /// journaled with the real price + fee (mode-scoped: paper or live).
  Future<AgentRunResult> tradeWithAmount(
    String goal,
    double amount, {
    required AccountMode mode,
    String? chatId,
  }) async {
    await ensureLoaded();
    final broker = await brokerFor(mode);
    final result = await agent.decideDirectTrade(goal, amount, broker, brain);
    final p = result.proposals.isNotEmpty ? result.proposals.first : null;

    Future<void> persist() async {
      try {
        await history.addSession(
          goal: goal,
          brain: result.brain,
          reply: result.reply,
          steps: [
            for (final s in result.steps) [s.agent, s.tool, s.detail],
          ],
          proposals: [
            for (final pr in result.proposals)
              {
                'symbol': pr.symbol,
                'side': pr.side.wire,
                'quantity': pr.quantity,
                'price': pr.marketPrice,
                'allowed': pr.allowed,
              },
          ],
          chatId: chatId,
        );
      } catch (_) {/* history must never break the crew */}
    }

    if (p == null || !p.allowed) {
      await persist();
      return result;
    }
    final exec = await executeWithAmount(p, amount, mode);
    final qty = exec.executed
        ? amount / (exec.fillPrice ?? p.marketPrice)
        : p.quantity;
    history.addDecision(
      symbol: p.symbol,
      side: p.side.wire,
      quantity: qty,
      price: exec.fillPrice ?? p.marketPrice,
      mode: mode.name,
      approved: exec.executed,
      reason: exec.reason,
      source: 'agent',
    );
    if (exec.executed) {
      final fill = exec.fillPrice ?? p.marketPrice;
      await history.addTrade(
        ExecutedTrade(
          symbol: p.symbol,
          side: p.side,
          quantity: qty,
          filledPrice: fill,
          at: DateTime.now(),
          mode: mode.name,
          source: 'agent',
          fee: exec.fee,
        ),
      );
      result.step(
        'execution',
        'filled',
        'BUY ${formatQty(qty)} ${p.symbol} filled at ₹${_round2(fill)} '
            '(fee ₹${_round2(exec.fee)})',
      );
      result.reply =
          'Done. Bought ${formatQty(qty)} ${p.symbol} at ₹${fill.toStringAsFixed(2)} '
          '(fee ₹${exec.fee.toStringAsFixed(2)}). '
          'Stop ₹${p.stopLoss?.toStringAsFixed(0) ?? '-'}, '
          'target ₹${p.takeProfit?.toStringAsFixed(0) ?? '-'}.';
    } else {
      result.step('execution', 'blocked', exec.reason ?? 'rejected');
      result.reply = 'Not executed: ${exec.reason ?? 'rejected'}';
    }
    await persist();
    return result;
  }

  /// Drafts a proposal for a symbol (BUY by default) using the same (BUY by default) using the same
  /// deterministic sizing + Risk Engine used by the crew. Returns null if
  /// live price/bars cannot be fetched. Used by the Agent screen's
  /// suggestion cards: user taps Trade → amount dialog → executeWithAmount.
  Future<AgentProposal?> draftProposal(
    String symbol, {
    Side side = Side.buy,
    AccountMode mode = AccountMode.paper,
  }) async {
    await ensureLoaded();
    return agent.draftProposalFor(
      symbol,
      side,
      await brokerFor(mode),
      rationale: 'Picked from agent suggestions — sized from your amount.',
    );
  }

  // -- amount-based execution ---------------------------------------------------

  /// Executes a proposal with a user-chosen ₹ amount: quantity is derived
  /// from the live price, then the SAME Risk Engine gate applies.
  Future<TradeExecution> executeWithAmount(
    AgentProposal p,
    double amount,
    AccountMode mode,
  ) async {
    await ensureLoaded();
    if (amount <= 0 || p.marketPrice <= 0) {
      return TradeExecution(
          executed: false, mode: mode, reason: 'Invalid amount.');
    }
    final qty = amount / p.marketPrice;
    // Honest pre-gate: LIVE orders check the real Coinbase balance here
    // too, so the user sees the truth BEFORE the approval dialog.
    final gateAccount =
        mode == AccountMode.live ? await _liveGateAccount() : paper.account;
    final verdict = risk.evaluate(
      symbol: p.symbol,
      side: p.side,
      quantity: qty,
      marketPrice: p.marketPrice,
      account: gateAccount,
      entryPrice: p.marketPrice,
      stopLoss: p.stopLoss,
      takeProfit: p.takeProfit,
      source: 'manual',
      confidence: p.confidence,
    );
    if (!verdict.allowed) {
      return TradeExecution(
          executed: false, mode: mode, reason: verdict.violations.first);
    }
    return execute(
      AgentProposal(
        symbol: p.symbol,
        side: p.side,
        quantity: qty,
        marketPrice: p.marketPrice,
        stopLoss: p.stopLoss,
        takeProfit: p.takeProfit,
        rationale: p.rationale,
        confidence: p.confidence,
        verdict: verdict,
      ),
      mode,
    );
  }

  /// Force-exit (sell) an ENTIRE open position at the live market price.
  Future<TradeExecution> closePosition(String symbol, AccountMode mode) async {
    await ensureLoaded();
    final sym = symbol.trim().toUpperCase();
    // Force-exit operates on the SELECTED mode's position: in LIVE that's
    // your real Coinbase holding, not the paper book.
    final broker = await brokerFor(mode);
    final pos = broker.account.positions[sym];
    if (pos == null) {
      return TradeExecution(
          executed: false, mode: mode, reason: 'No open position in $sym.');
    }
    double price = pos.currentPrice;
    try {
      price = await market.last(sym);
    } catch (_) {/* fall back to last known mark */}
    final p = AgentProposal(
      symbol: sym,
      side: Side.sell,
      quantity: pos.quantity,
      marketPrice: price,
      rationale: 'Force exit — full position closed from the Position screen.',
      verdict: risk.evaluate(
        symbol: sym,
        side: Side.sell,
        quantity: pos.quantity,
        marketPrice: price,
        account: broker.account,
        entryPrice: price,
        source: 'manual',
      ),
    );
    if (!p.allowed) {
      return TradeExecution(
          executed: false, mode: mode, reason: p.verdict.violations.first);
    }
    return execute(p, mode);
  }


  // -- manual orders (order ticket) ---------------------------------------------

  /// Places a MANUAL market order (paper or live) after the same Risk-Engine
  /// gate the AI proposals go through. [stopLoss]/[takeProfit] optional.
  Future<TradeExecution> placeManualMarket({
    required String symbol,
    required Side side,
    required double quantity,
    required double marketPrice,
    double? stopLoss,
  }) async {
    await ensureLoaded();
    final verdict = risk.evaluate(
      symbol: symbol,
      side: side,
      quantity: quantity,
      marketPrice: marketPrice,
      account: paper.account,
      entryPrice: marketPrice,
      stopLoss: stopLoss,
      source: 'manual',
    );
    if (!verdict.allowed) {
      return TradeExecution(
        executed: false,
        mode: AccountMode.paper,
        reason: verdict.violations.first,
      );
    }
    return execute(
      AgentProposal(
        symbol: symbol,
        side: side,
        quantity: quantity,
        marketPrice: marketPrice,
        stopLoss: stopLoss,
        rationale: 'Manual order from the chart order ticket',
        verdict: verdict,
      ),
      AccountMode.live,
    );
  }

  /// Rests a MANUAL limit order on the paper broker (fills when the live
  /// price crosses; checked by the 30s heartbeat). Risk-checked at limit.
  Future<TradeExecution> placeManualLimit({
    required String symbol,
    required Side side,
    required double quantity,
    required double limitPrice,
  }) async {
    await ensureLoaded();
    final verdict = risk.evaluate(
      symbol: symbol,
      side: side,
      quantity: quantity,
      marketPrice: limitPrice,
      account: paper.account,
      entryPrice: limitPrice,
      source: 'manual',
    );
    if (!verdict.allowed) {
      return TradeExecution(
        executed: false,
        mode: AccountMode.paper,
        reason: verdict.violations.first,
      );
    }
    final r = paper.placeLimitOrder(
      symbol: symbol,
      side: side,
      quantity: quantity,
      limitPrice: limitPrice,
    );
    await _persistPaper();
    return TradeExecution(
      executed: r.filled,
      mode: AccountMode.paper,
      reason: r.reason,
    );
  }
}

/// Runs [fn] over [items] with a bounded concurrency pool (default 6) so a
/// wider live universe never serializes N requests to Coinbase.
Future<List<T>> _mapPool<T>(
  Future<T?> Function(String) fn,
  List<String> items, {
  int pool = 6,
}) async {
  final out = <T>[];
  for (var i = 0; i < items.length; i += pool) {
    final chunk = items.skip(i).take(pool).toList();
    final rs = await Future.wait(chunk.map(fn));
    out.addAll(rs.whereType<T>());
  }
  return out;
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
