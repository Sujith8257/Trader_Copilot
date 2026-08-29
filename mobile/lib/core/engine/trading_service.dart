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
import '../models.dart';
import 'alerts.dart';
import 'coinbase_client.dart';
import 'paper_broker.dart';
import 'risk_engine.dart';

class Settings {
  Settings(
      {this.brain = const BrainConfig(),
      this.coinbaseKey = '',
      this.coinbaseSecret = ''});

  BrainConfig brain;
  String coinbaseKey;
  String coinbaseSecret;

  bool get coinbaseConfigured =>
      coinbaseKey.isNotEmpty && coinbaseSecret.isNotEmpty;
}

class TradeExecution {
  TradeExecution(
      {required this.executed, required this.mode, this.fillPrice, this.reason});
  final bool executed;
  final AccountMode mode;
  final double? fillPrice;
  final String? reason;
}

/// Result of one auto-refresh heartbeat.
class RefreshTick {
  RefreshTick({required this.alertsFired, required this.limitFills});
  final List<AlertRule> alertsFired;
  final List<(LimitOrder, double)> limitFills;
}

class TradingService {
  TradingService(
      {LiveCoinbaseMarket? marketClient,
      PaperBroker? paperBroker,
      RiskEngine? riskEngine}) {
    market = marketClient ?? LiveCoinbaseMarket();
    risk = riskEngine ?? RiskEngine();
    agent = TradingAgent(market: market, risk: risk);
    if (paperBroker != null) {
      _paper = paperBroker;
      _loaded = true; // injected broker: skip persistence hydration
    }
  }

  static TradingService? _instance;
  static TradingService get instance => _instance ??= TradingService();

