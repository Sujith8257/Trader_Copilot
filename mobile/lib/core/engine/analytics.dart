/// Portfolio analytics computed from REAL account data: the equity curve
/// (paper account history, marked to live prices) and the executed trade
/// journal. Pure functions — no network, no fabrication.
library;

import '../models.dart';

class PortfolioStats {
  const PortfolioStats({
    required this.trades,
    required this.wins,
    required this.losses,
    required this.winRatePct,
    required this.avgWin,
    required this.avgLoss,
    required this.profitFactor,
    required this.maxDrawdownPct,
    required this.netRealizedPnl,
    required this.bestTrade,
    required this.worstTrade,
  });

  final int trades;
  final int wins;
  final int losses;
  final double winRatePct;
  final double avgWin;
  final double avgLoss;
  final double profitFactor; // gross wins / gross losses (>= 1 is healthy)
  final double maxDrawdownPct; // worst peak-to-trough fall of the equity curve
  final double netRealizedPnl;
  final double bestTrade; // largest single-trade PnL (may be 0)
  final double worstTrade; // most negative single-trade PnL (may be 0)

  bool get hasTrades => trades > 0;
}

/// Realized PnL per closed lot: the journal stores fills, so PnL per SELL
/// is only exact if we track the average entry. The paper broker computes
/// realized PnL the same way — here we approximate per-trade PnL from
/// consecutive fills: each SELL against the current average BUY price.
List<double> realizedPnlSeries(List<ExecutedTrade> trades) {
  final openQty = <String, double>{};
  final openCost = <String, double>{};
  final pnl = <double>[];
  for (final t in trades) {
    if (t.side == Side.buy) {
      openQty[t.symbol] = (openQty[t.symbol] ?? 0) + t.quantity;
      openCost[t.symbol] =
          (openCost[t.symbol] ?? 0) + t.quantity * t.filledPrice;
    } else {
      final qty = openQty[t.symbol] ?? 0;
      final cost = openCost[t.symbol] ?? 0;
      if (qty <= 0) continue; // sell without a tracked lot (e.g. live import)
      final avg = cost / qty;
      final closed = qty < t.quantity ? qty : t.quantity;
      pnl.add((t.filledPrice - avg) * closed);
      openQty[t.symbol] = qty - closed;
      openCost[t.symbol] = openQty[t.symbol]! * avg;
    }
  }
  return pnl;
}

PortfolioStats computeStats({
  required List<ExecutedTrade> trades,
  required List<EquityPoint> equity,
}) {
  final pnls = realizedPnlSeries(trades);
  final wins = pnls.where((p) => p > 0).toList();
  final losses = pnls.where((p) => p <= 0).toList();
  final grossWin = wins.fold(0.0, (a, b) => a + b);
  final grossLoss = losses.fold(0.0, (a, b) => a + b).abs();

  // Max drawdown from the (chronological) equity curve.
  var peak = double.negativeInfinity;
  var maxDd = 0.0;
  for (final p in equity) {
    if (p.equity > peak) peak = p.equity;
    if (peak > 0) {
      final dd = (peak - p.equity) / peak * 100;
      if (dd > maxDd) maxDd = dd;
    }
  }

  return PortfolioStats(
    trades: trades.length,
    wins: wins.length,
    losses: losses.length,
    winRatePct: pnls.isEmpty ? 0 : wins.length / pnls.length * 100,
    avgWin: wins.isEmpty ? 0 : grossWin / wins.length,
    avgLoss: losses.isEmpty ? 0 : grossLoss / losses.length,
    profitFactor: grossLoss == 0
        ? (grossWin > 0 ? 99 : 0)
        : grossWin / grossLoss,
    maxDrawdownPct: maxDd,
    netRealizedPnl: pnls.fold(0.0, (a, b) => a + b),
    bestTrade: pnls.isEmpty ? 0 : pnls.reduce((a, b) => a > b ? a : b),
    worstTrade: pnls.isEmpty ? 0 : pnls.reduce((a, b) => a < b ? a : b),
  );
}

/// CSV export of the journal (shared to clipboard / files by the UI).
String tradesCsv(List<ExecutedTrade> trades) {
  final buf = StringBuffer(
    'time,symbol,side,quantity,filled_price_inr,notional_inr\n',
  );
  for (final t in trades) {
    buf.writeln(
      [
        t.at.toIso8601String(),
        t.symbol,
        t.side.name.toUpperCase(),
        t.quantity,
        t.filledPrice.toStringAsFixed(2),
        t.notional.toStringAsFixed(2),
      ].join(','),
    );
  }
  return buf.toString();
}
