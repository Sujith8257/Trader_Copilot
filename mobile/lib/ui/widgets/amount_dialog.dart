import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/models.dart';

/// Ask the user HOW MUCH (₹) to invest before executing an AI proposal.
/// Quantity is derived from the live price by the service layer; the Risk
/// Engine re-checks the resized order. Returns the chosen amount or null.
Future<double?> showAmountDialog(
  BuildContext context, {
  required String symbol,
  required Side side,
  required double marketPrice,
  double? suggestedAmount,
}) {
  final controller = TextEditingController(
    text: suggestedAmount == null
        ? ''
        : suggestedAmount.toStringAsFixed(0),
  );
  return showDialog<double>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${side == Side.buy ? 'Buy' : 'Sell'} $symbol — how much?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the amount in ₹ to ${side == Side.buy ? 'invest' : 'exit'}. '
            'Quantity is calculated from the live price '
            '(1 ${symbol.trim().toUpperCase()} = ${formatINR(marketPrice)}).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Amount (₹)',
              prefixText: '₹ ',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The Risk Engine checks the resized order before anything executes.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = double.tryParse(controller.text.trim());
            if (v == null || v <= 0) return;
            Navigator.of(context).pop(v);
          },
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}
