/// CoinSwitch PRO API Trading client — LIVE INR market data + LIVE spot
/// trading, called directly from the phone (no backend).
///
/// Auth: Ed25519 over `METHOD + path_with_query + epoch` (URL-decoded
/// query; body NOT signed when an epoch is sent). Headers: X-AUTH-APIKEY,
/// X-AUTH-SIGNATURE (hex), X-AUTH-EPOCH (Unix ms).
/// Docs: https://api-trading.coinswitch.co
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../models.dart';

const fallbackProducts = ['BTC', 'ETH', 'SOL', 'XRP', 'ADA', 'DOGE', 'LINK', 'AVAX'];

class CoinSwitchException implements Exception {
  CoinSwitchException(this.message);
  final String message;
  @override
  String toString() => message;
}

List<int> decodeSeedHex(String hexKey) {
  final clean = hexKey.trim().toLowerCase();
  if (clean.length != 64) {
    throw CoinSwitchException(
      'CoinSwitch secret must be 64 hex chars (got ${hexKey.trim().length}).',
    );
  }
  return [
    for (var i = 0; i < 64; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16)
  ];
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class CoinSwitchClient {
  CoinSwitchClient({this.apiKey, this.secretKey, http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String _base = 'https://coinswitch.co';
  String? apiKey;
  String? secretKey;

  bool get configured =>
      (apiKey ?? '').isNotEmpty && (secretKey ?? '').isNotEmpty;

  Future<({Map<String, String> headers, String path})> _sign(
    String method,
    String pathWithQuery,
  ) async {
    if (!configured) {
      throw CoinSwitchException('CoinSwitch API key not configured.');
    }
    final epoch = DateTime.now().millisecondsSinceEpoch.toString();
    final message = '$method$pathWithQuery$epoch';
    final algo = Ed25519();
    final pair = await algo.newKeyPairFromSeed(decodeSeedHex(secretKey!));
    final sig = await algo.sign(utf8.encode(message), keyPair: pair);
    return (
      headers: {
        'Content-Type': 'application/json',
        'X-AUTH-APIKEY': apiKey!.trim(),
        'X-AUTH-SIGNATURE': _hex(sig.bytes),
        'X-AUTH-EPOCH': epoch,
      },
      path: pathWithQuery,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? params,
    Map<String, dynamic>? body,
  }) async {
    var p = path;
    if (params != null && params.isNotEmpty) {
      p = '$path?${params.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    }
    final auth = await _sign(method, p);
    final r = method == 'POST'
        ? await _client
            .post(Uri.parse('$_base$p'),
                headers: auth.headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 20))
        : await _client
            .get(Uri.parse('$_base$p'), headers: auth.headers)
            .timeout(const Duration(seconds: 20));
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      decoded = {};
    }
    if (r.statusCode >= 400) {
      throw CoinSwitchException(
        'CoinSwitch $method $path -> ${r.statusCode}: '
        '${r.body.length > 200 ? r.body.substring(0, 200) : r.body}',
      );
    }
    return decoded;
  }

  Future<bool> validateKeys() async {
    final body = await _request('GET', '/trade/api/v2/validate/keys');
    return (body['message']?.toString().toLowerCase().contains('valid') ??
        false);
  }

  Future<List<Map<String, dynamic>>> ticker(
      {String exchange = 'coinswitchx'}) async {
    final body = await _request('GET', '/trade/api/v2/ticker',
        params: {'exchange': exchange});
    final data = body['data'];
    if (data is List) return data.cast<Map<String, dynamic>>();
    if (data is Map) {
      return [
        for (final e in data.entries)
          {'symbol': e.key, ...(e.value as Map).cast<String, dynamic>()}
      ];
    }
    return const [];
  }

  Future<List<String>> activeCoins({String exchange = 'coinswitchx'}) async {
    final body = await _request('GET', '/trade/api/v2/coins',
        params: {'exchange': exchange});
    final data = body['data'] as Map<String, dynamic>? ?? {};
    final list = (data[exchange] as List?) ?? const [];
    return [for (final s in list) (s as String).split('/').first];
  }

  Future<List<Map<String, dynamic>>> candles(
    String symbol, {
    String exchange = 'coinswitchx',
    int intervalMinutes = 1440,
  }) async {
    final end = DateTime.now().millisecondsSinceEpoch;
    final start = end - 120 * intervalMinutes * 60000;
    final body = await _request('GET', '/trade/api/v2/candles', params: {
      'exchange': exchange,
      'symbol': '$symbol/INR',
      'interval': '$intervalMinutes',
      'start_time': '$start',
      'end_time': '$end',
    });
    return (body['data'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> portfolio() async {
    final body = await _request('GET', '/trade/api/v2/user/portfolio');
    return (body['data'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> placeLimitOrder({
    required String symbol,
    required String side,
    required double price,
    required double quantity,
  }) =>
      _request('POST', '/trade/api/v2/order', body: {
        'side': side.toLowerCase(),
        'symbol': '$symbol/INR',
        'type': 'limit',
        'price': price,
        'quantity': quantity,
        'exchange': 'coinswitchx',
      });

  Future<Map<String, dynamic>> getOrder(String orderId) async {
    final body = await _request('GET', '/trade/api/v2/order',
        params: {'order_id': orderId});
    return body['data'] as Map<String, dynamic>? ?? {};
  }
}

/// Live CoinSwitch market — the same read surface the rest of the app
/// consumes, backed by CoinSwitch. INR-native: no FX conversion anywhere.
class LiveCoinSwitchMarket {
  LiveCoinSwitchMarket({CoinSwitchClient? client, List<String>? products})
      : client = client ?? CoinSwitchClient(),
        _products = List.of(products ?? fallbackProducts);

  final CoinSwitchClient client;
  List<String> _products;
  DateTime? _productsAt;
  final Map<String, List<Candle>> _bars = {};
  final Map<String, DateTime> _barsTs = {};
  final Map<String, (double, DateTime)> _spot = {};
  String? lastError;

  List<String> get symbols => List.unmodifiable(_products);

  String product(String symbol) => '${symbol.trim().toUpperCase()}/INR';

  double? baseIncrement(String symbol) => null;
  double? minBaseSize(String symbol) => null;
  double? minQuoteSize(String symbol) => null;

  /// Pull the live instrument list; fallback list when unreachable.
  Future<void> ensureProducts() async {
    final at = _productsAt;
    if (at != null && DateTime.now().difference(at).inMinutes < 5) return;
    try {
      final coins = await client.activeCoins();
      if (coins.length >= 5) {
        _products = coins;
        _productsAt = DateTime.now();
        lastError = null;
      }
    } catch (e) {
      lastError = 'coins: $e';
    }
  }

  Future<List<Candle>> bars(String symbol,
      {String granularity = 'ONE_DAY'}) async {
    final sym = symbol.trim().toUpperCase();
    final key = '$sym:$granularity';
    final cached = _bars[key];
    final ts = _barsTs[key];
    final ttl = granularity == 'ONE_DAY' ? 5 : 2;
    if (cached != null &&
        ts != null &&
        DateTime.now().difference(ts).inMinutes < ttl) {
      return cached;
    }
    final interval = granularity == 'ONE_HOUR'
        ? 60
        : (granularity == 'SIX_HOUR' ? 360 : 1440);
    try {
      final raw = await client.candles(sym, intervalMinutes: interval);
      final list = [
        for (final c in raw)
          Candle(
            time: DateTime.fromMillisecondsSinceEpoch(
              int.parse(c['start_time'] as String? ?? '0'),
            ),
            open: double.parse(c['o'] as String? ?? '0'),
            high: double.parse(c['h'] as String? ?? '0'),
            low: double.parse(c['l'] as String? ?? '0'),
            close: double.parse(c['c'] as String? ?? '0'),
            volume: double.tryParse(c['volume'] as String? ?? ''),
          ),
      ];
      if (list.isEmpty) throw CoinSwitchException('No candles for $sym');
      _bars[key] = list;
      _barsTs[key] = DateTime.now();
      lastError = null;
      return list;
    } catch (e) {
      lastError = '$sym: $e';
      rethrow;
    }
  }

  Future<List<double>> prices(String symbol) async =>
      (await bars(symbol)).map((b) => b.close).toList();

  Future<double> last(String symbol) async {
    final sym = symbol.trim().toUpperCase();
    final hit = _spot[sym];
    if (hit != null && DateTime.now().difference(hit.$2).inSeconds < 30) {
      return hit.$1;
    }
    double price = 0;
    try {
      for (final t in await client.ticker()) {
        if ((t['symbol'] as String? ?? '').split('/').first == sym) {
          price = double.tryParse(
                  (t['last_price'] ?? t['lastPrice'] ?? t['last'] ?? 0)
                      .toString()) ??
              0;
          break;
        }
      }
    } catch (_) {}
    if (price <= 0) {
      price = (await bars(sym)).last.close;
    }
    _spot[sym] = (price, DateTime.now());
    return price;
  }
}

