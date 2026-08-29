import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/providers.dart';
import '../theme.dart';

/// First-launch onboarding. The AI proposes; the Risk Engine decides; you
/// approve. Nothing here is collected — everything runs on your device.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;

  static const _pages = [
    _Page(
      icon: Icons.psychology_outlined,
      title: 'Agentic Copilot',
      body: 'I observe the market, think it through with visible tools, and '
          'draft a structured TradeProposal. I never execute on my own - '
          'every draft is only a suggestion.',
    ),
    _Page(
      icon: Icons.shield_outlined,
      title: 'Risk Engine first',
      body: 'Every proposal runs through 12 deterministic checks (position '
          'size, exposure, stop-loss, daily loss, kill switch...). '
          'Only an ALLOWED verdict + your tap can fill an order.',
    ),
    _Page(
      icon: Icons.phone_iphone_outlined,
      title: 'Local-first',
      body: 'Runs offline with a seeded market. Bring your own model via the '
          'Model Hub (Ollama / llama.cpp) or set OPENAI_API_KEY for cloud.',
    ),
  ];

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('seen_onboarding', true);
    ref.invalidate(startupPrefsProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TC.bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _page,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  for (final p in _pages) _buildPage(context, p),
                ],
              ),
            ),
            _Dots(index: _index, total: _pages.length),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _finish,
                    child: const Text('Skip'),
                  ),
                  const Spacer(),
                  _index == _pages.length - 1
                      ? FilledButton.icon(
                          onPressed: _finish,
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          label: const Text('Get Started'),
                        )
                      : TextButton(
                          onPressed: () => _page.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut),
                          child: const Text('Next'),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context, _Page p) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: TC.surfaceHi,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: TC.outline),
              ),
              child: Icon(p.icon, size: 40, color: TC.info),
            ),
            const SizedBox(height: 28),
            Text(p.title,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            Text(p.body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: TC.onBgDim,
                      height: 1.5,
                    )),
          ],
        ),
      );
}

class _Page {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.total});
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < total; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == index ? 22 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? TC.gain : TC.outline,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}
