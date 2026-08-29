/// Market Intelligence — technical indicators computed in plain Dart,
/// OUTSIDE any LLM. Port of `backend/app/core/indicators.py`. The agent
/// feeds these as structured context to the model (or reasons over them
/// directly), which is far more reliable than asking an LLM to do math.
///
/// Pure functions only — fully unit-testable.
library;

import '../models.dart';

List<double?> sma(List<double> values, int period) {
  final out = List<double?>.filled(values.length, null);
  for (var i = period - 1; i < values.length; i++) {
    var sum = 0.0;
    for (var j = i + 1 - period; j <= i; j++) {
      sum += values[j];
    }
    out[i] = sum / period;
  }
  return out;
}

/// EMA seeded with the SMA of the first `period` values (classic convention).
List<double?> ema(List<double> values, int period) {
  final out = List<double?>.filled(values.length, null);
  if (values.length < period) return out;
  final k = 2.0 / (period + 1);
  double? e;
  for (var i = 0; i < values.length; i++) {
    if (i + 1 < period) continue;
    if (e == null) {
      var sum = 0.0;
      for (var j = 0; j < period; j++) {
        sum += values[j];
      }
      e = sum / period;
    } else {
      e = values[i] * k + e * (1 - k);
    }
    out[i] = e;
  }
  return out;
}

/// Wilder's RSI. Returns null when there is not enough data.
double? rsi(List<double> values, [int period = 14]) {
  if (values.length < period + 1) return null;
  var gains = 0.0, losses = 0.0;
  for (var i = 1; i <= period; i++) {
    final d = values[i] - values[i - 1];
    gains += d > 0 ? d : 0.0;
    losses += d < 0 ? -d : 0.0;
  }
  var ag = gains / period, al = losses / period;
  for (var i = period + 1; i < values.length; i++) {
    final d = values[i] - values[i - 1];
    ag = (ag * (period - 1) + (d > 0 ? d : 0.0)) / period;
    al = (al * (period - 1) + (d < 0 ? -d : 0.0)) / period;
  }
  if (al == 0) return 100.0;
  final rs = ag / al;
  return 100.0 - 100.0 / (1.0 + rs);
}

double? _lastValid(List<double?> series) {
  for (var i = series.length - 1; i >= 0; i--) {
    final v = series[i];
    if (v != null) return v;
  }
  return null;
}

class MacdResult {
  const MacdResult({this.macd, this.signal, this.hist});
  final double? macd;
  final double? signal;
  final double? hist;
}

MacdResult macd(
  List<double> values, {
  int fast = 12,
  int slow = 26,
  int signal = 9,
}) {
  final ef = ema(values, fast), es = ema(values, slow);
  final line = List<double?>.generate(values.length, (i) {
    final a = ef[i], b = es[i];
    return (a == null || b == null) ? null : a - b;
  });
  final compact = line.whereType<double>().toList();
  final List<double?> sig;
  if (compact.length >= signal) {
    sig = ema(compact, signal);
  } else {
    sig = List<double?>.filled(compact.length, null);
  }
  double? lastSig;
  for (var i = sig.length - 1; i >= 0; i--) {
    if (sig[i] != null) {
      lastSig = sig[i];
      break;
    }
  }
  final m = _lastValid(line);
  final s = lastSig;
  return MacdResult(
    macd: m,
    signal: s,
    hist: (m == null || s == null) ? null : m - s,
  );
}

class BollingerResult {
  const BollingerResult({this.mid, this.upper, this.lower});
  final double? mid, upper, lower;
}

BollingerResult bollinger(
  List<double> values, [
  int period = 20,
  double k = 2.0,
]) {
  if (values.length < period) {
    return const BollingerResult();
  }
  final window = values.sublist(values.length - period);
  final mid = window.reduce((a, b) => a + b) / period;
  var variance = 0.0;
  for (final x in window) {
    variance += (x - mid) * (x - mid);
  }
  variance /= period;
  final sd = variance <= 0 ? 0.0 : _sqrt(variance);
  return BollingerResult(mid: mid, upper: mid + k * sd, lower: mid - k * sd);
}

double _sqrt(double x) {
  if (x <= 0) return 0;
  var guess = x;
  for (var i = 0; i < 40; i++) {
    guess = 0.5 * (guess + x / guess);
  }
  return guess;
}

/// Average True Range (Wilder smoothing). Null when not enough data.
double? atr(
  List<double> highs,
  List<double> lows,
  List<double> closes, [
  int period = 14,
]) {
  final n = closes.length;
  if (n < period + 1) return null;
  final trs = <double>[];
  for (var i = 1; i < n; i++) {
    trs.add(
      _max3(
        highs[i] - lows[i],
        (highs[i] - closes[i - 1]).abs(),
        (lows[i] - closes[i - 1]).abs(),
      ),
    );
  }
  var a = 0.0;
  for (var i = 0; i < period; i++) {
    a += trs[i];
  }
  a /= period;
  for (var i = period; i < trs.length; i++) {
    a = (a * (period - 1) + trs[i]) / period;
  }
  return a;
}

double _max3(double a, double b, double c) {
  var m = a;
  if (b > m) m = b;
  if (c > m) m = c;
  return m;
}

/// One structured indicator snapshot from OHLCV bars — the exact payload the
/// agent gives the LLM (or reasons over itself). ATR-based stop/target
/// levels (2x risk / 3x reward).
Map<String, dynamic> snapshot(List<Candle> bars) {
  final closes = bars.map((b) => b.close).toList();
  final highs = bars.map((b) => b.high).toList();
  final lows = bars.map((b) => b.low).toList();
  final last = closes.last;
  final prev = closes.length > 1 ? closes[closes.length - 2] : last;
  final e20 = _lastValid(ema(closes, 20));
  final e50 = _lastValid(ema(closes, 50));
  final r = rsi(closes);
  final m = macd(closes);
  final bb = bollinger(closes);
  final a = atr(highs, lows, closes);
  final stop = a != null ? last - 2 * a : last * 0.98;
  final target = a != null ? last + 3 * a : last * 1.03;
  return {
    'last': _round2(last),
    'change_pct': prev > 0 ? _round2((last / prev - 1) * 100) : 0.0,
    'rsi': r == null ? null : _round1(r),
    'ema20': e20 == null ? null : _round2(e20),
    'ema50': e50 == null ? null : _round2(e50),
    'trend': (e20 != null && e50 != null && e20 > e50) ? 'UP' : 'DOWN',
    'macd': m.macd == null ? null : _round3(m.macd!),
    'macd_hist': m.hist == null ? null : _round3(m.hist!),
    'bb_upper': bb.upper == null ? null : _round2(bb.upper!),
    'bb_lower': bb.lower == null ? null : _round2(bb.lower!),
    'atr': a == null ? null : _round2(a),
    'stop': _round2(stop),
    'target': _round2(target),
  };
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
double _round1(double v) => (v * 10).roundToDouble() / 10;
double _round3(double v) => (v * 1000).roundToDouble() / 1000;
