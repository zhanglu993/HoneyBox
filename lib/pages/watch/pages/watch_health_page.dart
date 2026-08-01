import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/app_theme.dart';
import '../health/watch_health_data.dart';
import '../health/watch_health_provider.dart';

class WatchHealthPage extends ConsumerWidget {
  const WatchHealthPage({
    super.key,
    required this.deviceName,
    required this.deviceId,
  });

  final String deviceName;
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = watchHealthProvider(deviceId);
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);
    final syncing = state.phase == WatchHealthSyncPhase.syncing;

    ref.listen(provider, (previous, next) {
      if (next.phase != WatchHealthSyncPhase.failure ||
          previous?.phase == next.phase) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(next.errorMessage!)));
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('运动 / 健康'),
        actions: [
          IconButton(
            key: const Key('watch-health-sync'),
            tooltip: '同步健康数据',
            onPressed: syncing ? null : notifier.sync,
            icon: syncing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              children: [
                _SyncHeader(
                  deviceName: deviceName,
                  state: state,
                  onSync: notifier.sync,
                ),
                if (state.snapshot == null)
                  _EmptyState(
                    syncing: syncing,
                    failed: state.phase == WatchHealthSyncPhase.failure,
                    onSync: notifier.sync,
                  )
                else ...[
                  const SizedBox(height: 22),
                  _SectionHeading(
                    title: '今日概览',
                    trailing: _date(state.snapshot!.syncedAt),
                  ),
                  const SizedBox(height: 10),
                  _MetricsGrid(snapshot: state.snapshot!),
                  const SizedBox(height: 22),
                  _TrendSection(
                    state: state,
                    onPeriodChanged: notifier.selectPeriod,
                  ),
                  const SizedBox(height: 22),
                  _SleepSection(snapshot: state.snapshot!),
                  const SizedBox(height: 22),
                  _HeartRateSection(snapshot: state.snapshot!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _date(DateTime value) => '${value.month}月${value.day}日';
}

class _SyncHeader extends StatelessWidget {
  const _SyncHeader({
    required this.deviceName,
    required this.state,
    required this.onSync,
  });

  final String deviceName;
  final WatchHealthState state;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final syncing = state.phase == WatchHealthSyncPhase.syncing;
    final failed = state.phase == WatchHealthSyncPhase.failure;
    final status = syncing
        ? '正在同步健康数据...'
        : failed
            ? '同步失败 · 可重新尝试'
            : state.snapshot == null
                ? '尚未同步健康数据'
                : '最近同步：${_time(state.snapshot!.syncedAt)}';
    return Container(
      padding: const EdgeInsets.only(bottom: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.outline)),
      ),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppTheme.watchAccent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.watch_outlined, color: AppTheme.watchAccent),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                deviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 3),
              Text(
                status,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: failed ? AppTheme.error : null,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: syncing ? null : onSync,
          icon: syncing
              ? const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync, size: 18),
          label: Text(failed
              ? '重试'
              : syncing
                  ? '同步中'
                  : '同步'),
        ),
      ]),
    );
  }

  static String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.syncing,
    required this.failed,
    required this.onSync,
  });

  final bool syncing;
  final bool failed;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 24),
      child: Column(children: [
        Icon(
          failed ? Icons.sync_problem : Icons.monitor_heart_outlined,
          size: 54,
          color: failed ? AppTheme.error : AppTheme.watchAccent,
        ),
        const SizedBox(height: 18),
        Text(
          syncing
              ? '正在读取手表数据'
              : failed
                  ? '同步未完成'
                  : '同步手表后即可查看',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          syncing
              ? '等待手表返回运动、睡眠和心率记录'
              : failed
                  ? '请确认手表保持连接，然后重新同步'
                  : '数据由已连接的手表提供',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (!syncing) ...[
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: onSync,
            icon: const Icon(Icons.sync),
            label: Text(failed ? '重新同步' : '立即同步'),
          ),
        ],
      ]),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.trailing});

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        Text(trailing, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.snapshot});

  final WatchHealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final heartRate = snapshot.latestHeartRate;
    final sleep = snapshot.sleepMinutes;
    final metrics = [
      _Metric(Icons.directions_walk, '步数', _number(snapshot.steps), '步'),
      _Metric(Icons.route_outlined, '距离',
          (snapshot.distanceMeters / 1000).toStringAsFixed(2), '公里'),
      _Metric(Icons.local_fire_department_outlined, '卡路里',
          snapshot.caloriesKcal.toStringAsFixed(1), 'kcal'),
      _Metric(Icons.timer_outlined, '活动时长', '${snapshot.activeMinutes}', '分钟'),
      _Metric(Icons.favorite, '最近心率', heartRate?.toString() ?? '--',
          heartRate == null ? '暂无数据' : '次/分'),
      _Metric(
          Icons.bedtime_outlined,
          '睡眠',
          sleep == 0
              ? '--'
              : '${sleep ~/ 60}:${(sleep % 60).toString().padLeft(2, '0')}',
          sleep == 0 ? '暂无数据' : '小时'),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final width = (constraints.maxWidth - 10) / 2;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: metrics
            .map((metric) => SizedBox(
                  width: width,
                  height: 104,
                  child: _MetricTile(metric: metric),
                ))
            .toList(),
      );
    });
  }

  static String _number(int value) {
    final text = value.toString();
    return text.length > 3
        ? '${text.substring(0, text.length - 3)},${text.substring(text.length - 3)}'
        : text;
  }
}

