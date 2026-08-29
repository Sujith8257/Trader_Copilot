/// Coinbase Advanced Trade client — LIVE market data + LIVE trading,
/// called directly from the phone (no backend). Port of
/// `backend/app/core/coinbase.py`.
///
/// Auth: CDP API key JWT. Ed25519 keys (64 raw bytes, seed||public) sign
/// with EdDSA. Credentials stay in secure storage on the device — never
/// logged, never exported.
///
/// All market prices are converted to INR (live USD/INR, 3-source fallback)
/// so the INR paper account, Risk Engine, and UI stay consistent.
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../models.dart';

const coinbaseProducts = [
  'BTC', 'ETH', 'SOL', 'XRP', 'ADA', 'DOGE', 'LINK', 'AVAX'
];

class CoinbaseException implements Exception {
  CoinbaseException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes a CDP private key. Returns the raw 32-byte Ed25519 seed for the
/// common 64-byte format (seed||public), or DER bytes for EC keys.
({List<int> keyBytes, String alg, bool isEd25519}) decodePrivateKey(
    String b64Key) {
  final der = base64.decode(b64Key.trim());
  if (der.length == 64) {
    return (keyBytes: der.sublist(0, 32), alg: 'EdDSA', isEd25519: true);
  }
  if (der.isNotEmpty && der[0] == 0x30) {
    return (keyBytes: der, alg: 'ES256', isEd25519: false);
  }
  throw CoinbaseException(
      'Unsupported Coinbase key format (${der.length} bytes). '
      'Use a CDP API key JSON.');
}

class CoinbaseClient {
  CoinbaseClient({this.apiKey, this.privateKey, http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  String? apiKey;
  String? privateKey;
  static const _base = 'https://api.coinbase.com';
  static const _api = '/api/v3/brokerage';

  bool get configured =>
      (apiKey ?? '').isNotEmpty && (privateKey ?? '').isNotEmpty;

  /// Mints a CDP JWT for one request (Ed25519 via package:cryptography).
  Future<String> _jwt(String method, String path) async {
    if (!configured) {
      throw CoinbaseException('Coinbase API key not configured.');
    }
    final key = decodePrivateKey(privateKey!);
    if (!key.isEd25519) {
      throw CoinbaseException('ES256 (EC) keys are not supported yet — '
          'create an Ed25519 CDP key in the Coinbase portal.');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final header = {
      'alg': key.alg,
      'kid': apiKey,
      'nonce': Random.secure().nextInt(1 << 32).toRadixString(16),
    };
    final claims = {
      'sub': apiKey,
      'iss': 'cdp',
      'nbf': now,
      'exp': now + 120,
      'uri': '$method api.coinbase.com$path',
    };
    final headB64 = _b64url(utf8.encode(jsonEncode(header)));
    final claimsB64 = _b64url(utf8.encode(jsonEncode(claims)));
    final signingInput = utf8.encode('$headB64.$claimsB64');

    final algo = Ed25519();
    final pair = await algo.newKeyPairFromSeed(key.keyBytes);
    final sig = await algo.sign(signingInput, keyPair: pair);
    return '$headB64.$claimsB64.${_b64url(sig.bytes)}';
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    bool auth = false,
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$_base$path').replace(
        queryParameters: query == null || query.isEmpty ? null : query);
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (auth) {
      headers['Authorization'] = 'Bearer ${await _jwt(method, path)}';
    }
    final req = http.Request(method, uri);
    req.headers.addAll(headers);
    if (body != null) {
      req.body = jsonEncode(body);
    }
    final streamed = await _client.send(req).timeout(const Duration(seconds: 20));
    final r = await http.Response.fromStream(streamed);
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      decoded = {};
    }
    if (r.statusCode >= 400) {
      throw CoinbaseException('Coinbase $method $path -> ${r.statusCode}: '
          '${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
    }
    return decoded;
  }

  // -- public market data --------------------------------------------------
  Future<double> getSpot(String productId) async {
    final body = await _request('GET', '$_api/market/products/$productId');
    return double.parse(body['price'] as String);
  }

  Future<List<Map<String, dynamic>>> getCandles(String productId,
      {String granularity = 'ONE_DAY', int limit = 350}) async {
    final body = await _request(
      'GET',
      '$_api/market/products/$productId/candles',
      query: {'granularity': granularity, 'limit': '$limit'},
    );
    final candles =
        (body['candles'] as List? ?? []).cast<Map<String, dynamic>>();
    candles.sort(
        (a, b) => (a['start'] as String).compareTo(b['start'] as String));
    return candles;
  }

  // -- authenticated surface -------------------------------------------------
  Future<List<Map<String, dynamic>>> getAccounts() async {
    final body = await _request('GET', '$_api/accounts',
        auth: true, query: {'limit': '250'});
    return (body['accounts'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> marketOrder(
    String productId,
    String side, {
    String? quoteSize,
    String? baseSize,
  }) {
    final payload = <String, dynamic>{
      'product_id': productId,
      'side': side,
      'order_type': 'market_market_ioc',
      'market_market_ioc': side == 'BUY'
          ? {'quote_size': quoteSize}
          : {'base_size': baseSize},
    };
    return _request('POST', '$_api/orders', auth: true, body: payload);
  }
}

/// LiveCoinbaseMarket — REAL Coinbase candles/spot behind the same read
/// surface the agent and indicators use. TTL caches respect rate limits.
class LiveCoinbaseMarket {
  LiveCoinbaseMarket({CoinbaseClient? client, List<String>? products})
      : client = client ?? CoinbaseClient(),
        _products = products ?? coinbaseProducts;

  final CoinbaseClient client;
  final List<String> _products;
  final Map<String, List<Candle>> _bars = {};
  final Map<String, DateTime> _barsTs = {};
  final Map<String, (double, DateTime)> _spot = {};
  (double, DateTime)? _fx;
  String? lastError;

  List<String> get symbols => List.unmodifiable(_products);

  String product(String symbol) => '${symbol.trim().toUpperCase()}-USD';

  Future<double> usdInr() async {
    final now = DateTime.now();
    final cached = _fx;
    if (cached != null && now.difference(cached.$2).inMinutes < 60) {
      return cached.$1;
    }
    final sources = <Future<double> Function()>[
      () async => (((await _getJson('https://open.er-api.com/v6/latest/USD'))
              ['rates'] as Map)['INR'] as num)
          .toDouble(),
      () async => (((await _getJson(
                  'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json'))
              ['usd'] as Map)['inr'] as num)
          .toDouble(),
      () async => (((await _getJson(
                  'https://api.frankfurter.dev/v1/latest?base=USD&symbols=INR'))
              ['rates'] as Map)['INR'] as num)
          .toDouble(),
    ];
    Object? lastErr;
    for (final fetch in sources) {
      try {
        final rate = await fetch();
        _fx = (rate, now);
        return rate;
      } catch (e) {
        lastErr = e;
      }
    }
    if (cached != null) return cached.$1; // last known rate; never fabricate
    throw CoinbaseException('USD/INR unavailable: $lastErr');
  }

  Future<Map<String, dynamic>> _getJson(String url) async {
    final r =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (r.statusCode >= 400) {
      throw CoinbaseException('$url -> ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<Candle>> bars(String symbol) async {
    final sym = symbol.trim().toUpperCase();
    final cached = _bars[sym];
    final ts = _barsTs[sym];
    if (cached != null &&
        ts != null &&
        DateTime.now().difference(ts).inMinutes < 5) {
      return cached;
    }
    try {
      final candles = await client.getCandles(product(sym), limit: 120);
      final fx = await usdInr();
      final list = [
        for (final c in candles)
          Candle(
            time: DateTime.fromMillisecondsSinceEpoch(
                int.parse(c['start'] as String) * 1000),
            open: double.parse(c['open'] as String) * fx,
            high: double.parse(c['high'] as String) * fx,
            low: double.parse(c['low'] as String) * fx,
            close: double.parse(c['close'] as String) * fx,
            volume: double.tryParse(c['volume'] as String? ?? ''),
          ),
      ];
      if (list.isEmpty) {
        throw CoinbaseException('No candles for $sym');
      }
      _bars[sym] = list;
      _barsTs[sym] = DateTime.now();
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
    final fx = await usdInr();
    final price = await client.getSpot(product(sym)) * fx;
    _spot[sym] = (price, DateTime.now());
    return price;
  }
}
