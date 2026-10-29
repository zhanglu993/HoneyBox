import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/watch_notification_provider.dart';
import '../../../theme/app_theme.dart';

class WatchNotificationPage extends ConsumerStatefulWidget {
  const WatchNotificationPage({super.key});

  @override
  ConsumerState<WatchNotificationPage> createState() =>
      _WatchNotificationPageState();
}

class _NotificationPageSample {
  final String name, icon, title, message;
  final int color;

  const _NotificationPageSample({
    required this.name,
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });
}

class _WatchNotificationPageState extends ConsumerState<WatchNotificationPage> {
  String _selectedSample = 'wechat';

  static const Map<String, _NotificationPageSample> _samples = {
    'wechat': _NotificationPageSample(
      name: '微信',
      icon: '微',
      color: 0xFF27A844,
      title: '项目讨论群',
      message: '明天上午十点一起确认新版本。',
    ),
    'call': _NotificationPageSample(
      name: '电话',
      icon: '电',
      color: 0xFF23845B,
      title: '王金星',
      message: '来电  138 **** 6208',
    ),
    'sms': _NotificationPageSample(
      name: '短信',
      icon: '短',
      color: 0xFF2D8B57,
      title: '快递服务',
      message: '您的快件已送达丰巢，请及时取件。',
    ),
    'feishu': _NotificationPageSample(
      name: '飞书',
      icon: '飞',
      color: 0xFF3370FF,
      title: '产品研发群',
      message: '周会资料已经更新，请查收。',
    ),
    'whatsapp': _NotificationPageSample(
      name: 'WhatsApp',
      icon: 'W',
      color: 0xFF25D366,
      title: '产品设计组',
      message: 'Design review at 3pm in the boardroom.',
    ),
    'telegram': _NotificationPageSample(
      name: 'Telegram',
      icon: 'T',
      color: 0xFF29A0D9,
      title: 'DevOps 警告',
      message: 'Production: memory usage > 85%, please check.',
    ),
    'weibo': _NotificationPageSample(
      name: '微博',
      icon: '博',
      color: 0xFFE6162D,
      title: '热门话题',
      message: '今日热搜：新能源车补贴政策调整，点击查看详情。',
    ),
    'douyin': _NotificationPageSample(
      name: '抖音',
      icon: '抖',
      color: 0xFF111111,
      title: '你关注的 @美食家老王',
      message: '新作品：街边牛肉面的灵魂吃法',
    ),
    'alipay': _NotificationPageSample(
      name: '支付宝',
      icon: '支',
      color: 0xFF1677FF,
      title: '到账提醒',
      message: '朋友转账 200.00 元已到账余额。',
    ),
    'mail': _NotificationPageSample(
      name: '邮件',
      icon: '邮',
      color: 0xFFD04B3E,
      title: '项目周报',
      message: '2026年Q3 产品路线图已经更新，请查收附件。',
    ),
  };

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return Scaffold(
        appBar: AppBar(title: const Text('通知转发')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('通知转发暂未适配 iOS', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final state = ref.watch(watchNotificationProvider);
    final notifier = ref.read(watchNotificationProvider.notifier);

    final paused = !state.masterEnabled || state.isInQuietPeriod;
    final sourcesByGroup = <NotificationGroup, List<NotificationSource>>{};
    for (final s in state.sources) {
      sourcesByGroup.putIfAbsent(s.group, () => []);
      sourcesByGroup[s.group]!.add(s);
    }
    final extraCount = state.sources
        .where((s) =>
            (s.group == NotificationGroup.other ||
                s.group == NotificationGroup.extra) &&
            s.enabled)
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('\u901a\u77e5\u8f6c\u53d1')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 32),
        children: [
          _ServiceStrip(
            masterEnabled: state.masterEnabled,
            permissionGranted: state.permissionGranted,
            isInQuietPeriod: state.isInQuietPeriod,
            onToggle: notifier.toggleMaster,
          ),
          if (!state.permissionGranted)
            _PermissionBanner(onRequest: notifier.requestPermission),
          const SizedBox(height: 16),
          _SourceGroup(
            title: '\u7535\u8bdd\u4e0e\u77ed\u4fe1',
            note: '\u91cd\u8981\u63d0\u9192',
            sources: sourcesByGroup[NotificationGroup.essential] ?? [],
            disabled: !state.permissionGranted || !state.masterEnabled,
            onToggle: notifier.toggleSource,
          ),
          const SizedBox(height: 16),
          _SourceGroup(
            title: '\u793e\u4ea4\u901a\u8baf',
            note: '\u804a\u5929\u6d88\u606f',
            sources: sourcesByGroup[NotificationGroup.social] ?? [],
            disabled: !state.permissionGranted || !state.masterEnabled,
            onToggle: notifier.toggleSource,
          ),
          const SizedBox(height: 16),
          _SourceGroup(
            title: '\u5de5\u4f5c\u534f\u4f5c',
            note: '\u4f1a\u8bae\u4e0e\u6d88\u606f',
            sources: sourcesByGroup[NotificationGroup.work] ?? [],
            disabled: !state.permissionGranted || !state.masterEnabled,
            onToggle: notifier.toggleSource,
          ),
          const SizedBox(height: 16),
          _SourceGroup(
            title: '\u5176\u4ed6\u5e38\u7528',
            note: '$extraCount \u4e2a\u5df2\u5f00\u542f',
            sources: sourcesByGroup[NotificationGroup.other] ?? [],
            disabled: !state.permissionGranted || !state.masterEnabled,
            onToggle: notifier.toggleSource,
          ),
          _MoreAppsButton(
            sources: sourcesByGroup[NotificationGroup.extra] ?? [],
            disabled: !state.permissionGranted || !state.masterEnabled,
            onToggle: notifier.toggleSource,
          ),
          const SizedBox(height: 20),
          _PrivacyPanel(
            privacy: state.privacy,
            onChanged: notifier.setPrivacy,
          ),
          const SizedBox(height: 16),
          _QuietPanel(
            quietEnabled: state.quietEnabled,
            quietStart: state.quietStart,
            quietEnd: state.quietEnd,
            onToggle: notifier.toggleQuiet,
            onStartChanged: notifier.setQuietStart,
            onEndChanged: notifier.setQuietEnd,
          ),
          const SizedBox(height: 16),
          _PreviewPanel(
            selectedSample: _selectedSample,
            paused: paused,
            pausedReason: !state.permissionGranted
                ? '\u9700\u8981\u901a\u77e5\u4f7f\u7528\u6743'
                : !state.masterEnabled
                    ? '\u901a\u77e5\u8f6c\u53d1\u5df2\u5173\u95ed'
                    : '\u5f53\u524d\u5904\u4e8e\u5b89\u9759\u65f6\u6bb5',
            privacy: state.privacy,
            onSampleChanged: (id) => setState(() => _selectedSample = id),
          ),
        ],
      ),
    );
  }
}

