import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trader_copilot/core/agent/agent_engine.dart';
import 'package:trader_copilot/core/engine/paper_broker.dart';
import 'package:trader_copilot/core/engine/trading_service.dart';
import 'package:trader_copilot/core/models.dart';
import 'package:trader_copilot/main.dart';
import 'package:trader_copilot/state/providers.dart';
import 'fake_market.dart';

/// A stubbed TradingService: injected fake market, canned crew runs and
/// overview. No network, no persistence.
class FakeService extends TradingService {
  FakeService({PaperBroker? broker})
      : super(
            marketClient: FakeMarket(),
            paperBroker: broker ??
                PaperBroker(accountId: 'test', initialCash: 1000000));

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<List<MarketRow>> marketOverview() async => [
        MarketRow(
            symbol: 'BTC', last: 5427000, changePct: 1.2, rsi: 61, trend: 'UP'),
        MarketRow(
            symbol: 'ETH',
            last: 270000,
            changePct: -0.4,
            rsi: 48,
            trend: 'DOWN'),
      ];

  @override
  Future<AgentRunResult> runCrew(String goal,
      {void Function(AgentStep)? onStep}) async {
    final r = AgentRunResult(goal: goal)
      ..brain = 'rule'
      ..reply = 'Top opportunity right now:\n• BTC — ₹54,27,000 · UP';
    r.step('scanner', 'scan_market',
        'Scoring 2 symbols on trend, RSI and momentum…');
    r.step('scanner', 'indicators',
        'BTC: ₹54,27,000 · RSI 61 · trend UP · score 1.95');
    return r;
  }
}

Widget _app(
    {bool onboarded = true, PaperBroker? broker, FakeService? service}) {
  return ProviderScope(
    overrides: [
      tradingServiceProvider
          .overrideWithValue(service ?? FakeService(broker: broker)),
      startupPrefsProvider.overrideWithValue(AsyncData(onboarded)),
    ],
    child: const TraderCopilotApp(),
  );
}

/// Pumps the app with a paper broker that already holds a BTC position so
/// the dashboard has content.
Future<void> _pumpHome(WidgetTester tester) async {
  final broker = PaperBroker(accountId: 'test', initialCash: 975500);
  broker.placeMarketOrder(
      symbol: 'BTC', side: Side.buy, quantity: 0.01, marketPrice: 5400000);
  await tester.pumpWidget(_app(broker: broker));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('dashboard renders account, stats and positions',
      (tester) async {
    await _pumpHome(tester);

    expect(find.text('Paper Trading Account'), findsOneWidget);
    // BTC position marked at the fake live price 60000*1.005*90 = 5427000
    expect(find.text('BTC'), findsWidgets);
    expect(find.textContaining('54,27,000'), findsWidgets);
  });

  testWidgets('live mode stays locked without Coinbase credentials',
      (tester) async {
    await _pumpHome(tester);

    await tester.tap(find.text('Paper'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Live'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Live trading needs Coinbase'), findsWidgets);
    expect(find.text('Paper Trading Account'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('bottom navigation switches to journal', (tester) async {
    await _pumpHome(tester);

    await tester.tap(find.text('Journal'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No trades yet'), findsOneWidget);
  });

  testWidgets('empty portfolio CTA opens the Copilot tab', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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

  testWidgets('agent crew runs a visible tool trace on a suggestion',
      (tester) async {
    await _pumpHome(tester);

    await tester.tap(find.text('Agent'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Scan the market'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // The newest entry is at the bottom of the chat - nudge the list up.
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('scan_market'), findsOneWidget);
    expect(find.textContaining('Top opportunity'), findsOneWidget);
    expect(find.textContaining('BTC'), findsWidgets);
  });

  testWidgets('first launch shows onboarding before the dashboard',
      (tester) async {
    await tester.pumpWidget(_app(onboarded: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Page 1 of the onboarding tour.
    expect(find.text('Agentic Copilot'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Get Started'), findsNothing);

    // Page 2: Risk Engine first.
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Risk Engine first'), findsOneWidget);

    // Page 3: Local-first. The CTA becomes Get Started.
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Local-first'), findsOneWidget);
    expect(find.text('Get Started'), findsOneWidget);
  });
}
