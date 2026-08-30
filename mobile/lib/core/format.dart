/// Shared helpers for Indian-rupee money formatting (₹ with lakh/crore
/// grouping, e.g. 10,00,000) used across the Trader Copilot UI.
library;

/// Formats [v] as `₹9,75,500` (Indian digit grouping, no decimals by default).
String formatINR(num v, {int decimals = 0}) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(decimals);
  final dot = s.indexOf('.');
  final digits = dot == -1 ? s : s.substring(0, dot);
  final frac = dot == -1 ? '' : s.substring(dot); // includes '.'
  String grouped;
  if (digits.length <= 3) {
    grouped = digits;
  } else {
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    grouped = '${groups.join(',')},$last3';
  }
  return '${neg ? '-' : ''}₹$grouped$frac';
}

/// `+₹500` / `-₹120` — for P&L displays.
String formatSignedINR(num v, {int decimals = 0}) =>
    '${v >= 0 ? '+' : ''}${formatINR(v, decimals: decimals)}';

/// Coin quantities with no floating-point noise: 0.0034000000000000005
/// becomes '0.0034' and 2.0 becomes '2'. Up to 8 decimals, zeros trimmed.
String formatQty(num v) {
  var s = v.toStringAsFixed(8);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}