class _ServiceStrip extends StatelessWidget {
  final bool masterEnabled;
  final bool permissionGranted;
  final bool isInQuietPeriod;
  final VoidCallback onToggle;

  const _ServiceStrip({
    required this.masterEnabled,
    required this.permissionGranted,
    required this.isInQuietPeriod,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final stateText = !permissionGranted
        ? '\u7b49\u5f85\u901a\u77e5\u4f7f\u7528\u6743'
        : !masterEnabled
            ? '\u901a\u77e5\u8f6c\u53d1\u5df2\u6682\u505c'
            : isInQuietPeriod
                ? '\u5b89\u9759\u65f6\u6bb5 \u00b7 \u6682\u505c\u63a8\u9001'
                : '\u901a\u77e5\u8f6c\u53d1\u5df2\u5f00\u542f';
    final Color stateColor;
    if (!permissionGranted) {
      stateColor = const Color(0xFFB96806);
    } else if (!masterEnabled || isInQuietPeriod) {
      stateColor = AppTheme.textSecondary;
    } else {
      stateColor = const Color(0xFF34A853);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFDADFE2))),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFE2F0EC),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.watch_outlined,
                color: Color(0xFF2E7D6B), size: 22),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('\u901a\u77e5\u8f6c\u53d1',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF202124))),
                const SizedBox(height: 2),
                Text(stateText,
                    style: TextStyle(fontSize: 11, color: stateColor)),
              ],
            ),
          ),
          _Switch(
              value: masterEnabled,
              onChanged: permissionGranted ? onToggle : null),
        ],
      ),
    );
  }
}

