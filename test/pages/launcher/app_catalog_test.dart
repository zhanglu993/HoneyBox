import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/launcher/app_catalog.dart';

void main() {
  group('kAppCatalog', () {
    test('contains ebadge, watch, dashboard and capture in this order', () {
      expect(kAppCatalog.map((e) => e.id).toList(), [
        AppId.ebadge,
        AppId.watch,
        AppId.dashboard,
        AppId.capture,
      ]);
    });

    test('every entry has non-empty title, subtitle, deviceFilter', () {
      for (final e in kAppCatalog) {
        expect(e.title, isNotEmpty, reason: '${e.id} title empty');
        expect(e.subtitle, isNotEmpty, reason: '${e.id} subtitle empty');
        expect(e.deviceFilter, isNotEmpty, reason: '${e.id} filter empty');
        expect(e.icon, isA<IconData>());
      }
    });

    test('uses the product names eBadge, Watch, Dashboard and 数据采集', () {
      expect(
        kAppCatalog.map((e) => e.title).toList(),
        ['eBadge', 'Watch', 'Dashboard', '数据采集'],
      );
    });

    test('all launcher applications are implemented', () {
      expect(kAppCatalog.every((e) => e.implemented), isTrue);
    });

    test('device filters are the exact spec values', () {
      final byId = {for (final e in kAppCatalog) e.id: e.deviceFilter};
      expect(byId[AppId.ebadge], 'eBadge');
      expect(byId[AppId.watch], 'Watch');
      expect(byId[AppId.dashboard], 'Dashboard');
      expect(byId[AppId.capture], '*');
    });
  });

  group('routeNameFor', () {
    test('maps each AppId to the spec-defined route name', () {
      expect(routeNameFor(AppId.ebadge), '/ebadge-root');
      expect(routeNameFor(AppId.watch), '/watch-root');
      expect(routeNameFor(AppId.dashboard), '/dashboard-root');
      expect(routeNameFor(AppId.capture), '/capture-root');
    });
  });
}
