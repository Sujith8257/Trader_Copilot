import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/models.dart';
import 'state/providers.dart';
import 'ui/screens/dashboard_screen.dart';
import 'ui/screens/agent_screen.dart';
import 'ui/screens/copilot_screen.dart';
import 'ui/screens/journal_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/settings_screen.dart';
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
      home: const BootGate(),
    );
  }
}

/// First-launch gate. Shows OnboardingScreen until the user taps
/// "Get Started" (which sets seen_onboarding=true and refreshes the provider),
/// then hands off to HomeShell for every launch thereafter.
class BootGate extends ConsumerWidget {
  const BootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seen = ref.watch(startupPrefsProvider);
    return seen.when(
      loading: () => const _Splash(),
      error: (_, _) => const HomeShell(),
      data: (seen) => seen ? const HomeShell() : const OnboardingScreen(),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: TC.bg,
      body: Center(child: CircularProgressIndicator(color: TC.gain)),
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
  _Dest(Icons.smart_toy_outlined, Icons.smart_toy, 'Agent'),
  _Dest(Icons.psychology_outlined, Icons.psychology, 'Copilot'),
  _Dest(Icons.menu_book_outlined, Icons.menu_book, 'Journal'),
];

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    final pages = const [
      DashboardScreen(),
      AgentScreen(),
      CopilotScreen(),
      JournalScreen(),
    ];

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
          actions: const [_SettingsButton(), ModeToggle()],
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

/// Opens the on-phone Settings: LLM brain, Coinbase credentials, risk config.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Settings',
      icon: const Icon(Icons.tune, size: 20),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}

/// Paper/Live mode chip. Live unlocks once Coinbase credentials exist in
/// Settings; otherwise the sheet explains what to do.
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
    final mode = ref.watch(tradingModeProvider);
    final coinbaseReady =
        ref.watch(tradingServiceProvider).settings.coinbaseConfigured;
    final killEnabled = ref.watch(killSwitchProvider);
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Trading mode'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.science_outlined, color: TC.gain),
                title: const Text('Paper'),
                subtitle: const Text('₹10,00,000 virtual cash, LIVE prices'),
                trailing: mode == AccountMode.paper
                    ? const Icon(Icons.check, color: TC.gain)
                    : null,
                onTap: () {
                  ref.read(tradingModeProvider.notifier).set(AccountMode.paper);
                  Navigator.of(context).pop();
                },
              ),
              ListTile(
                leading: Icon(
                  coinbaseReady ? Icons.currency_bitcoin : Icons.lock_outline,
                  color: coinbaseReady ? TC.warn : TC.onBgDim,
                ),
                title: const Text('Live'),
                subtitle: Text(coinbaseReady
                    ? 'REAL Coinbase orders — double-check everything'
                    : 'Add your Coinbase API key in Settings to unlock'),
                trailing: mode == AccountMode.live
                    ? const Icon(Icons.check, color: TC.warn)
                    : null,
                onTap: () {
                  if (coinbaseReady) {
                    ref
                        .read(tradingModeProvider.notifier)
                        .set(AccountMode.live);
                    Navigator.of(context).pop();
                  } else {
                    Navigator.of(context).pop();
                    _showLockedDialog(context);
                  }
                },
              ),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Trading enabled'),
                subtitle: const Text(
                    'Kill switch — off blocks EVERY proposal, AI or manual'),
                value: killEnabled,
                activeThumbColor: TC.gain,
                onChanged: (v) {
                  ref.read(tradingServiceProvider).risk.config.enabled = v;
                  setState(() {});
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
      ),
    );
  }

  void _showLockedDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline, color: TC.warn, size: 32),
        title: const Text('Live trading needs Coinbase'),
        content: const Text(
          'Live mode places REAL market orders through Coinbase Advanced '
          'Trade. Open Settings (tune icon) and paste your CDP API key ID '
          'and private key to unlock it. Until then, Paper mode gives you '
          'the full agentic experience on live prices with virtual cash.',
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