/// Styled switch that wraps Flutter's native [Switch] for accessibility
/// (semantics, keyboard navigation, platform adaptation).
class _Switch extends StatelessWidget {
  final bool value;
  final VoidCallback? onChanged;

  const _Switch({required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: SizedBox(
        width: 48,
        height: 28,
        child: Switch(
          value: value,
          onChanged: onChanged == null ? null : (_) => onChanged!(),
          activeThumbColor: AppTheme.watchAccent,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: onChanged == null
              ? const Color(0xFFCCD1D5)
              : const Color(0xFFAEB4B9),
        ),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  final VoidCallback onRequest;

  const _PermissionBanner({required this.onRequest});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE4B36B)),
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFFFFF8EC),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('\u26A0',
                  style: TextStyle(color: Color(0xFFB96806), fontSize: 17)),
              SizedBox(width: 9),
              Text('\u9700\u8981\u901a\u77e5\u4f7f\u7528\u6743',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF202124))),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 7),
            child: Text(
              '\u5141\u8bb8 HoneyBox \u8bfb\u53d6\u5df2\u9009\u5e94\u7528\u7684\u901a\u77e5\uff0c\u624d\u80fd\u8f6c\u53d1\u5230\u624b\u8868\u3002',
              style: TextStyle(fontSize: 11, color: Color(0xFF60656B)),
            ),
          ),
          SizedBox(
            height: 38,
            child: ElevatedButton(
              onPressed: onRequest,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0072BC),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7)),
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              child: const Text('\u5f00\u542f\u901a\u77e5\u4f7f\u7528\u6743'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceGroup extends StatelessWidget {
  final String title;
  final String note;
  final List<NotificationSource> sources;
  final bool disabled;
  final void Function(String) onToggle;

  const _SourceGroup({
    required this.title,
    required this.note,
    required this.sources,
    required this.disabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
          child: Row(
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF202124))),
              const Spacer(),
              Text(note,
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFF8A9096))),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE0E3E5)),
            borderRadius: BorderRadius.circular(8),
            color: Colors.white,
          ),
          child: Column(
            children: sources.asMap().entries.map((entry) {
              final i = entry.key;
              final s = entry.value;
              final isLast = i == sources.length - 1;
              return _SourceRow(
                source: s,
                disabled: disabled,
                isLast: isLast,
                onToggle: () => onToggle(s.id),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  final NotificationSource source;
  final bool disabled;
  final bool isLast;
  final VoidCallback onToggle;

  const _SourceRow({
    required this.source,
    required this.disabled,
    required this.isLast,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final opacity = disabled || !source.enabled ? 0.52 : 1.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(bottom: BorderSide(color: Color(0xFFECEEEF))),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Color(source.color).withValues(alpha: opacity),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(source.icon,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.name,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF202124)
                            .withValues(alpha: opacity))),
                const SizedBox(height: 2),
                Text(source.subtitle,
                    style: TextStyle(
                        fontSize: 10,
                        color: const Color(0xFF8A9096)
                            .withValues(alpha: opacity))),
              ],
            ),
          ),
          _Switch(
            value: source.enabled,
            onChanged: disabled ? null : onToggle,
          ),
        ],
      ),
    );
  }
}

class _MoreAppsButton extends StatelessWidget {
  final List<NotificationSource> sources;
  final bool disabled;
  final void Function(String) onToggle;

