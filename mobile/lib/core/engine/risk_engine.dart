/// Deterministic Risk Engine — RULE #1 of Trader Copilot: an LLM can only
/// *propose* a trade. Pure Dart port of `backend/app/core/risk_engine.py`:
/// no I/O, no model calls, fully unit-testable. Every check appends a
/// human-readable violation (hard block) or warning (pass with note).
library;

import '../models.dart';
import 'paper_broker.dart';

class RiskConfig {
  RiskConfig({
    this.enabled = true,
    this.maxPositionNotional = 25000.0,
    this.maxOpenPositions = 10,
    this.maxPortfolioExposurePct = 0.80,
    this.stopLossRequired = true,
    this.maxTradesPerDay = 20,
    this.maxDailyLossPct = 0.05,
  });

  bool enabled; // global kill switch: false blocks every proposal
  double maxPositionNotional;
  int maxOpenPositions;
  double maxPortfolioExposurePct;
  bool stopLossRequired;
  int maxTradesPerDay;
  double maxDailyLossPct;
}

class RiskVerdict {
  RiskVerdict({required this.allowed, List<String>? violations, List<String>? warnings})
      : violations = violations ?? [],
        warnings = warnings ?? [];

  bool allowed;
  final List<String> violations;
  final List<String> warnings;

  void block(String reason) {
    allowed = false;
    violations.add(reason);
  }

  void warn(String message) => warnings.add(message);

  Map<String, dynamic> toMap() => {
        'allowed': allowed,
        'violations': violations,
        'warnings': warnings,
      };
}

class RiskEngine {
  RiskEngine({RiskConfig? config}) : config = config ?? RiskConfig();

  final RiskConfig config;

  /// Evaluate a proposal against the account. Crypto is 24/7 so market
  /// hours never block; [marketPrice] is the live price in INR.
  RiskVerdict evaluate({
    required String symbol,
    required Side side,
    required double quantity,
    required double marketPrice,
    required EngineAccount account,
    double? entryPrice,
    double? stopLoss,
    double? takeProfit,
    String source = 'ai',
    double? confidence,
  }) {
    final cfg = config;
    final verdict = RiskVerdict(allowed: true);

    // 1. Kill switch
    if (!cfg.enabled) {
      verdict.block('Kill switch is ACTIVE — all trading is disabled.');
      return verdict;
    }

    // 2. Symbol & quantity validity
    final sym = symbol.trim().toUpperCase();
    if (sym.isEmpty) {
      verdict.block('Proposal has no symbol.');
    } else if (!sym.contains(RegExp(r'^[A-Z0-9.\-]+$'))) {
      verdict.block("Invalid symbol format: '$symbol'.");
    }
    if (quantity <= 0) {
      verdict.block('Quantity must be positive (got $quantity).');
      return verdict;
    }
    if (marketPrice <= 0) {
      verdict.block('Market price must be positive (got $marketPrice).');
      return verdict;
    }

    // 3. Available cash
    final cost = quantity * marketPrice;
    if (side == Side.buy && cost > account.cash) {
      verdict.block('Insufficient cash: order needs ${_fmt(cost)} '
          'but account has ${_fmt(account.cash)}.');
    }

    // 4. Max single-position notional
    if (cost > cfg.maxPositionNotional) {
      verdict.block('Order notional ${_fmt(cost)} exceeds max position size '
          '${_fmt(cfg.maxPositionNotional)}.');
    }

    // 5. Max open positions
    if (side == Side.buy && !account.positions.containsKey(sym)) {
      if (account.positions.length >= cfg.maxOpenPositions) {
        verdict.block('Max open positions reached (${cfg.maxOpenPositions}).');
      }
    }

    // 6. Portfolio exposure
    if (side == Side.buy) {
      final newExposure = account.grossExposure + cost;
      final equity = account.equity > 0 ? account.equity : 1e-9;
      if (newExposure / equity > cfg.maxPortfolioExposurePct) {
        verdict.block('Portfolio exposure would reach '
            '${(newExposure / equity * 100).toStringAsFixed(1)}% of equity '
            '(limit ${(cfg.maxPortfolioExposurePct * 100).toStringAsFixed(0)}%).');
      }
    }

    // 7. Stop-loss / take-profit sanity
    if (cfg.stopLossRequired && stopLoss == null && side == Side.buy) {
      verdict.block('Stop-loss is required by your risk config.');
    }
    if (side == Side.buy) {
      final ref = entryPrice ?? marketPrice;
      if (stopLoss != null && stopLoss >= ref) {
        verdict.block('For a BUY, stop-loss ($stopLoss) must be below the '
            'entry reference (${ref.toStringAsFixed(2)}).');
      }
      if (takeProfit != null && takeProfit <= ref) {
        verdict.block('For a BUY, take-profit ($takeProfit) must be above '
            'the entry reference (${ref.toStringAsFixed(2)}).');
      }
    } else {
      final pos = account.positions[sym];
      if (pos == null || pos.quantity < quantity) {
        verdict.block('Cannot SELL $sym: you hold '
            '${pos?.quantity ?? 0} but want to sell $quantity.');
      }
    }

    // 8. Max trades per day
    if (account.tradesToday >= cfg.maxTradesPerDay) {
      verdict.block('Daily trade limit reached '
          '(${account.tradesToday}/${cfg.maxTradesPerDay}).');
    }

    // 9. Max daily loss
    final dayEquity = account.dayStart > 0 ? account.dayStart : 1e-9;
    if (account.realizedPnlToday <= -dayEquity * cfg.maxDailyLossPct) {
      verdict.block('Daily loss ${_fmt(account.realizedPnlToday)} exceeds '
          '${(cfg.maxDailyLossPct * 100).toStringAsFixed(1)}% of day-start '
          'equity (${_fmt(dayEquity)}).');
    }

    // 10. Entry-vs-market deviation
    if (entryPrice != null && entryPrice > 0) {
      final deviation = (entryPrice - marketPrice).abs() / marketPrice;
      if (deviation > 0.02) {
        verdict.block('Proposal entry ${entryPrice.toStringAsFixed(2)} '
            'deviates ${(deviation * 100).toStringAsFixed(2)}% from market '
            'price ${marketPrice.toStringAsFixed(2)} (limit 2%).');
      }
    }

    // Confidence honesty
    if (source == 'ai' && confidence != null) {
      if (confidence < 0 || confidence > 1) {
        verdict.warn('AI confidence is out of range — treat as unreliable.');
      } else {
        verdict.warn('AI confidence is an assessment, not a guarantee.');
      }
    }

    return verdict;
  }
}

String _fmt(double v) => v.toStringAsFixed(2);
