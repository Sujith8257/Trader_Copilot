import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';

/// Manual order ticket (market or limit) — reachable from the chart screen.
/// Every order, manual or AI, passes the SAME deterministic Risk Engine.
Future<void> showOrderTicket(
  BuildContext context,
  WidgetRef ref, {
  required String symbol,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _OrderTicket(symbol: symbol),
  );
}

class _OrderTicket extends ConsumerStatefulWidget {
  const _OrderTicket({required this.symbol});
  final String symbol;

  @override
  ConsumerState<_OrderTicket> createState() => _OrderTicketState();
}

class _OrderTicketState extends ConsumerState<_OrderTicket> {
  Side _side = Side.buy;
  bool _isLimit = false;
  bool _loading = false;
  double? _livePrice;
  String? _error;
  final _qty = TextEditingController();
  final _limit = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchPrice();
  }

  @override
  void dispose() {
    _qty.dispose();
    _limit.dispose();
    super.dispose();
  }

  Future<void> _fetchPrice() async {
    try {
      final svc = ref.read(tradingServiceProvider);
      await svc.ensureLoaded();
      final px = await svc.market.last(widget.symbol);
      if (mounted) {
        setState(() => _livePrice = px);
        _limit.text = px.toStringAsFixed(0);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qty.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Enter a valid quantity.');
      return;
    }
    final price = _isLimit ? double.tryParse(_limit.text.trim()) : _livePrice;
    if (price == null || price <= 0) {
      setState(() => _error = 'Price unavailable — check connection.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(tradingServiceProvider);
      final result = _isLimit
          ? await svc.placeManualLimit(
              symbol: widget.symbol,
              side: _side,
              quantity: qty,
              limitPrice: price,
            )
          : await svc.placeManualMarket(
              symbol: widget.symbol,
              side: _side,
              quantity: qty,
              marketPrice: price,
            );
      HapticFeedback.mediumImpact();
      ref.invalidate(accountProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.executed
                ? (_isLimit
                      ? 'Limit order resting: ${_side.name.toUpperCase()} $qty ${widget.symbol} @ ${formatINR(price)}'
                      : 'Order filled: ${_side.name.toUpperCase()} $qty ${widget.symbol} @ ${formatINR(result.fillPrice ?? price)}')
                : 'Rejected by Risk Engine: ${result.reason ?? "unknown"}',
          ),
          backgroundColor: result.executed
              ? null
              : TC.loss.withValues(alpha: 0.9),
        ),
      );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Trade ${widget.symbol}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  if (_livePrice != null)
                    Chip(
                      avatar: const Icon(Icons.bolt, size: 14, color: TC.gain),
                      label: Text(
                        formatINR(_livePrice!),
                        style: const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<Side>(
                segments: const [
                  ButtonSegment(
                    value: Side.buy,
                    icon: Icon(Icons.north_east, size: 16),
                    label: Text('BUY'),
                  ),
                  ButtonSegment(
                    value: Side.sell,
                    icon: Icon(Icons.south_east, size: 16),
                    label: Text('SELL'),
                  ),
                ],
                selected: {_side},
                onSelectionChanged: (s) => setState(() => _side = s.first),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Market')),
                  ButtonSegment(
                    value: true,
                    label: Text('Limit'),
                    icon: Icon(Icons.schedule, size: 16),
                  ),
                ],
                selected: {_isLimit},
                onSelectionChanged: (s) => setState(() => _isLimit = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _qty,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  hintText: 'Quantity (e.g. 0.01)',
                ),
              ),
              if (_isLimit) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _limit,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Limit price in ₹',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: TC.loss)),
              ],
              const SizedBox(height: 12),
              Text(
                _isLimit
                    ? 'Limit orders rest on the PAPER broker and fill automatically when the live price crosses.'
                    : 'Market orders fill immediately at the live price. Risk Engine checks apply.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt, size: 18),
                label: Text(
                  _loading
                      ? 'Placing…'
                      : '${_side == Side.buy ? 'Buy' : 'Sell'} ${widget.symbol}',
                ),
                onPressed: _loading ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
