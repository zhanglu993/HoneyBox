import 'package:flutter/material.dart';

/// 「确认断开设备连接」对话框。两个全宽垂直排列的按钮:红色「断开」在上,
/// 中性「取消」在下。
///
/// 返回 `true` 表示用户点击了「断开」,`false` 表示点击「取消」或从
/// dialog 外部关闭。调用方负责在 `true` 时执行断开动作。
///
/// 在 DevicePage 右上角「断开」按钮 与 EBadgeAppRoot 的返回键拦截里
/// 共用同一份 UI,避免语义/样式漂移。
Future<bool> showDisconnectConfirmDialog(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('断开连接', textAlign: TextAlign.center),
      content: const Text('确认断开设备连接?'),
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError,
                ),
                child: const Text('断开'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: cs.surfaceContainerHighest,
                  foregroundColor: cs.onSurface,
                ),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result ?? false;
}
