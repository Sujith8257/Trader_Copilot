import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trader_copilot/main.dart';

/// Layout-overflow guards for narrow phones (iQOO 15 ≈ 360–400 logical px).
///
/// Flutter widget tests THROW on a RenderFlex overflow, so every screen we
/// walk here is proven free of the yellow/black overflow stripes that the
/// user saw on the chart screen. The real engine runs; network calls fail
/// fast in tests (mock HTTP 400) so the chrome + empty/error states are what
/// get exercised — exactly where static overflows appear.
void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'seen_onboarding': true}),
  );

  Future<void> pumpPhone(
    WidgetTester tester, {
    double width = 360,
    double height = 800,
  }) async {
    tester.view.physicalSize = Size(width * 2, height * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: TraderCopilotApp()));
    // Bounded pumps (never pumpAndSettle: loading spinners animate while the
    // mocked network resolves, so settle would time out).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('HomeShell chrome renders without overflow at narrow width', (
    tester,
  ) async {
    await pumpPhone(tester);
    // unmount to release the auto-refresh timer before the test ends
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('all four tabs render without overflow', (tester) async {
    await pumpPhone(tester);
    for (final tab in ['Agent', 'Copilot', 'Journal', 'Portfolio']) {
      final f = find.text(tab);
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Settings screen renders without overflow', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('onboarding slides render without overflow', (tester) async {
    SharedPreferences.setMockInitialValues({'seen_onboarding': false});
    await pumpPhone(tester);
    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
