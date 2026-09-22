import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/device/device_mode.dart';

void main() {
  group('DeviceMode.fromApi', () {
    test('parses every known API value', () {
      expect(DeviceMode.fromApi('ATTENDANT'), DeviceMode.attendant);
      expect(DeviceMode.fromApi('SUPERVISOR'), DeviceMode.supervisor);
      expect(DeviceMode.fromApi('SPORTS_ENTRANCE'), DeviceMode.sportsEntrance);
      expect(DeviceMode.fromApi('SPORTS_STORE'), DeviceMode.sportsStore);
      expect(DeviceMode.fromApi('UNREGISTERED'), DeviceMode.unregistered);
    });

    test('is tolerant of case, whitespace and hyphens', () {
      expect(DeviceMode.fromApi(' attendant '), DeviceMode.attendant);
      expect(DeviceMode.fromApi('sports-entrance'), DeviceMode.sportsEntrance);
    });

    test('falls back to unregistered for null, empty or unknown values', () {
      expect(DeviceMode.fromApi(null), DeviceMode.unregistered);
      expect(DeviceMode.fromApi(''), DeviceMode.unregistered);
      expect(DeviceMode.fromApi('ADMIN'), DeviceMode.unregistered);
    });

    test('round-trips apiValue', () {
      for (final mode in DeviceMode.values) {
        expect(DeviceMode.fromApi(mode.apiValue), mode);
      }
    });
  });
}
