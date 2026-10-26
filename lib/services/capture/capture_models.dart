String normalizeCaptureUuid(String value) {
  var uuid = value.trim().toLowerCase();
  if (uuid.length == 36 &&
      uuid.startsWith('0000') &&
      uuid.endsWith('-0000-1000-8000-00805f9b34fb')) {
    uuid = uuid.substring(4, 8);
  }
  if (!RegExp(
          r'^(?:[0-9a-f]{4}|[0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$')
      .hasMatch(uuid)) {
    throw FormatException('无效 UUID：$value');
  }
  return uuid;
}

class CaptureChannel {
  final String service;
  final String characteristic;
  final String? primaryService;
  final int instance;
  const CaptureChannel(
      {required this.service,
      required this.characteristic,
      this.primaryService,
      this.instance = 0});

  String get key =>
      '${primaryService == null ? '' : normalizeCaptureUuid(primaryService!)}:'
      '${normalizeCaptureUuid(service)}:${normalizeCaptureUuid(characteristic)}:$instance';
  Map<String, dynamic> toJson() => {
        'service': normalizeCaptureUuid(service),
        'characteristic': normalizeCaptureUuid(characteristic),
        'primaryService': primaryService == null
            ? null
            : normalizeCaptureUuid(primaryService!),
        'instance': instance,
      };
  factory CaptureChannel.fromJson(Map<String, dynamic> json) {
    final channel = CaptureChannel(
      service: normalizeCaptureUuid(json['service'] as String),
      characteristic: normalizeCaptureUuid(json['characteristic'] as String),
      primaryService: json['primaryService'] == null
          ? null
          : normalizeCaptureUuid(json['primaryService'] as String),
      instance: json['instance'] as int? ?? 0,
    );
    if (channel.instance < 0) throw const FormatException('特征实例无效');
    return channel;
  }
  @override
  bool operator ==(Object other) => other is CaptureChannel && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

class CaptureProfile {
  final String id;
  final String name;
  final List<CaptureChannel> channels;
  CaptureProfile(
      {required this.id,
      required this.name,
      required List<CaptureChannel> channels})
      : channels = List.unmodifiable(channels) {
    if (id.trim().isEmpty ||
        name.trim().isEmpty ||
        channels.isEmpty ||
        channels.toSet().length != channels.length) {
      throw const FormatException('设备名称、ID 和订阅特征不能为空，特征不能重复');
    }
  }
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'channels': channels.map((c) => c.toJson()).toList()
      };
  factory CaptureProfile.fromJson(Map<String, dynamic> json) => CaptureProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        channels: (json['channels'] as List)
            .map((c) => CaptureChannel.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

class CapturePacket {
  final String deviceId;
  final CaptureChannel channel;
  final int sequence;
  final DateTime time;
  final List<int> bytes;
  CapturePacket(
      {required this.deviceId,
      required this.channel,
      required this.sequence,
      required this.time,
      required List<int> bytes})
      : bytes = List.unmodifiable(bytes);
  String get hex =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  Map<String, dynamic> toJson() => {
        'time': time.toUtc().toIso8601String(),
        'sequence': sequence,
        'deviceId': deviceId,
        ...channel.toJson(),
        'hex': hex
      };
}
