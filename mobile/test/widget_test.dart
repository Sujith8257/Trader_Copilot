import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:trader_copilot/core/api_client.dart';
import 'package:trader_copilot/main.dart';
import 'package:trader_copilot/state/providers.dart';

http.Response _ok(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200);

ApiClient _fakeApi() {
  return ApiClient(
    client: MockClient((request) async {
      if (request.url.path == '/account') {
        return _ok({
          'account_id': 'paper-primary',
          'mode': 'PAPER',
          'cash': 975500.0,
          'equity': 1000000.0,
          'positions': {
            'RELIANCE': {'qty': 10, 'avg': 2450.0, 'last': 2500.0},
          },
        });
      }
      if (request.url.path == '/health') {
        return _ok({
          'status': 'ok',
          'risk_engine_enabled': true,
          'paper_broker': 'HEALTHY',
        });
      }
      return _ok({});
    }),
  );
}

Widget _app() => ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(_fakeApi())],
      child: const TraderCopilotApp(),
    );

void main() {
  testWidgets('dashboard renders account and position from backend',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Trader Copilot'), findsOneWidget);
    expect(find.text('PAPER ACCOUNT'), findsOneWidget);
    expect(find.text('RELIANCE'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
    // unrealized pnl +500.00 (10 * (2500 - 2450))
    expect(find.text('+500.00'), findsOneWidget);
  });

  testWidgets('live mode is gated — tapping Live stays in Paper',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    // Still in paper mode: banner unchanged, snackbar explains the gate.
    expect(find.text('PAPER ACCOUNT'), findsOneWidget);
    expect(find.textContaining('Live trading is locked'), findsOneWidget);
  });

  testWidgets('bottom navigation switches to journal', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Journal'));
    await tester.pumpAndSettle();

    expect(find.text('No trades yet.'), findsOneWidget);
  });
}

