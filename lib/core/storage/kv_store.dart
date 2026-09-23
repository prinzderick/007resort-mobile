import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small async key/value store. Production uses the Android Keystore-backed
/// secure storage (tokens, device credential, queue key); tests use memory.
abstract class KvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureKvStore implements KvStore {
  SecureKvStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryKvStore implements KvStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

abstract final class Keys {
  static const serverUrl = 'r007.serverUrl';
  static const device = 'r007.device';
  static const checkout = 'r007.checkout';
  static const queueKey = 'r007.queueKey';
  static const hardwareId = 'r007.hardwareId';
}
