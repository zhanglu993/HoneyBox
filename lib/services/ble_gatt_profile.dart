class BleGattCharacteristic<T> {
  const BleGattCharacteristic(
    this.value,
    this.uuid, {
    this.write = false,
    this.writeWithoutResponse = false,
    this.notify = false,
    this.indicate = false,
  });

  final T value;
  final String uuid;
  final bool write;
  final bool writeWithoutResponse;
  final bool notify;
  final bool indicate;
}

class BleGattEndpoint<T> {
  const BleGattEndpoint(this.value, {required this.withoutResponse});

  final T value;
  final bool withoutResponse;
}

/// Owns one atomically published connection value across replacements.
class BleConnectionOwner<T> {
  int _generation = 0;
  T? _value;

  int get generation => _generation;
  T? get value => _value;

  /// Starts a replacement generation and retires the previously published
  /// value synchronously before the replacement can publish anything.
  int replace([void Function(T? value)? onRetire]) {
    final retired = _value;
    _generation++;
    try {
      onRetire?.call(retired);
    } finally {
      _value = null;
    }
    return _generation;
  }

  bool isCurrent(int generation) => generation == _generation;

  /// Publishes only if setup still belongs to the current generation.
  bool publish(int generation, T value) {
    if (!isCurrent(generation)) return false;
    _value = value;
    return true;
  }

  /// Runs a connection-owned side effect only for the current generation.
  bool runIfCurrent(int generation, void Function() action) {
    if (!isCurrent(generation)) return false;
    action();
    return true;
  }

  /// Invalidates and retires the current generation, ignoring stale callers.
  bool clearIfCurrent(
    int generation,
    void Function(T? value) onRetire,
  ) {
    if (!isCurrent(generation)) return false;
    final retired = _value;
    _generation++;
    try {
      onRetire(retired);
    } finally {
      _value = null;
    }
    return true;
  }
}

class BleGattProfile<T> {
  const BleGattProfile({
    this.commandTx,
    this.commandRx,
    this.streamTx,
    this.streamRx,
  });

  factory BleGattProfile.select(
    Iterable<BleGattCharacteristic<T>> characteristics,
  ) {
    BleGattEndpoint<T>? commandTx;
    T? commandRx;
    BleGattEndpoint<T>? streamTx;
    T? streamRx;

    for (final characteristic in characteristics) {
      final uuid = _normalizeUuid(characteristic.uuid);
      switch (uuid) {
        case 'FFC1':
          commandTx = _selectWriteEndpoint(commandTx, characteristic);
        case 'FFC2':
          if (characteristic.notify || characteristic.indicate) {
            commandRx ??= characteristic.value;
          }
        case 'FFC4':
          streamTx = _selectWriteEndpoint(streamTx, characteristic);
        case 'FFC5':
          if (characteristic.notify || characteristic.indicate) {
            streamRx ??= characteristic.value;
          }
      }
    }

    return BleGattProfile<T>(
      commandTx: commandTx,
      commandRx: commandRx,
      streamTx: streamTx,
      streamRx: streamRx,
    );
  }

  final BleGattEndpoint<T>? commandTx;
  final T? commandRx;
  final BleGattEndpoint<T>? streamTx;
  final T? streamRx;

  bool get commandReady => commandTx != null && commandRx != null;
  bool get streamReady => streamTx != null && streamRx != null;

  static BleGattEndpoint<T>? _selectWriteEndpoint<T>(
    BleGattEndpoint<T>? current,
    BleGattCharacteristic<T> characteristic,
  ) {
    if (!characteristic.write && !characteristic.writeWithoutResponse) {
      return current;
    }

    final candidate = BleGattEndpoint<T>(
      characteristic.value,
      withoutResponse: characteristic.writeWithoutResponse,
    );
    if (current == null ||
        (!current.withoutResponse && candidate.withoutResponse)) {
      return candidate;
    }
    return current;
  }

  static String? _normalizeUuid(String uuid) {
    final upper = uuid.toUpperCase();
    if (upper == 'FFC1' ||
        upper == 'FFC2' ||
        upper == 'FFC4' ||
        upper == 'FFC5') {
      return upper;
    }

    const baseSuffix = '-0000-1000-8000-00805F9B34FB';
    if (upper.length == 36 &&
        upper.startsWith('0000') &&
        upper.endsWith(baseSuffix)) {
      final shortUuid = upper.substring(4, 8);
      if (shortUuid == 'FFC1' ||
          shortUuid == 'FFC2' ||
          shortUuid == 'FFC4' ||
          shortUuid == 'FFC5') {
        return shortUuid;
      }
    }
    return null;
  }
}
