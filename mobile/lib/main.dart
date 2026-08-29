import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/models.dart';
import 'state/providers.dart';
import 'ui/screens/dashboard_screen.dart';
import 'ui/screens/copilot_screen.dart';
import 'ui/screens/journal_screen.dart';
import 'ui/theme.dart';

void main() => runApp(const ProviderScope(child: TraderCopilotApp()));

class TraderCopilotApp extends StatelessWidget {
  const TraderCopilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trader Copilot',
      debugShowCheckedModeBanner: false,
      theme: TC.dark(),
      themeMode: ThemeMode.dark,
      home: const HomeShell(),
    );
  }
}

class _Dest {
  const _Dest(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const _dests = [
  _Dest(Icons.account_balance_outlined, Icons.account_balance, 'Portfolio'),
  _Dest(Icons.psychology_outlined, Icons.psychology, 'Copilot'),
  _Dest(Icons.menu_book_outlined, Icons.menu_book, 'Journal'),
];

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    final pages = const [DashboardScreen(), CopilotScreen(), JournalScreen()];

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      void setTab(int i) => ref.read(tabIndexProvider.notifier).set(i);

      final body = wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: setTab,
                  labelType: NavigationRailLabelType.all,
                  leading: const _BrandBadge(size: 40),
                  destinations: [
                    for (final d in _dests)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, color: TC.outline),
                Expanded(child: pages[index]),
              ],
            )
          : pages[index];

      return Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              _BrandBadge(size: 34),
              SizedBox(width: 10),
              Text('Trader Copilot'),
            ],
          ),
          actions: const [ModeToggle()],
        ),
        body: body,
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: index,
                onDestinationSelected: setTab,
                destinations: [
                  for (final d in _dests)
                    NavigationDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: d.label,
                    ),
                ],
              ),
      );
    });
  }
}

class _BrandBadge extends StatelessWidget {
  const _BrandBadge({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: TC.heroGradient,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: TC.outline),
      ),
      child: Icon(Icons.candlestick_chart, size: size * 0.55, color: TC.gain),
    );
  }
}

/// Paper/Live mode chip. Live is intentionally gated — the switcher explains
/// why, and selecting Live shows a locked dialog instead of switching.
class ModeToggle extends ConsumerWidget {
  const ModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(tradingModeProvider);
    final isPaper = mode == AccountMode.paper;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Material(
        color: TC.surfaceHi,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _showModeSheet(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  isPaper ? Icons.science_outlined : Icons.lock_outline,
                  size: 16,
                  color: isPaper ? TC.gain : TC.warn,
                ),
                const SizedBox(width: 6),
                Text(
                  isPaper ? 'Paper' : 'Live',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TC.onBg,
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 18, color: TC.onBgDim),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showModeSheet(BuildContext context, WidgetRef ref) {
    final mode = ref.read(tradingModeProvider);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trading mode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.science_outlined, color: TC.gain),
              title: const Text('Paper'),
              subtitle: const Text('₹10,00,000 virtual cash, real prices'),
              trailing: mode == AccountMode.paper
                  ? const Icon(Icons.check, color: TC.gain)
                  : null,
              onTap: () {
                ref.read(tradingModeProvider.notifier).set(AccountMode.paper);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline, color: TC.warn),
              title: const Text('Live'),
              subtitle: const Text('Requires a broker pack — locked'),
              onTap: () {
                Navigator.of(context).pop();
                _showLockedDialog(context);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showLockedDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline, color: TC.warn, size: 32),
        title: const Text('Live trading is locked'),
        content: const Text(
          'Live trading is locked until a broker pack is connected. '
          'Learn in Paper mode first — every Trader Copilot account starts '
          'with paper money so you can practice safely.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

