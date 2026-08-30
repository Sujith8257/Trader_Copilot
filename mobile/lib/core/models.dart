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

/// Deterministic Risk Engine result lives in `core/engine/risk_engine.dart`
/// (mutable, with block()/warn()). Kept out of this file to avoid shadowing.

class ExecutedTrade {
  ExecutedTrade({
    required this.symbol,
    required this.side,
    required this.quantity,
    required this.filledPrice,
    required this.at,
    this.mode = 'paper',
    this.source = 'manual',
  });

  final String symbol;
  final Side side;
  final double quantity;
  final double filledPrice;
  final DateTime at;

  /// Where the fill happened: 'paper' | 'live'. Real provenance, not
  /// decoration - the journal must say which account the fill hit.
  final String mode;

  /// What initiated it: 'manual' | 'agent' | 'agent-idea' | 'autopilot'
  /// | 'exit'.
  final String source;

  double get notional => quantity * filledPrice;
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

/// One OHLCV bar (candlestick). For the crypto market these are LIVE
/// Coinbase daily candles converted to INR.
class Candle {
  Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume,
  });

  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double? volume;

  bool get bullish => close >= open;

  factory Candle.fromJson(Map<String, dynamic> j) {
    final start = j['start'];
    final t = start is String
        ? DateTime.fromMillisecondsSinceEpoch(int.parse(start) * 1000)
        : DateTime.now();
    return Candle(
      time: t,
      open: (j['o'] as num).toDouble(),
      high: (j['h'] as num).toDouble(),
      low: (j['l'] as num).toDouble(),
      close: (j['c'] as num).toDouble(),
      volume: (j['v'] as num?)?.toDouble(),
    );
  }
}

/// Response of GET /market/candles/{symbol} — bars + data provenance.
class CandleSeries {
  CandleSeries({
    required this.symbol,
    required this.market,
    required this.source,
    required this.bars,
  });

  final String symbol;
  final Market market;
  final String source;
  final List<Candle> bars;

  double get minLow => bars.map((b) => b.low).reduce((a, b) => a < b ? a : b);
  double get maxHigh => bars.map((b) => b.high).reduce((a, b) => a > b ? a : b);

  factory CandleSeries.fromJson(Map<String, dynamic> j) => CandleSeries(
    symbol: j['symbol'] as String,
    market: (j['market'] as String? ?? 'stocks') == 'crypto'
        ? Market.crypto
        : Market.stocks,
    source: j['source'] as String? ?? 'unknown',
    bars: (j['bars'] as List? ?? [])
        .map((b) => Candle.fromJson(b as Map<String, dynamic>))
        .toList(),
  );
}