class _Metric {
  const _Metric(this.icon, this.label, this.value, this.unit);
  final IconData icon;
  final String label;
  final String value;
  final String unit;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});
  final _Metric metric;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.outline.withValues(alpha: 0.75)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(metric.icon, size: 18, color: AppTheme.watchAccent),
              const SizedBox(width: 7),
              Text(metric.label, style: Theme.of(context).textTheme.bodySmall),
            ]),
            const Spacer(),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Flexible(
                child: Text(
                  metric.value,
                  maxLines: 1,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 5),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(metric.unit,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
            ]),
          ]),
        ),
      );
}

class _TrendSection extends StatelessWidget {
  const _TrendSection({required this.state, required this.onPeriodChanged});

  final WatchHealthState state;
  final ValueChanged<WatchHealthPeriod> onPeriodChanged;

  @override
  Widget build(BuildContext context) {
    final trend = state.trend!;
    final hasHeartRate = trend.points.any((point) => point.heartRate != null);
    return Column(children: [
      _SectionHeading(title: '趋势', trailing: trend.summary),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.outline.withValues(alpha: 0.75)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Text(trend.label,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            SegmentedButton<WatchHealthPeriod>(
              segments: const [
                ButtonSegment(value: WatchHealthPeriod.day, label: Text('日')),
                ButtonSegment(value: WatchHealthPeriod.week, label: Text('周')),
                ButtonSegment(value: WatchHealthPeriod.month, label: Text('月')),
              ],
              selected: {state.period},
              onSelectionChanged: (value) => onPeriodChanged(value.first),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const _Legend(color: AppTheme.watchAccent, label: '步数'),
            if (hasHeartRate) ...[
              const SizedBox(width: 14),
              const _Legend(color: AppTheme.error, label: '心率'),
            ],
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 178,
            width: double.infinity,
            child: CustomPaint(painter: _TrendPainter(trend)),
          ),
        ]),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 8, height: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ]);
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(this.trend);
  final WatchHealthTrend trend;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 22.0;
    const top = 8.0;
    final height = size.height - bottom - top;
    final width = size.width;
    final points = trend.points;
    if (points.isEmpty) return;
    final maxSteps =
        points.map((point) => point.steps).fold(1, (a, b) => a > b ? a : b);
    final slot = width / points.length;
    final barPaint = Paint()
      ..color = AppTheme.watchAccent.withValues(alpha: 0.55);
    final gridPaint = Paint()..color = AppTheme.outline.withValues(alpha: 0.5);
    for (var i = 0; i < 4; i++) {
      final y = top + height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(width, y), gridPaint);
    }
    for (var i = 0; i < points.length; i++) {
      final barHeight = height * points[i].steps / maxSteps;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * slot + slot * 0.28,
            top + height - barHeight,
            slot * 0.44,
            barHeight,
          ),
          const Radius.circular(2),
        ),
        barPaint,
      );
    }
    final heartPoints = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      final bpm = points[i].heartRate;
      if (bpm == null) continue;
      final normalized = ((bpm - 40) / 160).clamp(0.0, 1.0);
      heartPoints.add(Offset(
        slot * (i + 0.5),
        top + height * (1 - normalized),
      ));
    }
    if (heartPoints.isNotEmpty) {
      final line = Paint()
        ..color = AppTheme.error
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(heartPoints.first.dx, heartPoints.first.dy);
      for (final point in heartPoints.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, line);
      final dot = Paint()..color = AppTheme.error;
      for (final point in heartPoints) {
        canvas.drawCircle(point, 3, dot);
      }
    }
    const labelStyle = TextStyle(color: AppTheme.textTertiary, fontSize: 9);
    final labelEvery = points.length > 10 ? 5 : 1;
    for (var i = 0; i < points.length; i += labelEvery) {
      final painter = TextPainter(
        text: TextSpan(text: points[i].label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: slot * labelEvery);
      painter.paint(
        canvas,
        Offset(slot * (i + 0.5) - painter.width / 2, size.height - 14),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.trend != trend;
}

class _SleepSection extends StatelessWidget {
  const _SleepSection({required this.snapshot});
  final WatchHealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final stages = snapshot.sleepStages;
    return Column(children: [
      _SectionHeading(title: '睡眠', trailing: snapshot.sleepRange ?? '暂无数据'),
      const SizedBox(height: 10),
      _DataPanel(
        child: stages.isEmpty
            ? const _NoData(message: '手表未返回睡眠记录')
            : Column(children: [
                for (final stage in stages)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Icon(
                        stage.mode == 1
                            ? Icons.nights_stay_outlined
                            : Icons.bedtime_outlined,
                        size: 18,
                        color: AppTheme.watchAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(stage.name)),
                      Text('${stage.minutes ~/ 60}时${stage.minutes % 60}分'),
                    ]),
                  ),
              ]),
      ),
    ]);
  }
}

class _HeartRateSection extends StatelessWidget {
  const _HeartRateSection({required this.snapshot});
  final WatchHealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final records = [...snapshot.heartRateRecords]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final recent = records.take(5).toList();
    return Column(children: [
      _SectionHeading(title: '最近心率', trailing: '${records.length} 次测量'),
      const SizedBox(height: 10),
      _DataPanel(
        child: recent.isEmpty
            ? const _NoData(message: '手表未返回心率记录')
            : Column(children: [
                for (var i = 0; i < recent.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(children: [
                      const Icon(Icons.favorite,
                          size: 18, color: AppTheme.error),
                      const SizedBox(width: 9),
                      Expanded(child: Text(_recordTime(recent[i].timestamp))),
                      Text('${recent[i].bpm} 次/分'),
                    ]),
                  ),
                  if (i < recent.length - 1) const Divider(),
                ],
              ]),
      ),
    ]);
  }

  static String _recordTime(DateTime value) =>
      '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
}

class _DataPanel extends StatelessWidget {
  const _DataPanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.outline.withValues(alpha: 0.75)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
}

class _NoData extends StatelessWidget {
  const _NoData({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
}
