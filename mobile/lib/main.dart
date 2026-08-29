import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/models.dart';
import 'state/providers.dart';
import 'ui/screens/dashboard_screen.dart';
import 'ui/screens/copilot_screen.dart';
import 'ui/screens/journal_screen.dart';

void main() {
  runApp(const ProviderScope(child: TraderCopilotApp()));
}

class TraderCopilotApp extends StatelessWidget {
  const TraderCopilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF1B5E20); // deep green — trading, not gambling
    return MaterialApp(
      title: 'Trader Copilot',
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed,
          useMaterial3: true,
          brightness: Brightness.dark),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [
      DashboardScreen(),
      CopilotScreen(),
      JournalScreen(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trader Copilot'),
        actions: const [ModeToggle()],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.account_balance_outlined),
              selectedIcon: Icon(Icons.account_balance),
              label: 'Portfolio'),
          NavigationDestination(
              icon: Icon(Icons.psychology_outlined),
              selectedIcon: Icon(Icons.psychology),
              label: 'Copilot'),
          NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'Journal'),
        ],
      ),
    );
  }
}

/// Paper/Live segmented toggle. Live is intentionally gated.
class ModeToggle extends ConsumerWidget {
  const ModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(tradingModeProvider);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SegmentedButton<AccountMode>(
        segments: const [
          ButtonSegment(
              value: AccountMode.paper,
              icon: Icon(Icons.science_outlined),
              label: Text('Paper')),
          ButtonSegment(
              value: AccountMode.live,
              icon: Icon(Icons.account_balance_wallet_outlined),
              label: Text('Live')),
        ],
        selected: {mode},
        onSelectionChanged: (selection) {
          final next = selection.first;
          if (next == AccountMode.live) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Live trading is locked until a broker pack is connected. '
                  'Learn in Paper mode first.'),
            ));
            return; // stay in paper — deliberate gate, not a bug
          }
          ref.read(tradingModeProvider.notifier).set(next);
        },
      ),
    );
  }
}

