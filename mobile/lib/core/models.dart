/// Shared domain models — mirrors of `backend/app/core/models.py`.
/// The on-device AI can only ever produce a [TradeProposal]; execution
/// decisions come back from the deterministic Risk Engine as [RiskVerdict].
library;

enum Side { buy, sell }

extension SideX on Side {
  String get wire => name.toUpperCase();
  static Side fromWire(String v) =>
      v.toUpperCase() == 'SELL' ? Side.sell : Side.buy;
}

enum AccountMode { paper, live }

extension AccountModeX on AccountMode {
  String get wire => name.toUpperCase();
  static AccountMode fromWire(String v) =>
      v.toUpperCase() == "LIVE" ? AccountMode.live : AccountMode.paper;
}

/// Which market the app is looking at. NSE follows IST market hours;
/// crypto paper-trades 24/7 - even on weekends.
enum Market { stocks, crypto }

extension MarketX on Market {
  String get wire => name;
  String get label => this == Market.crypto ? "Crypto" : "Stocks";
}

class Position {
  Position({
    required this.symbol,
    required this.quantity,
    required this.avgPrice,
    required this.lastPrice,
  });

  final String symbol;
  final double quantity;
  final double avgPrice;
  final double lastPrice;

  double get marketValue => quantity * lastPrice;
  double get unrealizedPnl => (lastPrice - avgPrice) * quantity;

  factory Position.fromJson(String symbol, Map<String, dynamic> j) => Position(
        symbol: symbol,
        quantity: (j['qty'] as num).toDouble(),
        avgPrice: (j['avg'] as num).toDouble(),
        lastPrice: (j['last'] as num).toDouble(),
      );
}

class AccountState {
  AccountState({
    required this.accountId,
    required this.mode,
    required this.cash,
    required this.equity,
    this.dayStart,
    required this.positions,
  });

  final String accountId;
  final AccountMode mode;
  final double cash;
  final double equity;
  final double? dayStart;
  final Map<String, Position> positions;

  /// Sum of open-position market values (exposure).
  double get grossExposure =>
      positions.values.fold(0.0, (s, p) => s + p.marketValue);

  factory AccountState.fromJson(Map<String, dynamic> j) => AccountState(
        accountId: j['account_id'] as String,
        mode: AccountModeX.fromWire(j['mode'] as String? ?? 'PAPER'),
        cash: (j['cash'] as num).toDouble(),
        equity: (j['equity'] as num).toDouble(),
        dayStart: (j['day_start_equity'] as num?)?.toDouble(),
        positions: {
          for (final e in (j['positions'] as Map<String, dynamic>).entries)
            e.key: Position.fromJson(e.key, e.value),
        },
      );
}

/// The ONLY output surface an AI model is allowed to produce.
class TradeProposal {
  TradeProposal({
    required this.symbol,
    required this.side,
    required this.quantity,
    this.entryPrice,
    this.stopLoss,
    this.takeProfit,
    this.rationale = '',
    this.confidence,
    this.source = 'ai',
  });

  final String symbol;
  final Side side;
  final double quantity;
  final double? entryPrice;
  final double? stopLoss;
  final double? takeProfit;
  final String rationale;
  final double? confidence;
  final String source;

  double? get riskReward {
    if (side != Side.buy || entryPrice == null) return null;
    final risk = entryPrice! - (stopLoss ?? 0);
    final reward = (takeProfit ?? 0) - entryPrice!;
    if (risk <= 0 || reward <= 0) return null;
    return reward / risk;
  }
}

/// Deterministic Risk Engine result — with human-readable reasons.
class RiskVerdict {
  RiskVerdict({
    required this.allowed,
    required this.violations,
    required this.warnings,
  });

  final bool allowed;
  final List<String> violations;
  final List<String> warnings;

  factory RiskVerdict.fromJson(Map<String, dynamic> j) => RiskVerdict(
        allowed: j['allowed'] as bool,
        violations:
            (j['violations'] as List? ?? []).cast<String>().toList(),
        warnings: (j['warnings'] as List? ?? []).cast<String>().toList(),
      );
}

class ExecutedTrade {
  ExecutedTrade({
    required this.symbol,
    required this.side,
    required this.quantity,
    required this.filledPrice,
    required this.at,
  });

  final String symbol;
  final Side side;
  final double quantity;
  final double filledPrice;
  final DateTime at;

  double get notional => quantity * filledPrice;
}

class OrderResult {
  OrderResult({
    required this.orderId,
    required this.status,
    this.filledPrice,
  });

