import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_models.dart';
import 'package:honeybox/services/capture/capture_store.dart';
import 'package:honeybox/services/capture/capture_scan_settings.dart';

void main() {
  late Directory dir;
  setUp(
      () async => dir = await Directory.systemTemp.createTemp('capture_test'));
  tearDown(() async => dir.delete(recursive: true));
  const channel = CaptureChannel(service: 'e0ff', characteristic: 'ffe1');
  test('loads version 1 and saves version 2 command profiles', () async {
    final store = CaptureStore(dir);
    await File('${dir.path}/capture_profiles.json').writeAsString(jsonEncode({
      'version': 1,
      'devices': [
        {
          'id': 'A',
          'name': 'Old',
          'channels': [channel.toJson()]
        }
      ]
    }));
    expect((await store.loadProfiles()).single.startCommands, isEmpty);
    await store.saveProfiles([
      CaptureProfile(id: 'A', name: 'New', channels: [
        channel
      ], startCommands: [
        CaptureCommand(channel: channel, hex: 'aB', withResponse: false),
        CaptureCommand(waitChannel: channel, timeoutSeconds: 60)
      ], stopCommands: [
        CaptureCommand(channel: channel, hex: '00')
      ])
    ]);
    final restored = (await store.loadProfiles()).single;
    expect(restored.startCommands.first.hex, 'ab');
    expect(restored.startCommands.first.withResponse, isFalse);
    expect(restored.startCommands.last.waitChannel, channel);
    expect(restored.stopCommands.single.hex, '00');
    expect(
        jsonDecode(await File('${dir.path}/capture_profiles.json')
            .readAsString())['version'],
        2);
  });
  test('restores scan settings without changing saved devices', () async {
    final store = CaptureStore(dir);
    await store.saveProfiles([
      CaptureProfile(id: 'A', name: 'Watch', channels: [channel])
    ]);
    await Future.wait([
      store.saveScanSettings(const CaptureScanSettings(minimumRssi: -70)),
      store.saveScanSettings(const CaptureScanSettings(
          strongestFirst: false, minimumRssi: -50, hideUnnamed: true)),
    ]);
    final restored = await CaptureStore(dir).loadScanSettings();
    expect(restored.strongestFirst, isFalse);
    expect(restored.minimumRssi, -50);
    expect(restored.hideUnnamed, isTrue);
    expect((await CaptureStore(dir).loadProfiles()).single.id, 'A');
  });
  test('missing scan settings use defaults; invalid settings are retained',
      () async {
    final defaults = await CaptureStore(dir).loadScanSettings();
    expect(defaults.strongestFirst, isTrue);
    expect(defaults.minimumRssi, -127);
    expect(defaults.hideUnnamed, isFalse);
    final file = File('${dir.path}/capture_scan_settings.json');
    await file.writeAsString('{"minimumRssi":-500}');
    await expectLater(
        CaptureStore(dir).loadScanSettings(), throwsFormatException);
    expect(await file.readAsString(), '{"minimumRssi":-500}');
  });
  test('restores multiple devices and their independent channels', () async {
    final store = CaptureStore(dir);
    await store.saveProfiles([
      CaptureProfile(id: 'A', name: '手表', channels: [channel]),
      CaptureProfile(id: 'B', name: '传感器', channels: [
        const CaptureChannel(
            service: '180d', characteristic: '2a37', instance: 2),
      ]),
    ]);
    final restored = await CaptureStore(dir).loadProfiles();
    expect(restored.map((p) => p.id), ['A', 'B']);
    expect(restored[1].channels.single.service, '180d');
    expect(restored[1].channels.single.instance, 2);
    expect(restored.first.channels.single, channel);
  });
  test('corrupt configuration raises an error and leaves source intact',
      () async {
    final file = File('${dir.path}/capture_profiles.json');
    await file.writeAsString('{broken');
    await expectLater(CaptureStore(dir).loadProfiles(), throwsFormatException);
    expect(await file.readAsString(), '{broken');
  });
  test('replaces saved configuration and keeps earlier recording discoverable',
      () async {
    final store = CaptureStore(dir);
    final first = CaptureProfile(id: 'A', name: 'Before', channels: [channel]);
    await store.saveProfiles([first]);
    final writer = await store.openRecording(first);
    await writer.close();
    await store.saveProfiles([
      CaptureProfile(id: 'B', name: 'After', channels: [channel])
    ]);
    expect((await CaptureStore(dir).loadProfiles()).single.id, 'B');
    expect((await CaptureStore(dir).listRecordings()).single.path,
        writer.file.path);
  });
  test('writes exact bytes and ordered metadata then closes the file',
      () async {
    final writer = await CaptureStore(dir).openRecording(
      CaptureProfile(id: 'A', name: '../手表', channels: [channel]),
    );
    await writer.append(CapturePacket(
      deviceId: 'A',
      channel: channel,
      sequence: 1,
      time: DateTime.utc(2026, 10, 26),
      bytes: [0, 255, 128, 10],
    ));
    await writer.close();
    final map = jsonDecode((await writer.file.readAsLines()).single) as Map;
    expect(map['hex'], '00ff800a');
    expect(map['deviceId'], 'A');
    expect(map['sequence'], 1);
    expect(map['time'], '2026-10-26T00:00:00.000Z');
    expect(await writer.file.parent.parent.resolveSymbolicLinks(),
        await Directory('${dir.path}/captures').resolveSymbolicLinks());
  });
  test('interrupted recording is found and resumed after its last full line',
      () async {
    final store = CaptureStore(dir);
    final profile = CaptureProfile(id: 'A', name: 'S100', channels: [channel]);
    CapturePacket packet(int seq) => CapturePacket(
        deviceId: 'A',
        channel: channel,
        sequence: seq,
        time: DateTime.utc(2026, 10, 26),
        bytes: [seq]);
    final closed = await store.openRecording(profile);
    await closed.close();
    expect(await store.findInterrupted(profile), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // Simulates the app being killed: never closed, partial line at the end.
    final killed = await store.openRecording(profile);
    await killed.append(packet(1));
    await killed.flush();
    await killed.file.writeAsString('{"hex":', mode: FileMode.append);
    final found = await store.findInterrupted(profile);
    expect(found?.path, killed.file.path);
    expect(
        await store.findInterrupted(
            CaptureProfile(id: 'B', name: 'X', channels: [channel])),
        isNull);
    final resumed = await store.openRecording(profile, resume: found);
    await resumed.append(packet(2));
    await resumed.close();
    final lines = await killed.file.readAsLines();
    expect(lines.map((l) => (jsonDecode(l) as Map)['sequence']), [1, 2]);
    final meta = jsonDecode(
            await File('${killed.file.parent.path}/device.json').readAsString())
        as Map;
    expect(meta['open'], isFalse);
    expect(meta['resumedAt'], hasLength(1));
    expect(await store.findInterrupted(profile), isNull);
    await killed.close(); // release the handle so Windows can delete the dir
  });
  test('deletes a recording folder and refuses paths outside captures',
      () async {
    final store = CaptureStore(dir);
    final folder = await Directory('${dir.path}/captures/capture_x')
        .create(recursive: true);
    final raw = await File('${folder.path}/raw.jsonl').writeAsString('{}');
    await File('${folder.path}/device.json').writeAsString('{}');
    await store.deleteRecording(raw);
    expect(await folder.exists(), isFalse);
    final outside = await File('${dir.path}/raw.jsonl').writeAsString('{}');
    await expectLater(store.deleteRecording(outside), throwsStateError);
    expect(await outside.exists(), isTrue);
  });
}
