import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/video/video_thumbnail_policy.dart';

void main() {
  test('classifies native busy separately from decode failure', () {
    expect(
      classifyVideoThumbnailFailure(PlatformException(code: 'busy')),
      VideoThumbnailFailureKind.busy,
    );
    expect(
      classifyVideoThumbnailFailure(
        PlatformException(code: 'decode_failed'),
      ),
      VideoThumbnailFailureKind.decodeFailed,
    );
    expect(
      classifyVideoThumbnailFailure(StateError('bad png')),
      VideoThumbnailFailureKind.other,
    );
  });

  test('busy message never claims the first frame is unreadable', () {
    final busy = videoThumbnailFailureMessage(VideoThumbnailFailureKind.busy);
    final decode =
        videoThumbnailFailureMessage(VideoThumbnailFailureKind.decodeFailed);

    expect(busy, isNot(contains('无法读取首帧')));
    expect(busy, contains('繁忙'));
    expect(decode, contains('无法读取首帧'));
  });

  test('known GIF type survives missing thumbnail metadata', () {
    expect(
      resolveVideoSourceIsGif(knownGif: true, decodedIsGif: null),
      isTrue,
    );
  });
}