  final String orderId;
  final String status;
  final double? filledPrice;

  bool get filled => status.toUpperCase() == 'FILLED';

  factory OrderResult.fromJson(Map<String, dynamic> j) => OrderResult(
        orderId: j['order_id'] as String,
        status: j['status'] as String,
        filledPrice: (j['filled_price'] as num?)?.toDouble(),
      );
}

// ---------------------------------------------------------------------------
// Agentic Copilot models — the chat agent returns a visible tool trace plus,
// at most, a proposal DRAFT (never an execution).
// ---------------------------------------------------------------------------

class AgentStep {
  AgentStep({required this.tool, required this.detail});

  final String tool;
  final String detail;

  factory AgentStep.fromJson(Map<String, dynamic> j) => AgentStep(
        tool: j['tool'] as String,
        detail: j['detail'] as String,
      );
}

class Opportunity {
  Opportunity({
    required this.symbol,
    required this.last,
    required this.changePct,
    required this.rsi,
    required this.trend,
    required this.score,
    required this.reasons,
    required this.stop,
    required this.target,
  });

  final String symbol;
  final double last;
  final double changePct;
  final double? rsi;
  final String trend;
  final double score;
  final List<String> reasons;
  final double stop;
  final double target;

  factory Opportunity.fromJson(Map<String, dynamic> j) => Opportunity(
        symbol: j['symbol'] as String,
        last: (j['last'] as num).toDouble(),
        changePct: (j['change_pct'] as num).toDouble(),
        rsi: (j['rsi'] as num?)?.toDouble(),
        trend: j['trend'] as String,
        score: (j['score'] as num).toDouble(),
        reasons: (j['reasons'] as List? ?? []).cast<String>(),
        stop: (j['stop'] as num).toDouble(),
        target: (j['target'] as num).toDouble(),
      );
}

class AgentReply {
  AgentReply({
    required this.brain,
    required this.reply,
    required this.steps,
    this.proposal,
    this.verdict,
    this.opportunities = const [],
  });

  final String brain; // "local" | "llm"
  final String reply;
  final List<AgentStep> steps;
  final TradeProposal? proposal;
  final RiskVerdict? verdict;
  final List<Opportunity> opportunities;

  bool get hasDraft => proposal != null && verdict != null;

  factory AgentReply.fromJson(Map<String, dynamic> j) {
    final p = j['proposal'] as Map<String, dynamic>?;
    final v = j['verdict'] as Map<String, dynamic>?;
    return AgentReply(
      brain: (j['brain'] as String?) ?? 'local',
      reply: (j['reply'] as String?) ?? '',
      steps: (j['steps'] as List? ?? [])
          .map((s) => AgentStep.fromJson(s as Map<String, dynamic>))
          .toList(),
      proposal: p == null
          ? null
          : TradeProposal(
              symbol: p['symbol'] as String,
              side: SideX.fromWire(p['side'] as String? ?? 'BUY'),
              quantity: (p['quantity'] as num).toDouble(),
              entryPrice: (p['entry_price'] as num?)?.toDouble(),
              stopLoss: (p['stop_loss'] as num?)?.toDouble(),
              takeProfit: (p['take_profit'] as num?)?.toDouble(),
              rationale: (p['rationale'] as String?) ?? '',
              confidence: (p['confidence'] as num?)?.toDouble(),
              source: 'ai',
            ),
      verdict: v == null ? null : RiskVerdict.fromJson(v),
      opportunities: (j['opportunities'] as List? ?? [])
          .map((o) => Opportunity.fromJson(o as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// One row of the market overview (the AI Radar on the dashboard).
class MarketRow {
  MarketRow({
    required this.symbol,
    required this.last,
    required this.changePct,
    required this.rsi,
    required this.trend,
  });

  final String symbol;
  final double last;
  final double changePct;
  final double? rsi;
  final String trend;

  factory MarketRow.fromJson(Map<String, dynamic> j) => MarketRow(
        symbol: j['symbol'] as String,
        last: (j['last'] as num).toDouble(),
        changePct: (j['change_pct'] as num).toDouble(),
        rsi: (j['rsi'] as num?)?.toDouble(),
        trend: j['trend'] as String,
      );
}

/// One point of the account equity curve.
class EquityPoint {
  EquityPoint({required this.t, required this.equity});

  final DateTime t;
  final double equity;

  factory EquityPoint.fromJson(Map<String, dynamic> j) => EquityPoint(
        t: DateTime.parse(j['t'] as String),
        equity: (j['equity'] as num).toDouble(),
      );
}
