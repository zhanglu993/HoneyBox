import 'package:flutter/material.dart';

/// nRF-Connect-style scan result row: signal strength on the left, device
/// name + address + tags in the middle, and an explicit connect action on the
/// right. Tapping anywhere on the card also connects.
class DeviceTile extends StatelessWidget {
  final String deviceId;
  final String name;
  final int? rssi;
  final bool connectable;
  final bool isConnecting;
  final VoidCallback? onConnect;

  /// 虚拟调试设备:在标签行额外显示一枚橙色"调试"徽标以示区分。
  final bool debug;

  const DeviceTile({
    super.key,
    required this.deviceId,
    required this.name,
    this.rssi,
    this.connectable = true,
    this.isConnecting = false,
    this.onConnect,
    this.debug = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasName = name.isNotEmpty && name != '未知设备';
    final canTap = !isConnecting && connectable && onConnect != null;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: canTap ? onConnect : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              _SignalBars(rssi: rssi, color: cs.primary, muted: cs.outline),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasName ? name : 'N/A',
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: hasName ? cs.onSurface : cs.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      deviceId,
                      style: tt.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        if (rssi != null) ...[
                          Text('$rssi dBm', style: tt.labelMedium),
                          const SizedBox(width: 10),
                        ],
                        _Tag(
                          label: connectable ? '可连接' : '不可连接',
                          color: connectable ? cs.secondary : cs.outline,
                        ),
                        if (debug) ...[
                          const SizedBox(width: 6),
                          const _Tag(
                            label: '调试',
                            color: Color(0xFFF57C00), // Colors.orange[700]
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 76,
                child: isConnecting
                    ? const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : FilledButton(
                        onPressed: canTap ? onConnect : null,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 38),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('连接'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four ascending bars whose filled count reflects RSSI strength.
class _SignalBars extends StatelessWidget {
  final int? rssi;
  final Color color;
  final Color muted;

  const _SignalBars({
    required this.rssi,
    required this.color,
    required this.muted,
  });

  int get _level {
    final r = rssi;
    if (r == null) return 0;
    if (r >= -60) return 4;
    if (r >= -72) return 3;
    if (r >= -84) return 2;
    if (r >= -96) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final level = _level;
    final inactive = muted.withValues(alpha: 0.35);
    return SizedBox(
      width: 30,
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(4, (i) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: Container(
              width: 4.5,
              height: 8.0 + i * 6.0,
              decoration: BoxDecoration(
                color: i < level ? color : inactive,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Small pill-shaped status label.
class _Tag extends StatelessWidget {
  final String label;
  final Color color;

  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
