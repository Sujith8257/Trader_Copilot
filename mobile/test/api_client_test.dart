import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:trader_copilot/core/api_client.dart';
import 'package:trader_copilot/core/models.dart';

void main() {
  group('ApiClient', () {
    test('fetchAccount parses account state', () async {
      final api = ApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/account');
          return http.Response(
            jsonEncode({
              'account_id': 'paper-primary',
              'mode': 'PAPER',
              'cash': 975500.0,
              'equity': 1000000.0,
              'positions': {
                'RELIANCE': {'qty': 10, 'avg': 2450.0, 'last': 2450.0},
              },
            }),
            200,
          );
        }),
      );

      final acct = await api.fetchAccount();
      expect(acct.accountId, 'paper-primary');
      expect(acct.mode, AccountMode.paper);
      expect(acct.cash, 975500.0);
      expect(acct.equity, 1000000.0);
      expect(acct.positions['RELIANCE']!.quantity, 10);
      expect(acct.positions['RELIANCE']!.unrealizedPnl, 0);
    });

    test('evaluateProposal sends proposal and parses verdict', () async {
      Map<String, dynamic>? sent;
      final api = ApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/proposals/evaluate');
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'allowed': false,
              'violations': ['Market is closed - order rejected.'],
              'warnings': [],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final verdict = await api.evaluateProposal(
        TradeProposal(
          symbol: 'RELIANCE',
          side: Side.buy,
          quantity: 10,
          stopLoss: 2400,
          takeProfit: 2550,
          confidence: 0.72,
        ),
        marketPrice: 2450,
        marketOpen: false,
      );

      expect(sent!['side'], 'BUY');
      expect(sent!['market_open'], false);
      expect(verdict.allowed, false);
      expect(verdict.violations, hasLength(1));
    });

    test('placePaperOrder parses fill result', () async {
      final api = ApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/orders/paper');
          expect(request.url.queryParameters['symbol'], 'INFY');
          return http.Response(
            jsonEncode({
              'order_id': 'ord_abc123',
              'status': 'FILLED',
              'filled_price': 1500.0,
            }),
            200,
          );
        }),
      );

      final result = await api.placePaperOrder(
        symbol: 'INFY',
        side: Side.buy,
        quantity: 5,
        marketPrice: 1500,
      );
      expect(result.filled, true);
      expect(result.filledPrice, 1500.0);
    });

    test('non-2xx response throws ApiError', () async {
      final api = ApiClient(
        client: MockClient((request) async =>
            http.Response('{"detail":"boom"}', 500)),
      );
      expect(() => api.fetchAccount(), throwsA(isA<ApiError>()));
    });

    test('riskReward computes for a long proposal', () {
      final p = TradeProposal(
        symbol: 'RELIANCE',
        side: Side.buy,
        quantity: 10,
        entryPrice: 2450,
        stopLoss: 2400,
        takeProfit: 2550,
      );
      expect(p.riskReward, closeTo(2.0, 0.01));
    });
  });
}
