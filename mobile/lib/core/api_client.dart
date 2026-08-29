import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// HTTP client for the Trader Copilot backend (FastAPI).
///
/// The AI never talks to this layer directly: proposals go IN for risk
/// evaluation, and only the user's approval sends anything to a broker.
class ApiClient {
  ApiClient({http.Client? client, this.baseUrl = 'http://localhost:8000'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> health() async {
    final r = await _client.get(_uri('/health'));
    _ensureOk(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<AccountState> fetchAccount() async {
    final r = await _client.get(_uri('/account'));
    _ensureOk(r);
    return AccountState.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Runs a proposal through the deterministic Risk Engine.
  /// Nothing is executed — evaluation only.
  Future<RiskVerdict> evaluateProposal(
    TradeProposal p, {
    required double marketPrice,
    bool marketOpen = true,
  }) async {
    final r = await _client.post(
      _uri('/proposals/evaluate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'symbol': p.symbol,
        'side': p.side.wire,
        'quantity': p.quantity,
        'entry_price': p.entryPrice,
        'stop_loss': p.stopLoss,
        'take_profit': p.takeProfit,
        'rationale': p.rationale,
        'confidence': p.confidence,
        'source': p.source,
        'market_price': marketPrice,
        'market_open': marketOpen,
      }),
    );
    _ensureOk(r);
    return RiskVerdict.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Places an order on the PAPER broker (simulated execution only).
  Future<OrderResult> placePaperOrder({
    required String symbol,
    required Side side,
    required double quantity,
    required double marketPrice,
  }) async {
    final r = await _client.post(_uri('/orders/paper').replace(queryParameters: {
      'symbol': symbol,
      'side': side.wire,
      'quantity': '$quantity',
      'market_price': '$marketPrice',
    }));
    _ensureOk(r);
    return OrderResult.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  void _ensureOk(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiError('Backend returned ${r.statusCode}: ${r.body}');
    }
  }
}

class ApiError implements Exception {
  ApiError(this.message);
  final String message;

  @override
  String toString() => message;
}