  late LiveCoinbaseMarket market;
  late RiskEngine risk;
  late TradingAgent agent;
  late AlertEngine alerts = AlertEngine();
  PaperBroker? _paper;
  BrainConfig? _brain;
  Settings _settings = Settings();
  bool _loaded = false;

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
        ? PaperBroker.fromSnapshot(jsonDecode(paperJson) as Map<String, dynamic>)
        : PaperBroker(accountId: 'phone-paper');
    _paper!.rollDay(DateTime.now().toUtc());
    final brainJson = sp.getString(_prefBrain);
    _brain = brainJson != null
        ? BrainConfig.fromMap(jsonDecode(brainJson) as Map<String, dynamic>)
        : BrainConfig.defaults(BrainKind.rule);
    const secure = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true));
    _settings = Settings(
      brain: _brain!,
      coinbaseKey: await secure.read(key: 'coinbase_key') ?? '',
      coinbaseSecret: await secure.read(key: 'coinbase_secret') ?? '',
    );
    market.client
      ..apiKey = _settings.coinbaseKey
      ..privateKey = _settings.coinbaseSecret;
    _loaded = true;
  }

  Future<void> saveBrain(BrainConfig brain) async {
    _brain = brain;
    _settings = Settings(
        brain: brain,
        coinbaseKey: _settings.coinbaseKey,
        coinbaseSecret: _settings.coinbaseSecret);
    final sp = await SharedPreferences.getInstance();
    // the API key lives in secure storage only — never in prefs
    final safe = Map<String, dynamic>.from(brain.toMap());
    safe['api_key'] = '';
    await sp.setString(_prefBrain, jsonEncode(safe));
  }

  Future<void> saveCoinbaseCredentials(
      {required String key, required String secret}) async {
    const secure = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true));
    await secure.write(key: 'coinbase_key', value: key);
    await secure.write(key: 'coinbase_secret', value: secret);
    _settings = Settings(brain: brain, coinbaseKey: key, coinbaseSecret: secret);
    market.client
      ..apiKey = key
      ..privateKey = secret;
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
    for (final sym in market.symbols) {
      try {
        prices[sym] = await market.last(sym);
      } catch (_) {/* keep last known */}
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
    for (final sym in market.symbols) {
      try {
        prices[sym] = await market.last(sym);
      } catch (_) {}
    }
    return prices;
  }

  /// News headlines (DuckDuckGo, no API key) — powers the news card and the
  /// agent's web_search tool.
  Future<List<Map<String, String>>> news({String query = 'bitcoin ethereum'}) =>
      agent.toolWebSearch(query);

  // -- market data ---------------------------------------------------------

  Future<List<MarketRow>> marketOverview() async {
    final rows = <MarketRow>[];
    for (final sym in market.symbols) {
      try {
        final s = await agent.toolIndicators(sym);
        rows.add(MarketRow(
          symbol: sym,
          last: (s['last'] as num).toDouble(),
          changePct: (s['change_pct'] as num).toDouble(),
          rsi: (s['rsi'] as num?)?.toDouble(),
          trend: s['trend'] as String,
        ));
      } catch (_) {/* skip on fetch failure */}
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
    final accounts = await market.client.getAccounts();
    final fx = await market.usdInr();
    var cash = 0.0;
    final positions = <String, Position>{};
    for (final a in accounts) {
      final bal = double.tryParse(
              ((a['available_balance'] ?? {})['value'] ?? '0').toString()) ??
          0;
      if (bal <= 0) continue;
      final cur = (a['currency'] as String? ?? '').toUpperCase();
      if (cur == 'USD' || cur == 'USDC') {
        cash += bal * fx;
      } else if (cur == 'INR') {
        cash += bal;
      } else if (coinbaseProducts.contains(cur)) {
        double price = 0;
        try {
          price = await market.last(cur);
        } catch (_) {/* mark at 0 if fetch fails */}
        positions[cur] = Position(
            symbol: cur, quantity: bal, avgPrice: price, lastPrice: price);
      }
    }
    return AccountState(
      accountId: 'coinbase-live',
      mode: AccountMode.live,
      cash: cash,
      equity: cash +
          positions.values.fold(0.0, (s, p) => s + p.quantity * p.lastPrice),
      positions: positions,
    );
  }

  // -- execution ---------------------------------------------------------------

  /// Execute an approved proposal on the chosen mode. The Risk Engine is
  /// re-checked here — approval alone is never enough.
  Future<TradeExecution> execute(AgentProposal p, AccountMode mode) async {
    await ensureLoaded();
    final verdict = risk.evaluate(
      symbol: p.symbol,
      side: p.side,
      quantity: p.quantity,
      marketPrice: p.marketPrice,
      account: paper.account,
      entryPrice: p.marketPrice,
      stopLoss: p.stopLoss,
      takeProfit: p.takeProfit,
      source: 'ai',
      confidence: p.confidence,
    );
    if (!verdict.allowed) {
      return TradeExecution(
          executed: false, mode: mode, reason: verdict.violations.first);
    }
    if (mode == AccountMode.paper) {
      final result = paper.placeMarketOrder(
        symbol: p.symbol,
        side: p.side,
        quantity: p.quantity,
        marketPrice: p.marketPrice,
      );
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
          executed: false, mode: AccountMode.live,
          reason: 'Coinbase credentials not configured.');
    }
    try {
      final fx = await market.usdInr();
      final quote = p.quantity * p.marketPrice / fx; // INR -> USD
      final resp = p.side == Side.buy
          ? await market.client.marketOrder('${p.symbol}-USDC', 'BUY',
              quoteSize: quote.toStringAsFixed(2))
          : await market.client.marketOrder('${p.symbol}-USDC', 'SELL',
              baseSize: p.quantity.toStringAsFixed(8));
      final ok = resp['success'] == true;
      return TradeExecution(
        executed: ok,
        mode: AccountMode.live,
        fillPrice: ok ? p.marketPrice : null,
        reason: ok ? null : (resp['failure_reason']?.toString() ?? 'rejected'),
      );
    } on CoinbaseException catch (e) {
      return TradeExecution(
          executed: false, mode: AccountMode.live, reason: e.message);
    }
  }

  // -- agentic crew -------------------------------------------------------------

  Future<AgentRunResult> runCrew(
    String goal, {
    void Function(AgentStep)? onStep,
  }) async {
    await ensureLoaded();
    return agent.runGoal(goal, broker: paper, brain: brain, onStep: onStep);
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
          executed: false, mode: AccountMode.paper, reason: verdict.violations.first);
    }
    return execute(AgentProposal(
      symbol: symbol,
      side: side,
      quantity: quantity,
      marketPrice: marketPrice,
      stopLoss: stopLoss,
      rationale: 'Manual order from the chart order ticket',
      verdict: verdict,
    ), AccountMode.live);
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
          executed: false, mode: AccountMode.paper, reason: verdict.violations.first);
    }
    final r = paper.placeLimitOrder(
        symbol: symbol, side: side, quantity: quantity, limitPrice: limitPrice);
    await _persistPaper();
    return TradeExecution(
        executed: r.filled, mode: AccountMode.paper, reason: r.reason);
  }
}
