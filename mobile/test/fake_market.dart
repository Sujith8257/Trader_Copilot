import 'package:trader_copilot/core/engine/coinbase_client.dart';
import 'package:trader_copilot/core/models.dart';

/// Deterministic fake market for widget tests — canned candles and spot
/// prices, zero network. Test-only by design.
class FakeMarket extends LiveCoinbaseMarket {
  FakeMarket() : super(products: const ['BTC', 'ETH']);

  @override
  Future<double> usdInr() async => 90.0;

  @override
  Future<List<Candle>> bars(String symbol) async {
    final bars = <Candle>[];
    for (var i = 0; i < 120; i++) {
      final o = 60000.0 + i * 20;
      final c = o * 1.005;
      bars.add(Candle(
        time: DateTime.fromMillisecondsSinceEpoch(
            1700000000000 + i * 86400000),
        open: o * 90,
        high: c * 1.01 * 90,
        low: o * 0.99 * 90,
        close: c * 90,
        volume: 100 + i.toDouble(),
      ));
    }
    return bars;
  }

  @override
  Future<double> last(String symbol) async =>
      symbol.toUpperCase() == 'BTC' ? 60000.0 * 1.005 * 90 : 3000.0 * 90;
}
