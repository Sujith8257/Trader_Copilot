/// The agentic trading crew — fully on-phone. An orchestrator runs multiple
/// roles (Scanner → Analyst → Strategist → Drafter) over a tool registry,
/// with LIVE Coinbase data tools and web search. The LLM (your Termux
/// Qwen, Gemini, Groq…) only ever THINKS; every tool executes in Dart and
/// every trade is gated by the deterministic Risk Engine + your approval.
///
/// Rule-brain fallback: identical pipeline without any LLM, so the app is
/// fully agentic even fully offline.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../engine/coinbase_client.dart';
import '../engine/indicators.dart';
import '../engine/paper_broker.dart';
import '../engine/risk_engine.dart';
import '../models.dart';
import 'llm_client.dart';

class AgentStep {
  AgentStep({required this.agent, required this.tool, required this.detail})
    : ts = DateTime.now();

  final String agent; // scanner | analyst | strategist | drafter | system
  final String tool; // scan_market | web_search | ... | thought
  final String detail;
  final DateTime ts;

  Map<String, String> toMap() => {
    'agent': agent,
    'tool': tool,
    'detail': detail,
  };
}

/// A proactive trade idea: the crew scanned the live market on its own and
/// picked this product. The user taps Trade → enters an amount → the Risk
/// Engine sizes and gates the order before anything executes.
class AgentSuggestion {
  AgentSuggestion({
    required this.symbol,
    required this.price,
    required this.rsi,
    required this.trend,
    required this.score,
    required this.changePct,
  });

  final String symbol;
  final double price;
  final double? rsi;
  final String trend; // UP | DOWN | FLAT
  final double score;
  final double changePct;

  Map<String, dynamic> toMap() => {
        'symbol': symbol,
        'price': price,
        'rsi': rsi,
        'trend': trend,
        'score': score,
        'change_pct': changePct,
      };
}

class AgentProposal {
  AgentProposal({
    required this.symbol,
    required this.side,
    required this.quantity,
    required this.marketPrice,
    this.stopLoss,
    this.takeProfit,
    required this.rationale,
    this.confidence,
    required this.verdict,
  });

  final String symbol;
  final Side side;
  final double quantity;
  final double marketPrice;
  final double? stopLoss;
  final double? takeProfit;
  final String rationale;
  final double? confidence;
  final RiskVerdict verdict;

  bool get allowed => verdict.allowed;

  Map<String, dynamic> toMap() => {
    'symbol': symbol,
    'side': side.wire,
    'quantity': quantity,
    'market_price': marketPrice,
    'stop_loss': stopLoss,
    'take_profit': takeProfit,
    'rationale': rationale,
    'confidence': confidence,
    'verdict': verdict.toMap(),
  };
}

class AgentRunResult {
  AgentRunResult({required this.goal});
  final String goal;
  final List<AgentStep> steps = [];
  final List<AgentProposal> proposals = [];
  final List<AgentSuggestion> suggestions = [];
  double? suggestedAmount; // ₹ amount the user mentioned in the goal, if any
  String reply = '';
  String brain = 'rule';

  void step(String agent, String tool, String detail) =>
      steps.add(AgentStep(agent: agent, tool: tool, detail: detail));
}

class TradingAgent {
  TradingAgent({
    required this.market,
    required this.risk,
    LlmClient? llm,
    http.Client? httpClient,
  }) : llmClient = llm ?? LlmClient(),
       _http = httpClient ?? http.Client();

  final LiveCoinbaseMarket market;
  final RiskEngine risk;
  final LlmClient llmClient;
  final http.Client _http;

