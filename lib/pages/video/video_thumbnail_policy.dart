import 'package:flutter/services.dart';

enum VideoThumbnailFailureKind { busy, decodeFailed, other }

VideoThumbnailFailureKind classifyVideoThumbnailFailure(Object error) {
  if (error is PlatformException) {
    switch (error.code) {
      case 'busy':
        return VideoThumbnailFailureKind.busy;
      case 'decode_failed':
        return VideoThumbnailFailureKind.decodeFailed;
    }
  }
  return VideoThumbnailFailureKind.other;
}

String videoThumbnailFailureMessage(VideoThumbnailFailureKind kind) {
  switch (kind) {
    case VideoThumbnailFailureKind.busy:
      return '媒体处理繁忙，请稍后重试';
    case VideoThumbnailFailureKind.decodeFailed:
      return '无法读取首帧，将按封面居中裁剪';
    case VideoThumbnailFailureKind.other:
      return '首帧预览加载失败，请重试';
  }
}

bool resolveVideoSourceIsGif({
  required bool knownGif,
  required bool? decodedIsGif,
}) {
  return knownGif || (decodedIsGif ?? false);
}
