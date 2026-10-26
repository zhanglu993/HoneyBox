import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/jw/jw_models.dart';
import 'package:honeybox/validation/jw_sdk_acceptance.dart';
import '../helpers/jw_fixture.dart';

class TestPort implements JwAcceptancePort {
  DateTime clock = DateTime(2026, 10, 4, 12);
  DateTime? scanStart;
  Duration discoveryDelay = Duration.zero;
  int foundOnAttempt = 1;
  int scans = 0, stops = 0, connections = 0, disconnects = 0;
  bool closed = false, failLanguage = false, failDisconnect = false;
  bool needBind = false, failBind = false;
  int bindCalls = 0;
  bool provideSample = true;
  Duration sampleDateOffset = Duration.zero;
  final languages = <int>[];
  final hearts = <bool>[];
  final times = <DateTime>[];
  @override
  JwDeviceState state = JwDeviceState(
      phase: JwDevicePhase.loggedIn,
      language: 1,
      capabilities:
          JwCapabilities.fromWire(jwHex('4dd17dfce34ad83d'), jwHex('03')));
  Future<void> delay(Duration d) async {
    clock = clock.add(d);
  }

  @override
  Future<void> startScan() async {
    scans++;
    scanStart = clock;
  }

  @override
  void stopScan() {
    stops++;
  }

  @override
  List<ScanDevice> get devices => scans >= foundOnAttempt &&
          scanStart != null &&
          clock.difference(scanStart!) >= discoveryDelay
      ? [
          ScanDevice(
              deviceId: '64:1A:B2:B8:00:3A',
              name: 'S200',
              rssi: -40,
              jwCandidate: true,
              firstSeen: clock,
              identitySeen: clock)
        ]
      : [];
  @override
  Future<void> connect(ScanDevice target) async {
    connections++;
  }

  @override
  Future<void> initialize() async {
    if (needBind) {
      state = state.copyWith(
          phase: JwDevicePhase.loginRejected,
          operationError: 'JwLoginException: Device refused login');
    }
  }

  @override
  Future<void> bindFirstTime({required bool confirmedFirstBind}) async {
    if (!confirmedFirstBind) {
      throw StateError('First bind requires explicit confirmation');
    }
    bindCalls++;
    if (failBind) {
      throw StateError('JwLoginException: Device refused first bind');
    }
    state = state.copyWith(
        phase: JwDevicePhase.loggedIn, operationError: null);
  }
  @override
  Future<String> identityDigest() async => 'd' * 64;
  @override
  Future<void> setLanguage(int value) async {
    languages.add(value);
    state = state.copyWith(language: value);
    if (failLanguage && value == 0) throw StateError('readback failed');
  }

  @override
  Future<void> setHeartRateStreaming(bool enabled) async {
    hearts.add(enabled);
    state = state.copyWith(
        heartRateStreaming: enabled,
        lastHeartRate: enabled && provideSample
            ? JwHeartRateSample(
                bpm: 72,
                date: DateTime(clock.year, clock.month, clock.day)
                    .add(sampleDateOffset),
                minute: 720,
                second: 0,
                receivedAt: clock,
                raw: Uint8List(0))
            : null);
  }