  const _MoreAppsButton({
    required this.sources,
    required this.disabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
        child: InkWell(
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
          onTap: () => _showExtraAppsSheet(context),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 13, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('\u7ba1\u7406\u5176\u4ed6\u5e94\u7528',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0072BC))),
                Text('\u203a',
                    style: TextStyle(fontSize: 18, color: Color(0xFF0072BC))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showExtraAppsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) {
                return Column(
                  children: [
                    Container(
                      height: 58,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          const Text('\u5176\u4ed6\u5e94\u7528',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF202124))),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    if (sources.isEmpty)
                      const Expanded(
                        child: Center(
                          child: Text('\u6ca1\u6709\u66f4\u591a\u5e94\u7528',
                              style: TextStyle(
                                  fontSize: 12, color: Color(0xFF60656B))),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          children: sources
                              .map((s) => _SourceRow(
                                    source: s,
                                    disabled: disabled,
                                    isLast: s == sources.last,
                                    onToggle: () {
                                      onToggle(s.id);
                                      setSheetState(() {});
                                    },
                                  ))
                              .toList(),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _PrivacyPanel extends StatelessWidget {
  final NotificationPrivacy privacy;
  final void Function(NotificationPrivacy) onChanged;

  const _PrivacyPanel({
    required this.privacy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = switch (privacy) {
      NotificationPrivacy.appOnly =>
        '\u624b\u8868\u4ec5\u663e\u793a\u5e94\u7528\u540d\u79f0\uff0c\u4e0d\u663e\u793a\u8054\u7cfb\u4eba\u3001\u6807\u9898\u548c\u6d88\u606f\u6b63\u6587\u3002',
      NotificationPrivacy.titleAndContact =>
        '\u624b\u8868\u663e\u793a\u5e94\u7528\u540d\u79f0\u3001\u6807\u9898\u4e0e\u8054\u7cfb\u4eba\uff0c\u4e0d\u663e\u793a\u6d88\u606f\u6b63\u6587\u3002',
      NotificationPrivacy.fullContent =>
        '\u624b\u8868\u663e\u793a\u5e94\u7528\u540d\u79f0\u3001\u6807\u9898\u3001\u8054\u7cfb\u4eba\u548c\u6d88\u606f\u6b63\u6587\u3002',
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE0E3E5)),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('\u901a\u77e5\u5185\u5bb9',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF202124))),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF0F2),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                _PrivacySegment(
                  label: '\u4ec5\u5e94\u7528\u540d\u79f0',
                  selected: privacy == NotificationPrivacy.appOnly,
                  onTap: () => onChanged(NotificationPrivacy.appOnly),
                ),
                _PrivacySegment(
                  label: '\u6807\u9898\u4e0e\u8054\u7cfb\u4eba',
                  selected: privacy == NotificationPrivacy.titleAndContact,
                  onTap: () => onChanged(NotificationPrivacy.titleAndContact),
                ),
                _PrivacySegment(
                  label: '\u5b8c\u6574\u5185\u5bb9',
                  selected: privacy == NotificationPrivacy.fullContent,
                  onTap: () => onChanged(NotificationPrivacy.fullContent),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(hint,
              style: const TextStyle(fontSize: 10, color: Color(0xFF60656B))),
        ],
      ),
    );
  }
}

class _PrivacySegment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PrivacySegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            boxShadow: selected
                ? [const BoxShadow(color: Colors.black26, blurRadius: 4)]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? const Color(0xFF0072BC)
                    : const Color(0xFF60656B),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuietPanel extends StatelessWidget {
  final bool quietEnabled;
  final TimeOfDay quietStart;
  final TimeOfDay quietEnd;
  final VoidCallback onToggle;
  final void Function(TimeOfDay) onStartChanged;
  final void Function(TimeOfDay) onEndChanged;

  const _QuietPanel({
    required this.quietEnabled,
    required this.quietStart,
    required this.quietEnd,
    required this.onToggle,
    required this.onStartChanged,
    required this.onEndChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE0E3E5)),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('\u5b9a\u65f6\u514d\u6253\u6270',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF202124))),
                      const SizedBox(height: 2),
                      Text(
                        quietEnabled
                            ? '${quietStart.format(context)} - ${quietEnd.format(context)}'
                            : '\u672a\u542f\u7528',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFF8A9096)),
                      ),
                    ],
                  ),
                ),
                _Switch(value: quietEnabled, onChanged: onToggle),
              ],
            ),
          ),
          if (quietEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _TimeButton(
                      time: quietStart,
                      onChanged: onStartChanged,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('\u81f3',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF8A9096))),
                  ),
                  Expanded(
                    child: _TimeButton(
                      time: quietEnd,
                      onChanged: onEndChanged,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TimeButton extends StatelessWidget {
  final TimeOfDay time;
  final void Function(TimeOfDay) onChanged;

  const _TimeButton({required this.time, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: time,
        );
        if (picked != null) {
          onChanged(picked);
        }
      },
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          border: Border.all(color: const Color(0xFFDADFE2)),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Center(
          child: Text(
            time.format(context),
            style: const TextStyle(fontSize: 13, color: Color(0xFF202124)),
          ),
        ),
      ),
    );
  }
}

