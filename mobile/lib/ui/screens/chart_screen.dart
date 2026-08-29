import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/alert_center.dart';
import '../widgets/order_ticket.dart';

/// Full-screen candlestick chart for one symbol — LIVE Coinbase OHLCV in INR.
/// Timeframes: 1H / 6H / 1D. Drag across the chart to scrub any bar (OHLC
/// readout), pin to watchlist, place a market/limit order, or create an alert.
class ChartScreen extends ConsumerStatefulWidget {
  const ChartScreen({super.key, required this.symbol});

  final String symbol;

  @override
  ConsumerState<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends ConsumerState<ChartScreen> {
  late Future<CandleSeries> _future;
  int _range = 90;
  String _granularity = 'ONE_DAY';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final svc = ref.read(tradingServiceProvider);
    _future = svc.ensureLoaded().then((_) async {
      final bars = await svc.market.bars(
        widget.symbol,
        granularity: _granularity,
      );
      return CandleSeries(
        symbol: widget.symbol.toUpperCase(),
        market: Market.crypto,
        source: 'coinbase-live',
        bars: bars,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.symbol),
        actions: [
          IconButton(
            tooltip: 'Trade',
            icon: const Icon(Icons.bolt, size: 20),
            onPressed: () =>
                showOrderTicket(context, ref, symbol: widget.symbol),
          ),
          IconButton(
            tooltip: 'Create alert',
            icon: const Icon(Icons.add_alert_outlined, size: 20),
            onPressed: () => showAlertCenter(context, ref),
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(_load),
          ),
        ],
      ),
      body: FutureBuilder<CandleSeries>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ErrorView(
              error: '${snap.error}',
              onRetry: () => setState(_load),
            );
          }
          final series = snap.data!;
          if (series.bars.isEmpty) {
            return const Center(child: Text('No data for this symbol.'));
          }
          return _ChartBody(
            series: series,
            range: _range,
            granularity: _granularity,
            onRange: (r) => setState(() => _range = r),
            onGranularity: (g) => setState(() {
              _granularity = g;
              _load();
            }),
          );
        },
      ),
    );
  }
}

class _ChartBody extends ConsumerStatefulWidget {
  const _ChartBody({
    required this.series,
    required this.range,
    required this.granularity,
    required this.onRange,
    required this.onGranularity,
  });

  final CandleSeries series;
  final int range;
  final String granularity;
  final ValueChanged<int> onRange;
  final ValueChanged<String> onGranularity;

  @override
  ConsumerState<_ChartBody> createState() => _ChartBodyState();
}

class _ChartBodyState extends ConsumerState<_ChartBody> {
  int? _scrub; // bar index under the finger; null = show the live bar

