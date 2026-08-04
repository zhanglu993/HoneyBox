import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_gatt_profile.dart';

void main() {
  group('BleGattProfile.select', () {
    test('matches exact four-character UUIDs case-insensitively', () {
      final profile = BleGattProfile.select(<BleGattCharacteristic<String>>[
        const BleGattCharacteristic(
          'command-tx',
          'ffc1',
          writeWithoutResponse: true,
        ),
        const BleGattCharacteristic('command-rx', 'FFC2', notify: true),
        const BleGattCharacteristic('stream-tx', 'FfC4', write: true),
        const BleGattCharacteristic('stream-rx', 'fFc5', indicate: true),
      ]);

      expect(profile.commandReady, isTrue);
      expect(profile.commandTx!.value, 'command-tx');
      expect(profile.commandRx, 'command-rx');
      expect(profile.streamReady, isTrue);
      expect(profile.streamTx!.value, 'stream-tx');
      expect(profile.streamRx, 'stream-rx');
    });

    test('matches exact Bluetooth-base UUIDs', () {
      final profile = BleGattProfile.select(<BleGattCharacteristic<String>>[
        const BleGattCharacteristic(
          'command-tx',
          '0000FFC1-0000-1000-8000-00805F9B34FB',
          write: true,
        ),
        const BleGattCharacteristic(
          'command-rx',
          '0000ffc2-0000-1000-8000-00805f9b34fb',
          notify: true,
        ),
        const BleGattCharacteristic(
          'stream-tx',
          '0000FFC4-0000-1000-8000-00805F9B34FB',
          write: true,
        ),
        const BleGattCharacteristic(
          'stream-rx',
          '0000FFC5-0000-1000-8000-00805F9B34FB',
          notify: true,
        ),
      ]);

      expect(profile.commandReady, isTrue);
      expect(profile.streamReady, isTrue);
    });

    test('keeps command and stream pair readiness independent', () {
      final profile = BleGattProfile.select(<BleGattCharacteristic<String>>[
        const BleGattCharacteristic('ffc4', 'FFC4', write: true),
        const BleGattCharacteristic(
          'ffc5',
          '0000FFC5-0000-1000-8000-00805F9B34FB',
          notify: true,
        ),
      ]);

      expect(profile.commandReady, isFalse);
      expect(profile.streamReady, isTrue);
      expect(profile.streamTx!.withoutResponse, isFalse);
    });

    test('requires both endpoints and supported properties for each pair', () {
      final profile = BleGattProfile.select(<BleGattCharacteristic<String>>[
        const BleGattCharacteristic('command-tx', 'FFC1'),
        const BleGattCharacteristic('command-rx', 'FFC2'),
        const BleGattCharacteristic('stream-tx', 'FFC4', write: true),
        const BleGattCharacteristic('stream-rx', 'FFC5'),
      ]);

      expect(profile.commandReady, isFalse);
      expect(profile.commandTx, isNull);
      expect(profile.commandRx, isNull);
      expect(profile.streamReady, isFalse);
      expect(profile.streamTx, isNotNull);
      expect(profile.streamRx, isNull);
    });

    test('accepts notify or indicate receive characteristics', () {
      final notifyProfile = BleGattProfile.select(
        <BleGattCharacteristic<String>>[
          const BleGattCharacteristic('tx', 'FFC1', write: true),
          const BleGattCharacteristic('rx', 'FFC2', notify: true),
        ],
      );
      final indicateProfile = BleGattProfile.select(
        <BleGattCharacteristic<String>>[
          const BleGattCharacteristic('tx', 'FFC4', write: true),
          const BleGattCharacteristic('rx', 'FFC5', indicate: true),
        ],
      );

      expect(notifyProfile.commandReady, isTrue);
      expect(indicateProfile.streamReady, isTrue);
    });

    test('prefers writes without response and falls back to write response',
        () {
      final preferredProfile = BleGattProfile.select(
        <BleGattCharacteristic<String>>[
          const BleGattCharacteristic(
            'tx',
            'FFC1',
            write: true,
            writeWithoutResponse: true,
          ),
          const BleGattCharacteristic('rx', 'FFC2', notify: true),
        ],
      );
      final fallbackProfile = BleGattProfile.select(
        <BleGattCharacteristic<String>>[
          const BleGattCharacteristic('tx', 'FFC4', write: true),
          const BleGattCharacteristic('rx', 'FFC5', notify: true),
        ],
      );

      expect(preferredProfile.commandTx!.withoutResponse, isTrue);
      expect(fallbackProfile.streamTx!.withoutResponse, isFalse);
    });

    test('does not match UUIDs that merely contain a target UUID', () {
      final profile = BleGattProfile.select(<BleGattCharacteristic<String>>[
        const BleGattCharacteristic('tx', 'A-FFC1-B', write: true),
        const BleGattCharacteristic('rx', '0000FFC20', notify: true),
      ]);

      expect(profile.commandReady, isFalse);
      expect(profile.commandTx, isNull);
      expect(profile.commandRx, isNull);
    });
  });
}