class _PreviewPanel extends StatelessWidget {
  final String selectedSample;
  final bool paused;
  final String pausedReason;
  final NotificationPrivacy privacy;
  final void Function(String) onSampleChanged;

  const _PreviewPanel({
    required this.selectedSample,
    required this.paused,
    required this.pausedReason,
    required this.privacy,
    required this.onSampleChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE0E3E5)),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('\u624b\u8868\u9884\u89c8',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF202124))),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _WatchNotificationPageState._samples.entries
                  .map((e) => _SampleTab(
                        label: e.value.name,
                        selected: e.key == selectedSample,
                        onTap: () => onSampleChanged(e.key),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: _WatchPreview(
              sample: _WatchNotificationPageState._samples[selectedSample]!,
              paused: paused,
              pausedReason: pausedReason,
              privacy: privacy,
            ),
          ),
        ],
      ),
    );
  }
}

class _SampleTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SampleTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color:
                  selected ? const Color(0xFF2E7D6B) : const Color(0xFFDADFE2),
            ),
            borderRadius: BorderRadius.circular(16),
            color: selected ? const Color(0xFFE2F0EC) : Colors.white,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? const Color(0xFF2E7D6B)
                    : const Color(0xFF60656B),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WatchPreview extends StatelessWidget {
  final _NotificationPageSample sample;
  final bool paused;
  final String pausedReason;
  final NotificationPrivacy privacy;

  const _WatchPreview({
    required this.sample,
    required this.paused,
    required this.pausedReason,
    required this.privacy,
  });

  @override
  Widget build(BuildContext context) {
    final title = switch (privacy) {
      NotificationPrivacy.appOnly => '\u65b0\u901a\u77e5',
      _ => sample.title,
    };
    final message = switch (privacy) {
      NotificationPrivacy.appOnly => '\u6253\u5f00\u624b\u673a\u67e5\u770b',
      NotificationPrivacy.titleAndContact =>
        '\u901a\u77e5\u5185\u5bb9\u5df2\u9690\u85cf',
      NotificationPrivacy.fullContent => sample.message,
    };

    return Container(
      width: 206,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(34),
        color: const Color(0xFF1E2225),
        boxShadow: const [
          BoxShadow(
              color: Color(0x2B191E21), blurRadius: 20, offset: Offset(0, 6)),
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF080B0D),
          borderRadius: BorderRadius.circular(25),
        ),
        child: paused
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('\u901a\u77e5\u5df2\u6682\u505c',
                      style: TextStyle(color: Color(0xFFC2C9CD), fontSize: 12)),
                  SizedBox(height: 4),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: Color(sample.color),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            sample.icon,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          sample.name,
                          style: const TextStyle(
                              color: Color(0xFFAEB7BD),
                              fontSize: 10,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Text('\u521a\u521a',
                          style:
                              TextStyle(color: Color(0xFFAEB7BD), fontSize: 9)),
                    ],
                  ),
                  const SizedBox(height: 17),
                  Text(
                    title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFFC3CBD0), fontSize: 11, height: 1.55),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                      '\u62ac\u8155\u67e5\u770b \u00b7 \u5411\u4e0a\u6ed1\u52a8\u5ffd\u7565',
                      style: TextStyle(color: Color(0xFF7F8A91), fontSize: 9)),
                ],
              ),
      ),
    );
  }
}