  @override
  Future<void> syncTime(DateTime value) async {
    times.add(value);
    state = state.copyWith(timeSubmitted: true);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    if (failDisconnect) throw StateError('disconnect failed');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  AcceptanceConfig config(
          {Duration scanWindow = const Duration(seconds: 120),
          int attempts = 3,
          int reconnects = 2,
          String mode = 'full',
          String? hash,
          bool labAuthorized = false}) =>
      AcceptanceConfig(
          outputDirectory: 'unused',
          address: '64:1A:B2:B8:00:3A',
          scanWindow: scanWindow,
          scanAttempts: attempts,
          reconnectRounds: reconnects,
          mode: mode,
          labAuthorized: labAuthorized,
          expectedIdentitySha256: hash);
  Future<Map<String, Object?>> run(TestPort p, AcceptanceConfig c,
          {bool Function()? cancelled}) =>
      AcceptanceRunner(
              port: p,
              config: c,
              now: () => p.clock,
              delay: p.delay,
              isCancelled: cancelled ?? () => false,
              record: (_) async {})
          .run();
  test('CLI configuration validates selectors, windows and restart digest', () {
    final c = AcceptanceConfig.parse([
      '--address',
      '64:1a:b2:b8:00:3a',
      '--output',
      'results',
      '--scan-seconds',
      '180',
      '--scan-attempts',
      '4'
    ]);
    expect(c.address, '64:1A:B2:B8:00:3A');
    expect(c.scanWindow, const Duration(seconds: 180));
    expect(c.scanAttempts, 4);
    for (final args in [
      <String>[],
      ['--address', 'DEBUG:1'],
      ['--address', '64:1A:B2:B8:00:3A', '--scan-seconds', '0'],
      ['--address', '64:1A:B2:B8:00:3A', '--mode', 'restart']
    ]) {
      expect(() => AcceptanceConfig.parse(args), throwsArgumentError);
    }
  });
  test('slow discovery beyond fifteen seconds passes actual SDK workflow',
      () async {
    final p = TestPort()..discoveryDelay = const Duration(seconds: 45);
    final report = await run(p, config(reconnects: 0));
    expect(report['exitCode'], 0);
    expect(report['status'], 'pass');
    expect(p.connections, 1);
    expect(p.languages, [0, 1]);
    expect(p.hearts, [true, false]);
    expect(p.times, hasLength(1));
    expect(p.closed, isTrue);
    expect(report['identitySha256'], 'd' * 64);
    final steps = report['steps']! as List;
    expect((steps.first as Map)['name'], 'scan.initial');
    expect((steps.first as Map)['targetName'], 'S200');
    expect(report.toString(), isNot(contains('userId')));
  });
  test('scan retries are bounded and never connect an unseen known address',
      () async {
    final p = TestPort()..foundOnAttempt = 10;
    final report = await run(
        p, config(scanWindow: const Duration(seconds: 2), attempts: 2));
    expect(report['exitCode'], 1);
    expect(p.scans, 2);
    expect(p.connections, 0);
    expect(p.stops, greaterThanOrEqualTo(2));
    expect(p.closed, isTrue);
  });
  test('cancel ends scanning with distinct exit code and cleanup', () async {
    final p = TestPort()..discoveryDelay = const Duration(seconds: 60);
    final report = await run(p, config(), cancelled: () => p.clock.minute >= 1);
    expect(report['exitCode'], 2);
    expect(report['status'], 'cancelled');
    expect(p.connections, 0);
    expect(p.closed, isTrue);
    expect(p.stops, greaterThan(0));
  });
  test('language failure still restores original and cannot report pass',
      () async {
    final p = TestPort()..failLanguage = true;
    final report = await run(p, config());
    expect(report['exitCode'], 1);
    expect(p.languages, [0, 1]);
    expect(p.state.language, 1);
    expect(p.hearts, isEmpty);
    expect(p.closed, isTrue);
  });
  test('full mode reconnects twice through discovery and preserves identity',
      () async {
    final p = TestPort();
    final report = await run(p, config());
    expect(report['exitCode'], 0);
    expect(p.connections, 3);
    expect(p.scans, 3);
    expect(p.languages, [0, 1]);
    expect(p.times, hasLength(1));
    expect(p.disconnects, greaterThanOrEqualTo(3));
    expect(p.closed, isTrue);
  });
  test('separate restart mode compares digest and only reads and logs in',
      () async {
    final p = TestPort();
    final report = await run(p, config(mode: 'restart', hash: 'd' * 64));
    expect(report['exitCode'], 0);
    expect(p.connections, 1);
    expect(p.languages, isEmpty);
    expect(p.hearts, isEmpty);
    expect(p.times, isEmpty);
    final bad = TestPort();
    final failure = await run(bad, config(mode: 'restart', hash: 'e' * 64));
    expect(failure['exitCode'], 1);
    expect(bad.closed, isTrue);
  });
  test('disconnect failure still closes host and reports failed cleanup',
      () async {
    final p = TestPort()..failDisconnect = true;
    final report = await run(p, config(reconnects: 0));
    expect(report['exitCode'], 1);
    expect(p.closed, isTrue);
  });
  test('heart sample timeout attempts stop and cannot submit time', () async {
    final p = TestPort()..provideSample = false;
    final report = await run(p, config(reconnects: 0));
    expect(report['exitCode'], 1);
    expect(report['error'], contains('No valid real heart sample'));
    expect(p.hearts, [true, false]);
    expect(p.times, isEmpty);
    expect(p.closed, isTrue);
  });
  test('heart wait cancellation attempts stop and cleans host', () async {
    final p = TestPort()..provideSample = false;
    final report = await run(p, config(reconnects: 0),
        cancelled: () => p.hearts.contains(true) && p.clock.second >= 1);
    expect(report['exitCode'], 2);
    expect(report['status'], 'cancelled');
    expect(p.hearts, [true, false]);
    expect(p.times, isEmpty);
    expect(p.closed, isTrue);
  });
  test('different device date blocks time and still stops measurement',
      () async {
    final p = TestPort()..sampleDateOffset = const Duration(days: -1);
    final report = await run(p, config(reconnects: 0));
    expect(report['exitCode'], 1);
    expect(report['error'], contains('Device date differs'));
    expect(p.hearts, [true, false]);
    expect(p.times, isEmpty);
    expect(p.closed, isTrue);
    expect(p.languages, [0, 1]);
  });
  test('need-bind without lab authorization fails at query_login', () async {
    final p = TestPort()..needBind = true;
    final report =
        await run(p, config(mode: 'restart', hash: 'd' * 64));
    expect(report['exitCode'], 1);
    expect(report['firstBind'],
        'not_run_no_destructive_action_authorization');
    expect(p.bindCalls, 0);
    expect(p.closed, isTrue);
  });
  test('need-bind with lab authorization runs firstBind then continues',
      () async {
    final p = TestPort()..needBind = true;
    final report = await run(
        p, config(mode: 'restart', hash: 'd' * 64, labAuthorized: true));
    expect(report['exitCode'], 0);
    expect(report['firstBind'], 'pass');
    expect(p.bindCalls, 1);
    expect(p.state.phase, JwDevicePhase.loggedIn);
    expect(p.closed, isTrue);
  });
  test('lab authorization without need-bind reports firstBind not_needed',
      () async {
    final report = await run(
        TestPort(), config(mode: 'restart', hash: 'd' * 64, labAuthorized: true));
    expect(report['exitCode'], 0);
    expect(report['firstBind'], 'not_needed');
  });
  test('CLI lab-authorized flag is parsed for Phase1 destructive bind', () {
    final c = AcceptanceConfig.parse([
      '--address',
      '64:1A:B2:B8:00:3A',
      '--lab-authorized',
      'true'
    ]);
    expect(c.labAuthorized, isTrue);
  });
}
