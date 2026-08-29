import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trader_copilot/main.dart';
import 'package:trader_copilot/ui/theme.dart';
import 'package:trader_copilot/ui/widgets/common.dart';

/// Widget tests use the REAL app with the REAL engine. Only network-free
/// surfaces are exercised here (onboarding, design-system widgets); the
/// trading engine itself is covered by engine_test.dart.
Widget _app({bool onboarded = false}) {
  SharedPreferences.setMockInitialValues({'seen_onboarding': onboarded});
  return ProviderScope(child: const TraderCopilotApp());
}

void main() {
  testWidgets('first launch shows the onboarding tour', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Page 1 of the onboarding tour.
    expect(find.text('Agentic Copilot'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Get Started'), findsNothing);

    // Page 2: Risk Engine first.
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Risk Engine first'), findsOneWidget);

    // Page 3: the CTA becomes Get Started.
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Get Started'), findsOneWidget);
  });

  testWidgets('PnlChip colors gains green and losses red', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Column(children: [PnlChip(500), PnlChip(-250)])),
      ),
    );
    expect(find.text('+₹500'), findsOneWidget);
    expect(find.text('-₹250'), findsOneWidget);
  });

  testWidgets('StatTile renders label and value', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StatTile(
            label: 'Cash',
            value: '₹10,00,000',
            icon: Icons.wallet,
          ),
        ),
      ),
    );
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('₹10,00,000'), findsOneWidget);
  });

  testWidgets('Sparkline paints with a flat series too', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Sparkline(values: [5, 5, 5, 5])),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CustomPaint), findsWidgets);
    expect(TC.gain, const Color(0xFF34D399)); // design token sanity
  });
}
