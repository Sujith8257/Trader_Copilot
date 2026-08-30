import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trader_copilot/core/engine/alerts.dart';
import 'package:trader_copilot/core/engine/analytics.dart';
import 'package:trader_copilot/core/engine/coinbase_client.dart';
import 'package:trader_copilot/core/engine/indicators.dart';
import 'package:trader_copilot/core/engine/paper_broker.dart';
import 'package:trader_copilot/core/engine/risk_engine.dart';
import 'package:trader_copilot/core/format.dart';
import 'package:trader_copilot/core/models.dart';

EngineAccount _richAccount({double cash = 1000000}) {
  final acct = EngineAccount(accountId: 'test');
  acct.cash = cash;
  acct.dayStart = cash;
  return acct;
}

void main() {
  group('indicators', () {
    test('sma computes simple averages', () {
      final out = sma([1, 2, 3, 4, 5], 3);
      expect(out[2], 2.0);
      expect(out[4], 4.0);
      expect(out[1], isNull);
    });

    test('rsi is 100 for straight-up series and low for falling', () {
      final up = List<double>.generate(30, (i) => 100.0 + i);
      expect(rsi(up), 100.0);
      final down = List<double>.generate(30, (i) => 100.0 - i);
      expect(rsi(down)! < 5, isTrue);
    });

    test('ema seeds with sma', () {
      final out = ema([2, 4, 6, 8], 2);
      expect(out[1], 3.0); // (2+4)/2
    });

    test('snapshot produces ATR stop below and target above', () {
      final bars = <Candle>[];
      for (var i = 0; i < 120; i++) {
        final o = 100.0 + i;
        bars.add(
          Candle(
            time: DateTime.now(),
            open: o,
            high: o + 2,
            low: o - 2,
            close: o + 1,
            volume: 10,
          ),
        );
      }
      final s = snapshot(bars);
      expect(s['trend'], 'UP');
      expect((s['stop'] as double) < (s['last'] as double), isTrue);
      expect((s['target'] as double) > (s['last'] as double), isTrue);
    });
  });

  group('formatINR', () {
    test('groups lakhs and crores the Indian way', () {
      expect(formatINR(975500), '₹9,75,500');
      expect(formatINR(10000000), '₹1,00,00,000');
      expect(formatINR(500), '₹500');
    });
    test('handles decimals, negatives and signs', () {
      expect(formatINR(-1500.5, decimals: 2), '-₹1,500.50');
      expect(formatSignedINR(250), '+₹250');
    });
  });

  group('risk engine', () {
    final engine = RiskEngine();

    test('allows a sane paper buy', () {
      final v = engine.evaluate(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 0.004,
        marketPrice: 5400000,
        account: _richAccount(),
        entryPrice: 5400000,
        stopLoss: 5200000,
        takeProfit: 5700000,
      );
      expect(v.allowed, isTrue);
    });

    test('blocks when notional exceeds max position', () {
      final v = engine.evaluate(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 1,
        marketPrice: 5400000,
        account: _richAccount(),
        entryPrice: 5400000,
        stopLoss: 5200000,
      );
      expect(v.allowed, isFalse);
      expect(v.violations.any((s) => s.contains('max position')), isTrue);
    });

    test('blocks when stop-loss is above entry for a BUY', () {
      final v = engine.evaluate(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 0.004,
        marketPrice: 5400000,
        account: _richAccount(),
        entryPrice: 5400000,
        stopLoss: 5600000,
      );
      expect(v.allowed, isFalse);
    });

    test('blocks sells of assets you do not hold', () {
      final v = engine.evaluate(
        symbol: 'ETH',
        side: Side.sell,
        quantity: 1,
        marketPrice: 270000,
        account: _richAccount(),
      );
      expect(v.allowed, isFalse);
    });

    test('allows EXITING a full position even above max notional', () {
      // Exits REDUCE risk — the notional cap must never trap a user in a
      // position (regression: force-exit was blocked with 'Order notional').
      final acct = _richAccount();
      acct.positions['BTC'] = EnginePosition(
        symbol: 'BTC',
        quantity: 0.01,
        avgPrice: 5400000,
        currentPrice: 5400000,
      );
      final v = engine.evaluate(
        symbol: 'BTC',
        side: Side.sell,
        quantity: 0.01, // 0.01 x 5,400,000 = ₹54,000 >> ₹25,000 cap
        marketPrice: 5400000,
        account: acct,
      );
      expect(v.allowed, isTrue);
      // ...while a BUY above the cap is still blocked.
      final buy = engine.evaluate(
        symbol: 'ETH',
        side: Side.buy,
        quantity: 1,
        marketPrice: 270000,
        account: _richAccount(),
      );
      expect(buy.allowed, isFalse);
    });

    test('kill switch blocks everything', () {
      final kill = RiskEngine(config: RiskConfig()..enabled = false);
      final v = kill.evaluate(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 0.001,
        marketPrice: 5400000,
        account: _richAccount(),
        stopLoss: 1,
      );
      expect(v.allowed, isFalse);
      expect(v.violations.first.contains('Kill switch'), isTrue);
    });
  });

  group('paper broker', () {
    test('market buy then sell round-trips cash and PnL', () {
      final broker = PaperBroker(accountId: 't', initialCash: 1000000);
      final buy = broker.placeMarketOrder(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 0.01,
        marketPrice: 100,
      );
      expect(buy.filled, isTrue);
      expect(broker.account.cash, closeTo(999999, 0.001));
      expect(broker.account.positions['BTC']!.quantity, 0.01);

      final sell = broker.placeMarketOrder(
        symbol: 'BTC',
        side: Side.sell,
        quantity: 0.01,
        marketPrice: 110,
      );
      expect(sell.filled, isTrue);
      expect(broker.account.cash, closeTo(1000000.1, 0.001));
      expect(broker.account.realizedPnlToday, closeTo(0.1, 0.001));
      expect(broker.account.positions.containsKey('BTC'), isFalse);
    });

    test('rejects buying without cash and selling without position', () {
      final broker = PaperBroker(accountId: 't', initialCash: 500);
      final r1 = broker.placeMarketOrder(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 1,
        marketPrice: 1000,
      );
      expect(r1.filled, isFalse);
      final r2 = broker.placeMarketOrder(
        symbol: 'BTC',
        side: Side.sell,
        quantity: 1,
        marketPrice: 1000,
      );
      expect(r2.filled, isFalse);
    });

    test('persists to a map and restores', () {
      final broker = PaperBroker(accountId: 't', initialCash: 1000000);
      broker.placeMarketOrder(
        symbol: 'ETH',
        side: Side.buy,
        quantity: 2,
        marketPrice: 100,
      );
      final restored = PaperBroker.fromMap(broker.account.toMap());
      expect(restored.account.cash, broker.account.cash);
      expect(restored.account.positions['ETH']!.quantity, 2);
    });
  });

  group('coinbase key decoding', () {
    test('decodes a 64-byte Ed25519 key (seed||public)', () {
      final raw = List<int>.generate(64, (i) => i);
      final key = decodePrivateKey(base64Encode(raw));
      expect(key.isEd25519, isTrue);
      expect(key.alg, 'EdDSA');
      expect(key.keyBytes.length, 32);
    });

    test('rejects garbage keys', () {
      expect(
        () => decodePrivateKey(base64Encode([1, 2, 3])),
        throwsA(isA<CoinbaseException>()),
      );
    });
  });

  group('limit orders', () {
    test('rests, then fills when the live price crosses, at the limit', () {
      final broker = PaperBroker(accountId: 't', initialCash: 1000000);
      final r = broker.placeLimitOrder(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 0.01,
        limitPrice: 100,
      );
      expect(r.filled, isTrue);
      expect(broker.limitOrders.length, 1);

      expect(broker.processLimits({'BTC': 110}), isEmpty); // above limit
      final fills = broker.processLimits({'BTC': 95}); // crossed
      expect(fills.length, 1);
      expect(fills.first.$2, 100); // fills AT the limit, never worse
      expect(broker.account.positions['BTC']!.avgPrice, 100);
      expect(broker.limitOrders, isEmpty);
    });

    test('sell limit fills on the way up', () {
      final broker = PaperBroker(accountId: 't', initialCash: 1000000);
      broker.placeMarketOrder(
        symbol: 'ETH',
        side: Side.buy,
        quantity: 2,
        marketPrice: 100,
      );
      broker.placeLimitOrder(
        symbol: 'ETH',
        side: Side.sell,
        quantity: 2,
        limitPrice: 120,
      );
      final fills = broker.processLimits({'ETH': 121});
      expect(fills.length, 1);
      expect(broker.account.realizedPnlToday, closeTo(40, 0.001));
    });

    test('snapshot round-trips resting limits', () {
      final broker = PaperBroker(accountId: 't', initialCash: 1000000);
      broker.placeLimitOrder(
        symbol: 'BTC',
        side: Side.buy,
        quantity: 0.01,
        limitPrice: 100,
      );
      final restored = PaperBroker.fromSnapshot(broker.toSnapshot());
      expect(restored.limitOrders.length, 1);
      expect(restored.limitOrders.first.limitPrice, 100);
    });
  });

  group('alerts', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('fires once on a fresh crossing, then re-arms', () async {
      final engine = AlertEngine();
      await engine.add(
        symbol: 'BTC',
        metric: AlertMetric.price,
        op: AlertOp.above,
        value: 100,
      );

      expect(await engine.check(prices: {'BTC': 90}, rsi: {}), isEmpty);
      expect((await engine.check(prices: {'BTC': 105}, rsi: {})).length, 1);
      expect(await engine.check(prices: {'BTC': 110}, rsi: {}), isEmpty);
      expect(await engine.check(prices: {'BTC': 95}, rsi: {}), isEmpty);
      expect((await engine.check(prices: {'BTC': 101}, rsi: {})).length, 1);
    });

    test('rsi alerts fire on oversold', () async {
      final engine = AlertEngine();
      await engine.add(
        symbol: 'ETH',
        metric: AlertMetric.rsi,
        op: AlertOp.below,
        value: 30,
      );
      final fired = await engine.check(prices: {}, rsi: {'ETH': 28.5});
      expect(fired.length, 1);
      expect(fired.first.symbol, 'ETH');
    });

    test('rules persist across engine instances', () async {
      final a = AlertEngine();
      await a.add(
        symbol: 'BTC',
        metric: AlertMetric.price,
        op: AlertOp.below,
        value: 50,
      );
      final b = AlertEngine();
      await b.load();
      expect(b.rules.length, 1);
      expect(b.rules.first.describe(), 'BTC price ≤ 50');
    });
  });

  group('portfolio analytics', () {
    ExecutedTrade t(Side side, double qty, double px) => ExecutedTrade(
      symbol: 'BTC',
      side: side,
      quantity: qty,
      filledPrice: px,
      at: DateTime.now(),
    );

    test('realized pnl per closed lot uses the average entry', () {
      final pnls = realizedPnlSeries([
        t(Side.buy, 1, 100),
        t(Side.buy, 1, 120),
        t(Side.sell, 2, 130),
      ]);
      expect(pnls.length, 1);
      expect(pnls.first, closeTo(40, 0.001)); // avg entry 110, 2 sold @ 130
    });

    test('stats: win rate, profit factor, max drawdown', () {
      final trades = [
        t(Side.buy, 1, 100),
        t(Side.sell, 1, 130), // +30
        t(Side.buy, 1, 100),
        t(Side.sell, 1, 80), // -20
      ];
      final now = DateTime.now();
      final equity = [
        EquityPoint(t: now, equity: 1000),
        EquityPoint(t: now, equity: 1200), // peak
        EquityPoint(t: now, equity: 900), // -25% from peak
        EquityPoint(t: now, equity: 1100),
      ];
      final s = computeStats(trades: trades, equity: equity);
      expect(s.trades, 4);
      expect(s.winRatePct, closeTo(50, 0.01));
      expect(s.profitFactor, closeTo(1.5, 0.01));
      expect(s.maxDrawdownPct, closeTo(25, 0.01));
      expect(s.netRealizedPnl, closeTo(10, 0.001));
      expect(s.bestTrade, closeTo(30, 0.001));
      expect(s.worstTrade, closeTo(-20, 0.001));
    });

    test('csv export has a header and one row per trade', () {
      final csv = tradesCsv([
        ExecutedTrade(
          symbol: 'BTC',
          side: Side.buy,
          quantity: 0.01,
          filledPrice: 5400000,
          at: DateTime.parse('2026-01-01T10:00:00Z'),
        ),
      ]);
      final lines = csv.trim().split('\n');
      expect(lines.first, startsWith('time,symbol,side'));
      expect(lines.length, 2);
      expect(lines.last, contains('BTC,BUY'));
    });
  });
}