  /// Run the full crew for a goal. [broker] and [brain] come from the
  /// trading service each run (they can change between runs).
  Future<AgentRunResult> runGoal(
    String goal, {
    required PaperBroker broker,
    required BrainConfig brain,
    void Function(AgentStep)? onStep,
  }) async {
    final res = AgentRunResult(goal: goal);

    // Suggestion intent: "suggest me a good position", "I want to invest
    // ₹5000", "any ideas?" — the crew proactively picks 5-6 cryptos and the
    // user trades any of them with one tap (amount asked in the UI).
    if (_wantsSuggestions(goal)) {
      res.suggestedAmount = _extractAmount(goal);
      await _runSuggestions(res);
      res.brain = 'rule';
      return res;
    }

    if (brain.isLlm) {
      try {
        await _runLlmCrew(goal, broker, brain, res, onStep);
        res.brain = brain.kind.name;
        if (res.reply.isEmpty) {
          res.reply = res.proposals.isEmpty
              ? 'The crew found no setup worth trading right now. '
                    'Patience is a position.'
              : 'Proposals are drafted below — the Risk Engine already '
                    'checked them. Review and approve.';
        }
        return res;
      } on LlmException catch (e) {
        res.step(
          'system',
          'fallback',
          'LLM brain unavailable (${e.message}) — using the rule brain.',
        );
      }
    }
    _runRuleBrain(broker, res);
    res.brain = 'rule';
    return res;
  }

  // ------------------------------------------------------------------ //
  // Tools — executed in Dart, results fed to the LLM                    //
  // ------------------------------------------------------------------ //

  Future<List<Map<String, dynamic>>> toolScanMarket() async {
    final rows = <Map<String, dynamic>>[];
    for (final sym in market.symbols) {
      try {
        final s = snapshot(await market.bars(sym));
        final trendScore = s['trend'] == 'UP' ? 1.0 : -0.5;
        final r = s['rsi'] as double?;
        final rsiScore = r == null
            ? 0.0
            : (r < 30 ? 1.0 : (r > 70 ? -1.0 : 0.3));
        final mom = ((s['change_pct'] as num).toDouble() / 5).clamp(-1.5, 1.5);
        rows.add({'symbol': sym, 'score': trendScore + rsiScore + mom, ...s});
      } catch (_) {
        /* skip symbol on fetch failure */
      }
    }
    rows.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    return rows;
  }

  Future<Map<String, dynamic>> toolIndicators(String symbol) async {
    final bars = await market.bars(symbol);
    final s = snapshot(bars);
    final closes = bars.map((b) => b.close).toList();
    final recent = closes.length > 14
        ? closes.sublist(closes.length - 14)
        : closes;
    return {
      'symbol': symbol.toUpperCase(),
      ...s,
      'recent_14_closes': [for (final c in recent) _round2(c)],
    };
  }

  Map<String, dynamic> toolAccount(PaperBroker broker) {
    final a = broker.account;
    return {
      'cash': _round2(a.cash),
      'equity': _round2(a.equity),
      'day_start': _round2(a.dayStart),
      'realized_pnl_today': _round2(a.realizedPnlToday),
      'trades_today': a.tradesToday,
      'positions': [
        for (final p in a.positions.values)
          {
            'symbol': p.symbol,
            'qty': p.quantity,
            'avg': _round2(p.avgPrice),
            'last': _round2(p.currentPrice),
            'unrealized_pnl': _round2(p.unrealizedPnl),
          },
      ],
    };
  }

