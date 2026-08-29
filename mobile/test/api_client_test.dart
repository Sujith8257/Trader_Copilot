import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:trader_copilot/core/api_client.dart';
import 'package:trader_copilot/core/format.dart';
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

  group('formatINR (Indian rupee grouping)', () {
    test('groups lakhs and crores the Indian way', () {
      expect(formatINR(0), '₹0');
      expect(formatINR(500), '₹500');
      expect(formatINR(2450), '₹2,450');
      expect(formatINR(975500), '₹9,75,500');
      expect(formatINR(1000000), '₹10,00,000');
      expect(formatINR(12345678), '₹1,23,45,678');
    });

    test('handles decimals, negatives and signs', () {
      expect(formatINR(2450.5, decimals: 2), '₹2,450.50');
      expect(formatINR(-1200), '-₹1,200');
      expect(formatSignedINR(500), '+₹500');
      expect(formatSignedINR(-500), '-₹500');
    });
  });

  group('AgentReply parsing (agentic copilot)', () {
    test('parses reply, tool trace and opportunities', () async {
      final api = ApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/agent/chat');
          return http.Response(
            jsonEncode({
              'brain': 'local',
              'reply': 'Top 1 opportunities right now.',
              'steps': [
                {'tool': 'scan_market', 'detail': 'Scoring 8 symbols...'},
                {'tool': 'indicators', 'detail': 'TATAMOTORS: RSI 61'},
              ],
              'proposal': null,
              'verdict': null,
              'opportunities': [
                {
                  'symbol': 'TATAMOTORS',
                  'last': 1020.0,
                  'change_pct': 1.2,
                  'rsi': 61.0,
                  'trend': 'UP',
                  'score': 1.95,
                  'reasons': ['price above key EMAs'],
                  'stop': 980.0,
                  'target': 1080.0,
                },
              ],
            }),
            200,
          );
        }),
      );

      final reply = await api.agentChat('scan the market');
      expect(reply.brain, 'local');
      expect(reply.steps, hasLength(2));
      expect(reply.steps[0].tool, 'scan_market');
      expect(reply.hasDraft, false);
      expect(reply.opportunities, hasLength(1));
      expect(reply.opportunities.first.symbol, 'TATAMOTORS');
      expect(reply.opportunities.first.stop < reply.opportunities.first.last,
          isTrue);
    });

    test('parses a proposal draft with its verdict', () async {
      final api = ApiClient(
        client: MockClient((request) async => http.Response(
              jsonEncode({
                'brain': 'local',
                'reply': 'Draft ready.',
                'steps': [],
                'proposal': {
                  'symbol': 'INFY',
                  'side': 'BUY',
                  'quantity': 4,
                  'entry_price': 1520.0,
                  'stop_loss': 1480.0,
                  'take_profit': 1580.0,
                  'rationale': 'UP trend.',
                  'confidence': 0.72,
                },
                'verdict': {'allowed': true, 'violations': [], 'warnings': []},
                'opportunities': [],
              }),
              200,
            )),
      );

      final reply = await api.agentChat('buy INFY');
      expect(reply.hasDraft, true);
      expect(reply.proposal!.symbol, 'INFY');
      expect(reply.proposal!.side, Side.buy);
      expect(reply.verdict!.allowed, true);
    });

    test('kill switch posts enabled flag', () async {
      var sent = <String, dynamic>{};
      final api = ApiClient(
        client: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'trading_enabled': false}), 200);
        }),
      );
      await api.setKillSwitch(false);
      expect(sent['enabled'], false);
    });
  });
}
