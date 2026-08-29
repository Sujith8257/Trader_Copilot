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

ApiClient _fakeApi({Map<String, dynamic>? positions}) {
  return ApiClient(
    client: MockClient((request) async {
      if (request.url.path == '/account') {
        return _ok({
          'account_id': 'paper-primary',
          'mode': 'PAPER',
          'cash': 975500.0,
          'equity': 1000500.0,
          'day_start_equity': 1000000.0,
          'positions': positions ??
            {
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

Widget _app({Map<String, dynamic>? positions}) => ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(_fakeApi(positions: positions))],
      child: const TraderCopilotApp(),
    );

/// Pumps the app and waits for the account future. Uses explicit pumps (not
/// pumpAndSettle) because the skeleton loader animates indefinitely.
Future<void> _pumpHome(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.pump(); // start frame (loading skeleton)
  await tester.pump(const Duration(milliseconds: 400)); // future resolves
}

void main() {
  testWidgets('dashboard renders account, stats and positions',
      (tester) async {
    await _pumpHome(tester);

    expect(find.text('Paper Trading Account'), findsOneWidget);
    // equity = cash 975,500 + 10 @ 2,500 = 10,00,500 (Indian grouping)
    expect(find.text('₹10,00,500'), findsOneWidget);
    // cash appears in the stat tile AND the allocation legend
    expect(find.text('₹9,75,500'), findsNWidgets(2));
    // exposure appears in its stat tile, the position tile and the legend
    expect(find.text('₹25,000'), findsNWidgets(3));
    expect(find.text('RELIANCE'), findsWidgets);
    // unrealized pnl +500 → position chip; day delta also +500 today
    expect(find.text('+₹500'), findsOneWidget);
    expect(find.text('+₹500 today'), findsOneWidget);
  });

  testWidgets('live mode is gated — selecting Live shows the locked dialog',
      (tester) async {
    await _pumpHome(tester);

    // Open the mode switcher chip in the app bar.
    await tester.tap(find.text('Paper'));
    await tester.pump(const Duration(milliseconds: 300));

    // Pick Live → locked dialog explains the gate; mode stays paper.
    await tester.tap(find.text('Live'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Live trading is locked'), findsWidgets);
    expect(find.text('Paper Trading Account'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('bottom navigation switches to journal', (tester) async {
    await _pumpHome(tester);

    await tester.tap(find.text('Journal'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No trades yet'), findsOneWidget);
    expect(find.text('Session journal'), findsNothing);
  });

  testWidgets('empty portfolio CTA opens the Copilot tab', (tester) async {
    await tester.pumpWidget(_app(positions: {}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The empty state sits below the hero + allocation cards — scroll to it.
    await tester.scrollUntilVisible(
      find.text('Open Copilot'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Open Copilot'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Propose a trade'), findsOneWidget);
  });
}
