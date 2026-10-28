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

/// A write or a first-packet barrier, executed in list order.
class CaptureCommand {
  final CaptureChannel? channel;
  final String? hex;
  final bool withResponse;
  final bool polarResponse;
  final CaptureChannel? waitChannel;
  final String prefix;
  final int timeoutSeconds;
  CaptureCommand(
      {this.channel,
      this.hex,
      this.withResponse = true,
      this.polarResponse = false,
      this.waitChannel,
      this.prefix = '',
      this.timeoutSeconds = 10}) {
    if (timeoutSeconds <= 0 ||
        !((channel != null && hex != null && waitChannel == null) ||
            (channel == null && hex == null && waitChannel != null)) ||
        (hex != null && !RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(hex!)) ||
        !RegExp(r'^(?:[0-9a-fA-F]{2})*$').hasMatch(prefix) ||
        (polarResponse && (hex == null || hex!.length < 4))) {
      throw const FormatException('控制步骤无效');
    }
  }
  List<int> get bytes => [
        for (var i = 0; i < hex!.length; i += 2)
          int.parse(hex!.substring(i, i + 2), radix: 16)
      ];
  Map<String, dynamic> toJson() => {
        if (channel != null) 'channel': channel!.toJson(),
        if (hex != null) 'hex': hex!.toLowerCase(),
        'withResponse': withResponse,
        'polarResponse': polarResponse,
        if (waitChannel != null) 'waitChannel': waitChannel!.toJson(),
        'prefix': prefix,
        'timeoutSeconds': timeoutSeconds,
      };
  factory CaptureCommand.fromJson(Map<String, dynamic> j) => CaptureCommand(
        channel:
            j['channel'] == null ? null : CaptureChannel.fromJson(j['channel']),
        hex: j['hex'],
        withResponse: j['withResponse'] as bool? ?? true,
        polarResponse: j['polarResponse'] as bool? ?? false,
        waitChannel: j['waitChannel'] == null
            ? null
            : CaptureChannel.fromJson(j['waitChannel']),
        prefix: j['prefix'] as String? ?? '',
        timeoutSeconds: j['timeoutSeconds'] as int? ?? 10,
      );
}

class CaptureProfile {
  final String id;
  final String name;
  final List<CaptureChannel> channels;
  final List<CaptureCommand> startCommands;
  final List<CaptureCommand> stopCommands;
  final int minimumMtu;
  final Map<String, dynamic>? polarOptions;
  CaptureProfile(
      {required this.id,
      required this.name,
      required List<CaptureChannel> channels,
      List<CaptureCommand> startCommands = const [],
      List<CaptureCommand> stopCommands = const [],
      this.minimumMtu = 0,
      this.polarOptions})
      : startCommands = List.unmodifiable(startCommands),
        stopCommands = List.unmodifiable(stopCommands),
        channels = List.unmodifiable(channels) {
    if (minimumMtu < 0 ||
        minimumMtu > 517 ||
        [...startCommands, ...stopCommands].any((c) =>
            (c.waitChannel != null && !channels.contains(c.waitChannel)) ||
            (c.polarResponse && !channels.contains(c.channel)))) {
      throw const FormatException('MTU 或控制步骤的订阅通道无效');
    }
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
        'channels': channels.map((c) => c.toJson()).toList(),
        'startCommands': startCommands.map((c) => c.toJson()).toList(),
        'stopCommands': stopCommands.map((c) => c.toJson()).toList(),
        'minimumMtu': minimumMtu,
        if (polarOptions != null) 'polarOptions': polarOptions,
      };
  factory CaptureProfile.fromJson(Map<String, dynamic> json) => CaptureProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        minimumMtu: json['minimumMtu'] as int? ?? 0,
        polarOptions: json['polarOptions'] as Map<String, dynamic>?,
        startCommands: (json['startCommands'] as List? ?? [])
            .map((c) => CaptureCommand.fromJson(c))
            .toList(),
        stopCommands: (json['stopCommands'] as List? ?? [])
            .map((c) => CaptureCommand.fromJson(c))
            .toList(),
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
  final String? event;
  final Map<String, dynamic> details;
  CapturePacket(
      {required this.deviceId,
      required this.channel,
      required this.sequence,
      required this.time,
      required List<int> bytes,
      this.event,
      this.details = const {}})
      : bytes = List.unmodifiable(bytes);
  String get hex =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  Map<String, dynamic> toJson() => {
        'time': time.toUtc().toIso8601String(),
        'sequence': sequence,
        'deviceId': deviceId,
        ...channel.toJson(),
        'hex': hex,
        if (event != null) 'event': event,
        ...details,
      };
}
