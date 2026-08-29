import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/alerts.dart';
import '../../core/engine/coinbase_client.dart';
import '../../state/providers.dart';
import '../theme.dart';

/// Bell button with an unread badge; opens the alert center sheet.
class AlertBell extends ConsumerWidget {
  const AlertBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadAlertsProvider);
    return IconButton(
      tooltip: 'Alerts',
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text('$unread'),
        child: const Icon(Icons.notifications_outlined, size: 22),
      ),
      onPressed: () => showAlertCenter(context, ref),
    );
  }
}

Future<void> showAlertCenter(BuildContext context, WidgetRef ref) {
  ref.read(unreadAlertsProvider.notifier).clear();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _AlertSheet(),
  );
}

class _AlertSheet extends ConsumerStatefulWidget {
  const _AlertSheet();

  @override
  ConsumerState<_AlertSheet> createState() => _AlertSheetState();
}

class _AlertSheetState extends ConsumerState<_AlertSheet> {
  String _symbol = 'BTC';
  AlertMetric _metric = AlertMetric.price;
  AlertOp _op = AlertOp.above;
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final v = double.tryParse(_value.text.trim());
    if (v == null || v <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a valid threshold value.')));
      return;
    }
    HapticFeedback.selectionClick();
    await ref.read(alertsProvider.notifier).add(
        symbol: _symbol, metric: _metric, op: _op, value: v);
    _value.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Alert created: '
              '$_symbol ${_metric.name} ${_op.name} $v')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(alertsProvider);
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Price & indicator alerts',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('Checked every 30s against LIVE Coinbase data.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Flexible(
                child: rules.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text('No alerts yet. Create one below.',
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in rules)
                            ListTile(
                              leading: Icon(
                                r.metric == AlertMetric.price
                                    ? Icons.price_change_outlined
                                    : Icons.show_chart,
                                color: TC.info,
                              ),
                              title: Text(r.describe()),
                              subtitle: Text(r.triggeredOnce
                                  ? 'Triggered — re-arms on next crossing'
                                  : 'Watching…'),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20),
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  ref
                                      .read(alertsProvider.notifier)
                                      .remove(r.id);
                                },
                              ),
                            ),
                        ],
                      ),
              ),
              const Divider(),
              Text('New alert', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _AlertForm(
                symbol: _symbol,
                metric: _metric,
                op: _op,
                value: _value,
                onSymbol: (v) => setState(() => _symbol = v),
                onMetric: (v) => setState(() => _metric = v),
                onOp: (v) => setState(() => _op = v),
                onCreate: _create,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertForm extends StatelessWidget {
  const _AlertForm({
    required this.symbol,
    required this.metric,
    required this.op,
    required this.value,
    required this.onSymbol,
    required this.onMetric,
    required this.onOp,
    required this.onCreate,
  });

  final String symbol;
  final AlertMetric metric;
  final AlertOp op;
  final TextEditingController value;
  final ValueChanged<String> onSymbol;
  final ValueChanged<AlertMetric> onMetric;
  final ValueChanged<AlertOp> onOp;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DropdownButton<String>(
              value: symbol,
              items: [
                for (final s in coinbaseProducts)
                  DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: (v) => onSymbol(v ?? 'BTC'),
              underline: const SizedBox.shrink(),
            ),
            ChoiceChip(
              label: const Text('Price'),
              selected: metric == AlertMetric.price,
              onSelected: (_) => onMetric(AlertMetric.price),
            ),
            ChoiceChip(
              label: const Text('RSI'),
              selected: metric == AlertMetric.rsi,
              onSelected: (_) => onMetric(AlertMetric.rsi),
            ),
            ChoiceChip(
              label: const Text('≥ above'),
              selected: op == AlertOp.above,
              onSelected: (_) => onOp(AlertOp.above),
            ),
            ChoiceChip(
              label: const Text('≤ below'),
              selected: op == AlertOp.below,
              onSelected: (_) => onOp(AlertOp.below),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: value,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText:
                metric == AlertMetric.price ? 'Price in ₹ (e.g. 5400000)' : 'RSI value (e.g. 70)',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.add_alert, size: 18),
          label: const Text('Create alert'),
          onPressed: onCreate,
        ),
      ],
    );
  }
}
