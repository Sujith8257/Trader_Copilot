/// Price & indicator alerts — checked on every auto-refresh tick against
/// LIVE Coinbase data. Triggered alerts surface in the in-app alert center
/// (bell icon) with a badge + snackbar. No fabricated data: an alert only
/// fires when a real fetched price/RSI crosses the threshold.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum AlertMetric { price, rsi }

enum AlertOp { above, below }

class AlertRule {
  AlertRule({
    required this.id,
    required this.symbol,
    required this.metric,
    required this.op,
    required this.value,
    this.triggeredAt,
  });

  final String id;
  final String symbol; // e.g. BTC
  final AlertMetric metric;
  final AlertOp op;
  final double value;
  DateTime? triggeredAt; // set when last fired

  bool get triggeredOnce => triggeredAt != null;

  String describe() =>
      '$symbol ${metric == AlertMetric.price ? 'price' : 'RSI'} '
      '${op == AlertOp.above ? '≥' : '≤'} '
      '${metric == AlertMetric.price ? value.toStringAsFixed(0) : value.toStringAsFixed(1)}';

  Map<String, dynamic> toMap() => {
    'id': id,
    'symbol': symbol,
    'metric': metric.name,
    'op': op.name,
    'value': value,
    'triggered_at': triggeredAt?.toIso8601String(),
  };

  static AlertRule fromMap(Map<String, dynamic> m) => AlertRule(
    id: m['id'] as String,
    symbol: (m['symbol'] as String).toUpperCase(),
    metric: (m['metric'] as String? ?? 'price') == 'rsi'
        ? AlertMetric.rsi
        : AlertMetric.price,
    op: (m['op'] as String? ?? 'above') == 'below'
        ? AlertOp.below
        : AlertOp.above,
    value: (m['value'] as num).toDouble(),
    triggeredAt: DateTime.tryParse(m['triggered_at'] as String? ?? ''),
  );
}

class AlertEngine {
  AlertEngine();

  static const _pref = 'engine_alerts';
  final List<AlertRule> rules = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_pref);
    if (raw != null) {
      rules
        ..clear()
        ..addAll([
          for (final e in jsonDecode(raw) as List)
            AlertRule.fromMap(Map<String, dynamic>.from(e as Map)),
        ]);
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_pref, jsonEncode([for (final r in rules) r.toMap()]));
  }

  Future<AlertRule> add({
    required String symbol,
    required AlertMetric metric,
    required AlertOp op,
    required double value,
  }) async {
    await load();
    final r = AlertRule(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      symbol: symbol.toUpperCase(),
      metric: metric,
      op: op,
      value: value,
    );
    rules.add(r);
    await _persist();
    return r;
  }

  Future<void> remove(String id) async {
    await load();
    rules.removeWhere((r) => r.id == id);
    await _persist();
  }

  /// Evaluate every rule against live prices (INR) / RSI values.
  /// Returns the rules that fired THIS tick (re-arm after firing: a rule
  /// only re-fires when the condition first becomes true again).
  Future<List<AlertRule>> check({
    required Map<String, double> prices,
    required Map<String, double> rsi,
  }) async {
    await load();
    final fired = <AlertRule>[];
    var dirty = false;
    for (final r in rules) {
      final v = r.metric == AlertMetric.price
          ? prices[r.symbol]
          : rsi[r.symbol];
      if (v == null) continue;
      final hit = r.op == AlertOp.above ? v >= r.value : v <= r.value;
      if (hit && !r.triggeredOnce) {
        r.triggeredAt = DateTime.now();
        fired.add(r);
        dirty = true;
      } else if (!hit && r.triggeredOnce) {
        r.triggeredAt = null; // re-arm
        dirty = true;
      }
    }
    if (dirty) await _persist();
    return fired;
  }
}