  /// Web search via DuckDuckGo Lite (no API key). Compact headlines the
  /// analyst can weigh.
  Future<List<Map<String, String>>> toolWebSearch(
    String query, {
    int max = 6,
  }) async {
    final uri = Uri.parse(
      'https://lite.duckduckgo.com/lite/?q=${Uri.encodeQueryComponent('$query crypto market news')}',
    );
    try {
      final r = await _http
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0 (compatible)'})
          .timeout(const Duration(seconds: 15));
      String strip(String h) => h
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#x27;', "'")
          .trim();
      final results = <Map<String, String>>[];
      final links = RegExp(r'<a[^>]+class="result-link"[^>]*>([\s\S]*?)</a>')
          .allMatches(r.body)
          .toList();
      final snips = RegExp(r'class="result-snippet"[^>]*>([\s\S]*?)</td>')
          .allMatches(r.body)
          .toList();
      for (var i = 0; i < links.length && results.length < max; i++) {
        final title = strip(links[i].group(1) ?? '');
        if (title.isEmpty) continue;
        results.add({
          'title': title,
          'snippet': i < snips.length ? strip(snips[i].group(1) ?? '') : '',
        });
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------------ //
  // The LLM crew: Scanner → Analyst → Strategist → Drafter              //
  // ------------------------------------------------------------------ //

  Future<void> _runLlmCrew(
    String goal,
    PaperBroker broker,
    BrainConfig brain,
    AgentRunResult res,
    void Function(AgentStep)? onStep,
  ) async {
    void emit(String agent, String tool, String detail) {
      res.step(agent, tool, detail);
      onStep?.call(res.steps.last);
    }

    // -- Scanner ---------------------------------------------------------
    emit(
      'scanner',
      'scan_market',
      'Scoring all ${market.symbols.length} Coinbase products…',
    );
    final scan = await toolScanMarket();
    final top = scan.take(4).toList();
    for (final t in top) {
      emit(
        'scanner',
        'indicators',
        '${t['symbol']}: ₹${_round2(t['last'] as double)} · RSI ${t['rsi']} · '
            'trend ${t['trend']} · score ${(t['score'] as double).toStringAsFixed(2)}',
      );
    }
    emit('scanner', 'web_search', 'Checking the news flow…');
    final news = await toolWebSearch('bitcoin ethereum solana market');
    for (final n in news.take(3)) {
      emit('scanner', 'web_search', n['title'] ?? '');
    }

    final scanCtx = jsonEncode({
      'goal': goal,
      'top_candidates': top,
      'headlines': news,
    });

    // -- Analyst -----------------------------------------------------------
    emit('analyst', 'get_indicators', 'Deep-diving the top candidates…');
    final analyses = <Map<String, dynamic>>[];
    for (final c in top.take(2)) {
      final sym = c['symbol'] as String;
      final ind = await toolIndicators(sym);
      analyses.add(ind);
      emit(
        'analyst',
        'indicators',
        '$sym: trend ${ind['trend']}, RSI ${ind['rsi']}, '
            'MACD hist ${ind['macd_hist']}, ATR ${ind['atr']}',
      );
    }

    // -- Strategist ----------------------------------------------------------
    emit(
      'strategist',
      'get_account',
      'Balancing decisions against the portfolio…',
    );
    final account = toolAccount(broker);

    final system = ChatMessage.system(
      'You are a disciplined crypto trading crew. Respond ONLY with valid JSON, '
      'no prose. You NEVER execute trades; you only decide. Rules: '
      'max 2 new positions; never fight the trend blindly; RSI>70 = overbought, '
      'RSI<30 = oversold; prefer EMA20>EMA50 (UP) for buys; respect the goal; '
      'if nothing meets the bar, return an empty list — patience is valid.',
    );

    final decRaw = await llmClient.chat([
      system,
      ChatMessage.user(
        'GOAL: $goal\n\nMARKET SCAN: $scanCtx\n\nINDICATORS: '
        '${jsonEncode(analyses)}\n\nACCOUNT: ${jsonEncode(account)}\n\n'
        'Decide trades. Respond JSON: {"decisions":[{"symbol":"BTC",'
        '"side":"BUY"|"SELL"|"WAIT","conviction":0.0-1.0,"rationale":"..."}]} '
        'Use SELL only for symbols in ACCOUNT positions.',
      ),
    ], brain: brain);
    final decisions =
        (LlmClient.extractJson(decRaw)?['decisions'] as List? ?? [])
            .cast<Map<String, dynamic>>();
    for (final d in decisions) {
      emit(
        'strategist',
        'thought',
        '${d['symbol']}: ${d['side']} (conviction ${d['conviction']}) — ${d['rationale']}',
      );
    }

    // -- Drafter (deterministic sizing + Risk Engine) --------------------------
    emit(
      'drafter',
      'risk_engine',
      'Drafting proposals and running risk checks…',
    );
    for (final d in decisions) {
      final sym = (d['symbol'] as String? ?? '').toUpperCase();
      final sideStr = (d['side'] as String? ?? 'WAIT').toUpperCase();
      if (sym.isEmpty || sideStr == 'WAIT') continue;
      final side = sideStr == 'SELL' ? Side.sell : Side.buy;
      final p = await _draftProposalAsync(
        sym,
        side,
        broker,
        rationale: (d['rationale'] as String?) ?? '',
        confidence: (d['conviction'] as num?)?.toDouble(),
      );
      if (p != null) {
        res.proposals.add(p);
        emit(
          'drafter',
          'proposal',
          '${side.wire} ${p.quantity} $sym @ ₹${_round2(p.marketPrice)} — '
              'risk: ${p.allowed ? "ALLOWED" : "BLOCKED"}',
        );
      }
    }
    if (res.proposals.isEmpty && res.reply.isEmpty) {
      res.reply = 'The crew decided to stand down — no setup met the bar.';
    }
  }

  /// Deterministic proposal drafting: position sizing from the risk config,
  /// ATR-based stop/target, then the Risk Engine verdict. Used by the LLM
  /// crew AND the rule brain — sizing is never left to the model.
  /// Public: the Agent screen uses it to draft a proposal when the user
  /// taps Trade on a proactive suggestion.
  Future<AgentProposal?> draftProposalFor(
    String symbol,
    Side side,
    PaperBroker broker, {
    required String rationale,
    double? confidence,
  }) => _draftProposalAsync(
        symbol,
        side,
        broker,
        rationale: rationale,
        confidence: confidence,
      );

  // ------------------------------------------------------------------ //
  // Suggestion mode — "hey, find me a good position"                    //
  // ------------------------------------------------------------------ //

  static final RegExp _amountRe = RegExp(r'([\d][\d,]{2,}(?:\.\d+)?)');

  static bool _wantsSuggestions(String goal) {
    final g = goal.toLowerCase();
    const kw = [
      'suggest', 'recommend', 'good position', 'opportunit', 'idea',
      'what should i', 'invest', 'deploy', 'picks', 'best coin',
      'what to buy', 'good trade',
    ];
    if (kw.any(g.contains)) return true;
    // an explicit amount with trade-ish words: "i have 5000 for trading"
    return _amountRe.hasMatch(g) &&
        RegExp(r'(trade|position|amount|buy|market)').hasMatch(g);
  }

  static double? _extractAmount(String goal) {
    final m = _amountRe.firstMatch(goal);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!.replaceAll(',', ''));
    return (v != null && v >= 100) ? v : null;
  }

  Future<void> _runSuggestions(AgentRunResult res) async {
    res.step(
      'scanner',
      'scan_market',
      'Scoring all ${market.symbols.length} live Coinbase products for '
          'trade ideas…',
    );
    final scan = await toolScanMarket();
    if (scan.isEmpty) {
      res.reply = 'Could not reach live market data — check your internet '
          'and try again.';
      return;
    }
    // Prefer uptrends, but always fill 5-6 cards so the user has choice.
    final up = scan.where((r) => r['trend'] == 'UP').toList();
    final picks = (up.length >= 5 ? up : [
      ...up,
      ...scan.where((r) => r['trend'] != 'UP'),
    ]).take(6).toList();

    res.step(
      'strategist',
      'thought',
      'Picked the top ${picks.length} scored products — user picks one, '
          'the Risk Engine sizes the order from their amount.',
    );
    for (final t in picks) {
      final s = AgentSuggestion(
        symbol: t['symbol'] as String,
        price: (t['last'] as num).toDouble(),
        rsi: (t['rsi'] as num?)?.toDouble(),
        trend: t['trend'] as String? ?? 'FLAT',
        score: (t['score'] as num).toDouble(),
        changePct: (t['change_pct'] as num?)?.toDouble() ?? 0,
      );
      res.suggestions.add(s);
      res.step(
        'scanner',
        'idea',
        '${s.symbol}: ₹${_round2(s.price)} · trend ${s.trend} · '
            'RSI ${s.rsi?.toStringAsFixed(0) ?? '-'} · '
            'score ${s.score.toStringAsFixed(2)}',
      );
    }
    final amt = res.suggestedAmount;
    res.reply = amt != null
        ? 'Here are my top ${res.suggestions.length} ideas for your '
            '₹${_round2(amt)} — tap TRADE on one and I will size the order '
            'from your amount and run the Risk Engine before executing.'
        : 'Here are my top ${res.suggestions.length} ideas right now — '
            'tap TRADE on one, enter how much you want to put in, and the '
            'Risk Engine will size and check the order.';
  }

  Future<AgentProposal?> _draftProposalAsync(
    String symbol,
    Side side,
    PaperBroker broker, {
    required String rationale,
    double? confidence,
  }) async {
    final sym = symbol.toUpperCase();
    double price;
    List<Candle> bars;
    try {
      price = await market.last(sym);
      bars = await market.bars(sym);
    } catch (_) {
      return null;
    }
    final acct = broker.account;
    double? stop;
    double? target;
    final a = atr(
      bars.map((b) => b.high).toList(),
      bars.map((b) => b.low).toList(),
      bars.map((b) => b.close).toList(),
    );
    if (a != null && a > 0) {
      stop = price - 2 * a;
      target = price + 3 * a;
    }
    double qty;
    if (side == Side.buy) {
      final notional = acct.cash < risk.config.maxPositionNotional
          ? acct.cash * 0.9
          : risk.config.maxPositionNotional;
      qty = notional / price;
      if (qty <= 0 || qty * price > acct.cash) {
        return null;
      }
    } else {
      final pos = acct.positions[sym];
      if (pos == null) return null;
      qty = pos.quantity; // exit the full position
    }
    final verdict = risk.evaluate(
      symbol: sym,
      side: side,
      quantity: qty,
      marketPrice: price,
      account: acct,
      entryPrice: price,
      stopLoss: side == Side.buy ? stop : null,
      takeProfit: side == Side.buy ? target : null,
      confidence: confidence,
    );
    return AgentProposal(
      symbol: sym,
      side: side,
      quantity: qty,
      marketPrice: price,
      stopLoss: side == Side.buy ? stop : null,
      takeProfit: side == Side.buy ? target : null,
      rationale: rationale,
      confidence: confidence,
      verdict: verdict,
    );
  }

  // ------------------------------------------------------------------ //
  // Rule brain — the full pipeline with zero LLM calls (offline mode)   //
  // ------------------------------------------------------------------ //

  Future<void> _runRuleBrain(PaperBroker broker, AgentRunResult res) async {
    res.step(
      'scanner',
      'scan_market',
      'Scoring all ${market.symbols.length} Coinbase products…',
    );
    final scan = await toolScanMarket();
    for (final t in scan.take(3)) {
      res.step(
        'scanner',
        'indicators',
        '${t['symbol']}: ₹${_round2(t['last'] as double)} · RSI ${t['rsi']} · '
            'trend ${t['trend']} · score ${(t['score'] as double).toStringAsFixed(2)}',
      );
    }
    if (scan.isEmpty) {
      res.reply = 'Could not reach live market data. Check your internet.';
      return;
    }

    res.step(
      'strategist',
      'thought',
      'Rule brain: follow the top-scoring trend if we do not already hold it.',
    );
    final top = scan.first;
    final sym = top['symbol'] as String;
    final rsi = top['rsi'] as double?;
    final held = broker.account.positions[sym];
    if (held != null && (top['trend'] == 'DOWN' || (rsi != null && rsi > 70))) {
      final p = await _draftProposalAsync(
        sym,
        Side.sell,
        broker,
        rationale:
            'Rule exit: $sym trend ${top['trend']}, RSI ${rsi ?? '-'} — '
            'protecting gains.',
      );
      if (p != null) {
        res.proposals.add(p);
        res.step(
          'drafter',
          'proposal',
          'SELL ${p.quantity} $sym — risk: ${p.allowed ? "ALLOWED" : "BLOCKED"}',
        );
      }
    } else if (held == null &&
        top['trend'] == 'UP' &&
        (rsi == null || rsi < 70)) {
      final p = await _draftProposalAsync(
        sym,
        Side.buy,
        broker,
        rationale:
            'Rule entry: $sym is the top-scoring product '
            '(trend UP, RSI ${rsi ?? '-'}, '
            'score ${(top['score'] as double).toStringAsFixed(2)}).',
      );
      if (p != null) {
        res.proposals.add(p);
        res.step(
          'drafter',
          'proposal',
          'BUY ${p.quantity} $sym @ ₹${_round2(p.marketPrice)} — '
              'risk: ${p.allowed ? "ALLOWED" : "BLOCKED"}',
        );
      }
    }
    res.reply = res.proposals.isEmpty
        ? 'Rule brain: no entry met the filters (need UP trend + RSI<70, '
              'or an exit trigger on a held position).'
        : 'Rule brain drafted ${res.proposals.length} proposal(s) — '
              'review and approve below.';
  }
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