  @override
  Widget build(BuildContext context) {
    final bars = widget.series.bars.length > widget.range
        ? widget.series.bars.sublist(widget.series.bars.length - widget.range)
        : widget.series.bars;
    final last = bars.last;
    final first = bars.first;
    final changePct = (last.close / first.close - 1) * 100;
    final isLive = widget.series.source.contains('coinbase');
    final shown = _scrub == null || _scrub! >= bars.length
        ? last
        : bars[_scrub!];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Text(
                formatINR(shown.close),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(width: 10),
              Text(
                '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%',
                style: TextStyle(
                  color: changePct >= 0 ? TC.gain : TC.loss,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Chip(
                avatar: Icon(
                  isLive ? Icons.bolt : Icons.science_outlined,
                  size: 14,
                  color: isLive ? TC.gain : TC.warn,
                ),
                label: Text(
                  isLive ? 'LIVE Coinbase' : 'simulated',
                  style: const TextStyle(fontSize: 11),
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final g in const [
                  ('1H', 'ONE_HOUR'),
                  ('6H', 'SIX_HOUR'),
                  ('1D', 'ONE_DAY'),
                ]) ...[
                  ChoiceChip(
                    label: Text(g.$1),
                    selected: widget.granularity == g.$2,
                    onSelected: (_) => widget.onGranularity(g.$2),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                ],
                const SizedBox(width: 8),
                for (final r in const [30, 60, 90]) ...[
                  ChoiceChip(
                    label: Text('$r'),
                    selected: widget.range == r,
                    onSelected: (_) => widget.onRange(r),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _scrub == null
                  ? 'O ${formatINR(shown.open)}   H ${formatINR(shown.high)}   '
                        'L ${formatINR(shown.low)}   C ${formatINR(shown.close)}'
                  : '${shown.time.toLocal().toString().substring(0, 10)}   '
                        'O ${formatINR(shown.open)}   H ${formatINR(shown.high)}   '
                        'L ${formatINR(shown.low)}   C ${formatINR(shown.close)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
            child: GestureDetector(
              onHorizontalDragUpdate: (d) =>
                  _scrubTo(d.localPosition.dx, bars.length),
              onTapDown: (d) => _scrubTo(d.localPosition.dx, bars.length),
              onHorizontalDragEnd: (_) => setState(() => _scrub = null),
              child: CustomPaint(
                painter: CandlePainter(
                  bars: bars,
                  highlight: _scrub == null ? -1 : _scrub!,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text('Ask Copilot about ${widget.series.symbol}'),
              onPressed: () {
                ref.read(tabIndexProvider.notifier).set(1);
                Navigator.of(context).pop();
              },
            ),
          ),
        ),
      ],
    );
  }

  void _scrubTo(double dx, int count) {
    final width = context.size?.width ?? 1;
    final idx = ((dx / width) * count).floor().clamp(0, count - 1);
    HapticFeedback.selectionClick();
    setState(() => _scrub = idx);
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 40, color: TC.onBgDim),
          const SizedBox(height: 12),
          Text(
            'Could not load candles',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TC.onBgDim, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class CandlePainter extends CustomPainter {
  CandlePainter({required this.bars, this.highlight = -1});

  final List<Candle> bars;
  final int highlight; // index to outline while scrubbing (-1 = none)

  static const _gridLines = 4;
  static const _volumeFraction = 0.16; // bottom band reserved for volume

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final plot = Offset(48, 8) & Size(size.width - 58, size.height - 8);
    final priceBottom = plot.bottom - plot.height * _volumeFraction;
    final priceRect = Rect.fromLTRB(
      plot.left,
      plot.top,
      plot.right,
      priceBottom,
    );
    final volumeRect = Rect.fromLTRB(
      plot.left,
      priceBottom + 6,
      plot.right,
      plot.bottom,
    );

    final lows = bars.map((b) => b.low).reduce(_min);
    final highs = bars.map((b) => b.high).reduce(_max);
    final span = (highs - lows) <= 0 ? highs * 0.01 : highs - lows;
    final pad = span * 0.06;
    final yMin = lows - pad;
    final yMax = highs + pad;

    double yOf(double price) =>
        priceRect.bottom - (price - yMin) / (yMax - yMin) * priceRect.height;

    final maxVol = bars
        .map((b) => b.volume ?? 0)
        .reduce(_max)
        .clamp(1e-9, double.infinity);
    double yVol(double v) =>
        volumeRect.bottom - (v / maxVol) * volumeRect.height;

    // grid + price labels
    final grid = Paint()
      ..color = TC.outline.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var i = 0; i <= _gridLines; i++) {
      final t = i / _gridLines;
      final y = priceRect.top + t * priceRect.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final price = yMax - t * (yMax - yMin);
      _label(canvas, formatINR(price), Offset(2, y - 6));
    }

    // candles + volume
    final n = bars.length;
    final slot = priceRect.width / n;
    final bodyW = (slot * 0.62).clamp(1.5, 14.0);
    final upPaint = Paint()..color = TC.gain;
    final downPaint = Paint()..color = TC.loss;
    final upVol = Paint()..color = TC.gain.withValues(alpha: 0.35);
    final downVol = Paint()..color = TC.loss.withValues(alpha: 0.35);

    for (var i = 0; i < n; i++) {
      final b = bars[i];
      final x = priceRect.left + slot * (i + 0.5);
      final paint = b.bullish ? upPaint : downPaint;
      final vPaint = b.bullish ? upVol : downVol;

      canvas.drawLine(Offset(x, yOf(b.high)), Offset(x, yOf(b.low)), paint);
      final yOpen = yOf(b.open);
      final yClose = yOf(b.close);
      final top = yOpen < yClose ? yOpen : yClose;
      final h = (yClose - yOpen).abs().clamp(1.0, double.infinity);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, top + h / 2),
            width: bodyW,
            height: h,
          ),
          const Radius.circular(1.5),
        ),
        paint,
      );
      if (b.volume != null && b.volume! > 0) {
        final vy = yVol(b.volume!);
        canvas.drawRect(
          Rect.fromLTRB(x - bodyW / 2, vy, x + bodyW / 2, volumeRect.bottom),
          vPaint,
        );
      }
    }

    // crosshair highlight of the scrubbed bar
    if (highlight >= 0 && highlight < n) {
      final b = bars[highlight];
      final x = priceRect.left + slot * (highlight + 0.5);
      final cross = Paint()
        ..color = TC.info.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, plot.top), Offset(x, volumeRect.bottom), cross);
      canvas.drawLine(
        Offset(plot.left, yOf(b.close)),
        Offset(plot.right, yOf(b.close)),
        cross,
      );
    }

    // last-price marker (dashed)
    final last = bars.last;
    final ly = yOf(last.close);
    final dash = Paint()
      ..color = TC.info
      ..strokeWidth = 1;
    for (var x = plot.left; x < plot.right - 2; x += 8) {
      canvas.drawLine(Offset(x, ly), Offset(x + 4, ly), dash);
    }
    _label(
      canvas,
      formatINR(last.close),
      Offset(plot.right - 52, ly - 14),
      color: TC.info,
    );
  }

  void _label(Canvas canvas, String text, Offset at, {Color? color}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color ?? TC.onBgDim, fontSize: 9.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;

  @override
  bool shouldRepaint(CandlePainter old) =>
      old.bars != bars || old.highlight != highlight;
}
