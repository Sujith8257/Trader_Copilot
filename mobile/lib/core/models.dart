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
      v.toUpperCase() == 'LIVE' ? AccountMode.live : AccountMode.paper;
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
    required this.positions,
  });

  final String accountId;
  final AccountMode mode;
  final double cash;
  final double equity;
  final Map<String, Position> positions;

  factory AccountState.fromJson(Map<String, dynamic> j) => AccountState(
        accountId: j['account_id'] as String,
        mode: AccountModeX.fromWire(j['mode'] as String? ?? 'PAPER'),
        cash: (j['cash'] as num).toDouble(),
        equity: (j['equity'] as num).toDouble(),
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
