class CaptureScanSettings {
  final bool strongestFirst;

  /// -127 means no RSSI cutoff.
  final int minimumRssi;
  final bool hideUnnamed;
  const CaptureScanSettings(
      {this.strongestFirst = true,
      this.minimumRssi = -127,
      this.hideUnnamed = false});

  Map<String, dynamic> toJson() => {
        'version': 1,
        'strongestFirst': strongestFirst,
        'minimumRssi': minimumRssi,
        'hideUnnamed': hideUnnamed
      };

  factory CaptureScanSettings.fromJson(Map<String, dynamic> json) {
    final strongest = json['strongestFirst'] ?? true;
    final rssi = json['minimumRssi'] ?? -127;
    final unnamed = json['hideUnnamed'] ?? false;
    if (strongest is! bool ||
        unnamed is! bool ||
        rssi is! int ||
        ![-127, -90, -80, -70, -60, -50, -40].contains(rssi)) {
      throw const FormatException('筛选条件无效');
    }
    return CaptureScanSettings(
        strongestFirst: strongest, minimumRssi: rssi, hideUnnamed: unnamed);
  }
}
