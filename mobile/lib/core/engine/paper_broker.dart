/// PaperBroker — simulated fills against virtual cash at REAL market prices.
/// Port of `backend/app/core/brokers/paper.py`. Same surface the live
/// Coinbase broker uses, so the agent + Risk Engine never know or care
/// which one is behind a fill.
library;

import '../models.dart';

class EnginePosition {
  EnginePosition({
    required this.symbol,
    required this.quantity,
    required this.avgPrice,
    this.currentPrice = 0,
  });

  final String symbol;
  double quantity;
  double avgPrice;
  double currentPrice;

  double get marketValue => quantity * currentPrice;
  double get unrealizedPnl => (currentPrice - avgPrice) * quantity;

  Map<String, dynamic> toMap() => {
        'symbol': symbol,
        'quantity': quantity,
        'avg_price': avgPrice,
        'current_price': currentPrice,
      };

  static EnginePosition fromMap(Map<String, dynamic> m) => EnginePosition(
        symbol: m['symbol'] as String,
        quantity: (m['quantity'] as num).toDouble(),
        avgPrice: (m['avg_price'] as num).toDouble(),
        currentPrice: (m['current_price'] as num?)?.toDouble() ?? 0,
      );
}

/// Engine-side account: cash + positions + intraday counters + equity curve.
class EngineAccount {
  EngineAccount({
    required this.accountId,
    this.cash = 0,
    this.dayStart = 0,
    this.realizedPnlToday = 0,
    this.tradesToday = 0,
    Map<String, EnginePosition>? positions,
    List<Map<String, dynamic>>? equityHistory,
  })  : positions = positions ?? {},
        equityHistory = equityHistory ?? [];

  final String accountId;
  double cash;
  double dayStart;
  double realizedPnlToday;
  int tradesToday;
  final Map<String, EnginePosition> positions;
  final List<Map<String, dynamic>> equityHistory;

  double get equity =>
      cash + positions.values.fold(0.0, (s, p) => s + p.marketValue);
  double get grossExposure =>
      positions.values.fold(0.0, (s, p) => s + p.marketValue);

  void mark(String symbol, double price) {
    positions[symbol]?.currentPrice = price;
  }

  void markAll(Map<String, double> prices) {
    prices.forEach(mark);
  }

  void pushEquityPoint(DateTime t) {
    equityHistory.add({'t': t.toIso8601String(), 'equity': equity});
  }

  Map<String, dynamic> toMap() => {
        'account_id': accountId,
        'cash': cash,
        'day_start': dayStart,
        'realized_pnl_today': realizedPnlToday,
        'trades_today': tradesToday,
        'positions': [for (final p in positions.values) p.toMap()],
        'equity_history': equityHistory,
      };

  static EngineAccount fromMap(Map<String, dynamic> m) => EngineAccount(
        accountId: m['account_id'] as String,
        cash: (m['cash'] as num).toDouble(),
        dayStart: (m['day_start'] as num?)?.toDouble() ?? 0,
        realizedPnlToday: (m['realized_pnl_today'] as num?)?.toDouble() ?? 0,
        tradesToday: (m['trades_today'] as num?)?.toInt() ?? 0,
        positions: {
          for (final p in (m['positions'] as List? ?? []))
            (p as Map<String, dynamic>)['symbol'] as String:
                EnginePosition.fromMap(p),
        },
        equityHistory: [
          for (final e in (m['equity_history'] as List? ?? []))
            Map<String, dynamic>.from(e as Map),
        ],
      );
}

class FillResult {
  const FillResult({required this.filled, this.price, this.reason});
  final bool filled;
  final double? price;
  final String? reason;
}

/// A resting limit order held by the paper broker. Fills when the LIVE
/// market price crosses [limitPrice] (buy: price <= limit; sell: price >= limit).
class LimitOrder {
  LimitOrder({
    required this.id,
    required this.symbol,
    required this.side,
    required this.quantity,
    required this.limitPrice,
    required this.createdAt,
  });

  final String id;
  final String symbol;
  final Side side;
  final double quantity;
  final double limitPrice;
  final DateTime createdAt;

  bool crosses(double marketPrice) => side == Side.buy
      ? marketPrice <= limitPrice
      : marketPrice >= limitPrice;

  Map<String, dynamic> toMap() => {
        'id': id,
        'symbol': symbol,
        'side': side.name,
        'quantity': quantity,
        'limit_price': limitPrice,
        'created_at': createdAt.toIso8601String(),
      };

  static LimitOrder fromMap(Map<String, dynamic> m) => LimitOrder(
        id: m['id'] as String,
        symbol: m['symbol'] as String,
        side: (m['side'] as String? ?? 'buy') == 'sell' ? Side.sell : Side.buy,
        quantity: (m['quantity'] as num).toDouble(),
        limitPrice: (m['limit_price'] as num).toDouble(),
        createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
      );
}


class PaperBroker {
  PaperBroker({required String accountId, double initialCash = 1000000})
      : account = EngineAccount(accountId: accountId) {
    account.cash = initialCash;
    account.dayStart = initialCash;
    account.pushEquityPoint(DateTime.now().toUtc());
  }

  /// Rehydrate from persistence (shared_preferences JSON snapshot).
  PaperBroker.fromMap(Map<String, dynamic> m)
      : account = EngineAccount.fromMap(m);

