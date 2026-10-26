import 'capture_models.dart';

const polarService = 'fb005c80-02e7-f387-1cad-8acd2d8df0c8';
const polarControl = 'fb005c81-02e7-f387-1cad-8acd2d8df0c8';
const polarData = 'fb005c82-02e7-f387-1cad-8acd2d8df0c8';

class PolarCaptureOptions {
  final bool ecg, acc;
  final int rate, range;
  const PolarCaptureOptions(
      {this.ecg = true, this.acc = true, this.rate = 25, this.range = 8});
  Map<String, dynamic> toJson() =>
      {'ecg': ecg, 'acc': acc, 'rate': rate, 'range': range};
  factory PolarCaptureOptions.fromJson(Map<String, dynamic> j) =>
      PolarCaptureOptions(
          ecg: j['ecg'] as bool? ?? true,
          acc: j['acc'] as bool? ?? true,
          rate: j['rate'] as int? ?? 25,
          range: j['range'] as int? ?? 8);
}

CaptureProfile polarCaptureProfile(
    {required String id,
    required String name,
    required Iterable<CaptureChannel> available,
    PolarCaptureOptions options = const PolarCaptureOptions()}) {
  if (![25, 50, 100, 200].contains(options.rate) ||
      ![2, 4, 8].contains(options.range)) {
    throw const FormatException('Polar ACC 参数无效');
  }
  CaptureChannel find(String service, String characteristic) {
    final matches = available
        .where((c) =>
            normalizeCaptureUuid(c.service) == service &&
            normalizeCaptureUuid(c.characteristic) == characteristic)
        .toList();
    if (matches.length != 1) {
      throw StateError('未发现唯一 Polar H10 特征：$characteristic');
    }
    return matches.single;
  }

  final hr = find('180d', '2a37');
  if (!options.ecg && !options.acc) {
    return CaptureProfile(
        id: id, name: name, channels: [hr], polarOptions: options.toJson());
  }
  final cp = find(polarService, polarControl),
      data = find(polarService, polarData);
  CaptureCommand write(String hex) =>
      CaptureCommand(channel: cp, hex: hex, polarResponse: true);
  final stops = [write('0300'), write('0302')];
  return CaptureProfile(
      id: id,
      name: name,
      channels: [hr, cp, data],
      minimumMtu: 232,
      polarOptions: options.toJson(),
      stopCommands: stops,
      startCommands: [
        ...stops,
        if (options.ecg) ...[
          write('02000001820001010e00'),
          CaptureCommand(waitChannel: data, prefix: '00', timeoutSeconds: 60),
        ],
        if (options.acc)
          write(
              '02020001${options.rate.toRadixString(16).padLeft(2, '0')}00010110000201${options.range.toRadixString(16).padLeft(2, '0')}00'),
      ]);
}

class CaptureConfigurationException implements Exception {
  final String message;
  const CaptureConfigurationException(this.message);
  @override
  String toString() => message;
}

void checkPolarResponse(List<int> bytes) {
  if (bytes.length < 5 || bytes[0] != 0xf0) {
    throw const CaptureConfigurationException('Polar 控制响应无效');
  }
  final status = bytes[3];
  if (status != 0 && status != 6) {
    throw CaptureConfigurationException(status == 10
        ? 'Polar invalid_mtu=10：需要协商 MTU ≥ 232'
        : 'Polar 控制命令失败：status=$status');
  }
}
