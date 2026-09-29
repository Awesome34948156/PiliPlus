import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/mpv_net_stats.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

/// Samples the live network rate and shows it with a short history.
///
/// **A readout, nothing more.** It is not wired to host selection — see
/// [MpvNetStats]. Closing the dialog stops the sampling; nothing runs while it
/// is shut.
const _maxSamples = 60;
const _tickInterval = Duration(seconds: 1);

Future<void> showNetSpeedDialog(
  BuildContext context, {
  required PlPlayerController controller,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _NetSpeedDialog(controller: controller),
  );
}

class _NetSpeedDialog extends StatefulWidget {
  const _NetSpeedDialog({required this.controller});

  final PlPlayerController controller;

  @override
  State<_NetSpeedDialog> createState() => _NetSpeedDialogState();
}

class _NetSpeedDialogState extends State<_NetSpeedDialog> {
  /// Oldest first, capped at [_maxSamples]. Holds whichever series is being
  /// shown — Mbps, or buffer fill — but never a mix, because a tick produces
  /// exactly one of them.
  final _series = <double>[];

  Timer? _timer;
  double? _mbps;
  double _bufferRate = 0;
  int _prevBuffered = 0;

  bool get _hasSpeed => _mbps != null;

  @override
  void initState() {
    super.initState();
    _prevBuffered = widget.controller.buffered.value;
    // Taken directly, not through _sample: nothing is built yet, and setState
    // during initState is not allowed.
    _read();
    _timer = Timer.periodic(_tickInterval, (_) => _sample());
  }

  @override
  void dispose() {
    // The whole reason this dialog is cheap: sampling exists only while it is
    // on screen.
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _sample() {
    _read();
    if (mounted) {
      setState(() {});
    }
  }

  void _read() {
    final player = widget.controller.videoPlayerController;
    final bytes = player == null
        ? null
        : MpvNetStats.readBytesPerSecond(player);

    final buffered = widget.controller.buffered.value;
    final delta = buffered - _prevBuffered;
    _prevBuffered = buffered;

    if (bytes != null) {
      _mbps = MpvNetStats.toMbps(bytes);
      _bufferRate = 0;
      _push(_mbps!);
    } else {
      _mbps = null;
      _bufferRate = MpvNetStats.bufferFillRate(delta.toDouble(), 1);
      _push(_bufferRate);
    }
  }

  void _push(double value) {
    _series.add(value);
    if (_series.length > _maxSamples) {
      _series.removeAt(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final value = _hasSpeed ? _mbps! : _bufferRate;

    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: const Text('实时网速'),
      constraints: const BoxConstraints.tightFor(width: 320),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            spacing: 6,
            children: [
              Text(
                value.toStringAsFixed(2),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                _hasSpeed ? 'Mbps' : '秒/秒',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _hasSpeed ? 'mpv 上报的实时下载速率' : 'mpv 未提供速率，显示缓冲填充速度（≥1 表示追得上播放）',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (_series.isEmpty)
            const SizedBox(
              height: 80,
              child: Center(child: Text('正在采样…')),
            )
          else
            _Chart(series: _series, color: color),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.series, required this.color});

  final List<double> series;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Scale to the series, with a floor so an all-zero run does not collapse
    // the axis, and a little headroom so the trace never touches the top.
    final peak = series.fold<double>(0, math.max);

    return IgnorePointer(
      child: SizedBox(
        height: 80,
        child: LineChart(
          LineChartData(
            titlesData: const FlTitlesData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            // Fixed, so the trace scrolls left as it fills instead of the
            // whole graph rescaling on every tick.
            minX: 0,
            maxX: (_maxSamples - 1).toDouble(),
            minY: 0,
            maxY: peak <= 0 ? 1 : peak * 1.15,
            lineBarsData: [
              LineChartBarData(
                spots: List.generate(
                  series.length,
                  (index) => FlSpot(index.toDouble(), series[index]),
                ),
                isCurved: true,
                barWidth: 1.5,
                color: color,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: color.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