  final EngineAccount account;

  /// Resting limit orders (persisted with the account snapshot).
  final List<LimitOrder> limitOrders = [];

  /// Full persistence snapshot: account + resting limits.
  Map<String, dynamic> toSnapshot() => {
        ...account.toMap(),
        'limit_orders': [for (final o in limitOrders) o.toMap()],
      };

  static PaperBroker fromSnapshot(Map<String, dynamic> m) {
    final b = PaperBroker.fromMap(m);
    b.limitOrders.addAll([
      for (final o in (m['limit_orders'] as List? ?? []))
        LimitOrder.fromMap(Map<String, dynamic>.from(o as Map)),
    ]);
    return b;
  }

  /// Submit a limit order (paper mode). It rests until the LIVE price
  /// crosses it — checked by [processLimits] on every refresh tick.
  FillResult placeLimitOrder({
    required String symbol,
    required Side side,
    required double quantity,
    required double limitPrice,
  }) {
    if (quantity <= 0 || limitPrice <= 0) {
      return const FillResult(filled: false, reason: 'invalid order');
    }
    if (side == Side.buy && quantity * limitPrice > account.cash) {
      return FillResult(filled: false, reason: 'insufficient cash for limit');
    }
    if (side == Side.sell) {
      final pos = account.positions[symbol];
      if (pos == null || pos.quantity < quantity) {
        return FillResult(filled: false, reason: 'not enough $symbol to sell');
      }
    }
    limitOrders.add(LimitOrder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      symbol: symbol.toUpperCase(),
      side: side,
      quantity: quantity,
      limitPrice: limitPrice,
      createdAt: DateTime.now(),
    ));
    return FillResult(filled: true, price: null, reason: 'resting');
  }

  Future<void> cancelLimitOrder(String id) async =>
      limitOrders.removeWhere((o) => o.id == id);

  /// Check resting limits against LIVE prices; fill any that crossed at the
  /// limit price. Returns (order, fillPrice) pairs; mutates state.
  List<(LimitOrder, double)> processLimits(Map<String, double> prices) {
    final fills = <(LimitOrder, double)>[];
    for (final o in List<LimitOrder>.from(limitOrders)) {
      final px = prices[o.symbol];
      if (px == null || !o.crosses(px)) continue;
      final r = placeMarketOrder(
        symbol: o.symbol,
        side: o.side,
        quantity: o.quantity,
        marketPrice: o.limitPrice, // fill at the limit, never worse
      );
      if (r.filled) {
        limitOrders.remove(o);
        fills.add((o, o.limitPrice));
      }
    }
    return fills;
  }

  /// Submit a market order at [marketPrice] (INR). MARKET orders fill
  /// immediately (paper liquidity is infinite); quantity pre-validated.
  FillResult placeMarketOrder({
    required String symbol,
    required Side side,
    required double quantity,
    required double marketPrice,
  }) {
    if (marketPrice <= 0 || quantity <= 0) {
      return const FillResult(filled: false, reason: 'invalid order');
    }
    final price = marketPrice;
    if (side == Side.buy) {
      final cost = quantity * price;
      if (cost > account.cash) {
        return FillResult(filled: false, reason: 'insufficient cash');
      }
      account.cash -= cost;
      final pos = account.positions[symbol];
      if (pos == null) {
        account.positions[symbol] = EnginePosition(
            symbol: symbol,
            quantity: quantity,
            avgPrice: price,
            currentPrice: price);
      } else {
        final total = pos.quantity + quantity;
        pos.avgPrice = (pos.avgPrice * pos.quantity + cost) / total;
        pos.quantity = total;
        pos.currentPrice = price;
      }
    } else {
      final pos = account.positions[symbol];
      if (pos == null || pos.quantity < quantity) {
        return FillResult(filled: false, reason: 'not enough $symbol to sell');
      }
      final proceeds = quantity * price;
      account.cash += proceeds;
      account.realizedPnlToday += (price - pos.avgPrice) * quantity;
      pos.quantity -= quantity;
      pos.currentPrice = price;
      if (pos.quantity <= 1e-9) {
        account.positions.remove(symbol);
      }
    }
    account.tradesToday += 1;
    account.pushEquityPoint(DateTime.now().toUtc());
    return FillResult(filled: true, price: price);
  }

  void markAll(Map<String, double> prices) => account.markAll(prices);

  /// Reset the paper account to [cash] (fresh start).
  void reset({double cash = 1000000}) {
    account.cash = cash;
    account.dayStart = cash;
    account.realizedPnlToday = 0;
    account.tradesToday = 0;
    account.positions.clear();
    account.equityHistory.clear();
    account.pushEquityPoint(DateTime.now().toUtc());
  }

  /// Roll intraday counters on the first touch of a new UTC day.
  void rollDay(DateTime now) {
    if (account.equityHistory.isEmpty) return;
    final last = DateTime.tryParse(
            account.equityHistory.last['t'] as String? ?? '') ??
        now;
    if (last.toUtc().day != now.toUtc().day ||
        last.toUtc().month != now.toUtc().month ||
        last.toUtc().year != now.toUtc().year) {
      account.dayStart = account.equity;
      account.realizedPnlToday = 0;
      account.tradesToday = 0;
    }
  }
}
