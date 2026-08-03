import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/video/video_example_thumbnail.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Center(child: child));

  testWidgets('failed example thumbnail leaves spinner and shows placeholder',
      (tester) async {
    await tester.pumpWidget(wrap(VideoExampleThumbnail(
      sourceKey: 'failed',
      load: () => Future<ui.Image>.error(StateError('decode failed')),
    )));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  testWidgets('stale failure cannot replace the next thumbnail loading state',
      (tester) async {
    final oldLoad = Completer<ui.Image>();
    final newLoad = Completer<ui.Image>();

    await tester.pumpWidget(wrap(VideoExampleThumbnail(
      sourceKey: 'old',
      load: () => oldLoad.future,
    )));
    await tester.pumpWidget(wrap(VideoExampleThumbnail(
      sourceKey: 'new',
      load: () => newLoad.future,
    )));

    oldLoad.completeError(StateError('late old failure'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    newLoad.completeError(StateError('completed after dispose'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
