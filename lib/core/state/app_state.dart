import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../api/http_api.dart';
import '../api/r007_api.dart';
import '../config/app_config.dart';
import '../device/device_mode.dart';
import '../mock/mock_api.dart';
import '../models/models.dart';
import '../storage/kv_store.dart';
import '../util/json.dart';

const _uuid = Uuid();

/// Client-generated ids MUST be UUIDv7 (contract: non-v7 ids are rejected 422).
String newId() => _uuid.v7();

// ---------------------------------------------------------------- config

final appConfigProvider = Provider<AppConfig>(
  (_) => throw UnimplementedError('appConfigProvider must be overridden'),
);
final kvStoreProvider = Provider<KvStore>(
  (_) => throw UnimplementedError('kvStoreProvider must be overridden'),
);

/// Background timers (polling, connectivity probe, idle lock). Disabled in
/// widget tests to keep them deterministic.
final timersEnabledProvider = Provider<bool>((_) => true);

/// Sound + haptics on alerts; disabled in tests (no platform channel).
final feedbackEnabledProvider = Provider<bool>((_) => true);

// ------------------------------------------------------------ app state

class AppState {
  const AppState({
    this.serverUrl,
    this.device,
    this.session,
    this.checkout,
    this.checkoutStaffId,
    this.locked = false,
  });

  final String? serverUrl;
  final DeviceIdentity? device;
  final AuthSession? session;
  final Checkout? checkout;
  final String? checkoutStaffId;
  final bool locked;

  DeviceMode get mode => device?.mode ?? DeviceMode.unregistered;
  Staff? get staff => session?.staff;

  /// The facility this tablet is currently serving.
  String? get facilityId => mode == DeviceMode.attendant
      ? checkout?.facility.id
      : (checkout?.facility.id ?? device?.homeFacilityId);
  String? get facilityName {
    final n = checkout?.facility.name;
    return (n != null && n.isNotEmpty) ? n : device?.homeFacilityName;
  }

  /// Dedicated tablets (supervisor / sports) are bound to a home facility and
  /// are checked out automatically at sign-in; the waiter pool is not.
  bool get isDedicated =>
      device?.homeFacilityId != null &&
      (mode == DeviceMode.supervisor ||
          mode == DeviceMode.sportsEntrance ||
          mode == DeviceMode.sportsStore);

  bool can(String permission) => session?.staff.can(permission) ?? false;

  AppState copyWith({
    String? serverUrl,
    DeviceIdentity? device,
    AuthSession? session,
    Checkout? checkout,
    String? checkoutStaffId,
    bool? locked,
    bool clearSession = false,
    bool clearCheckout = false,
    bool clearDevice = false,
  }) => AppState(
    serverUrl: serverUrl ?? this.serverUrl,
    device: clearDevice ? null : (device ?? this.device),
    session: clearSession ? null : (session ?? this.session),
    checkout: clearCheckout ? null : (checkout ?? this.checkout),
    checkoutStaffId: clearCheckout
        ? null
        : (checkoutStaffId ?? this.checkoutStaffId),
    locked: locked ?? this.locked,
  );
}

/// Loads persisted bootstrap state (server URL, device, checkout, session).
Future<AppState> loadAppState(KvStore kv, AppConfig config) async {
  Json? decode(String? s) {
    if (s == null) return null;
    try {
      return jsonDecode(s) as Json;
    } on Object {
      return null;
    }
  }

  final url = await kv.read(Keys.serverUrl);
  final dev = decode(await kv.read(Keys.device));
  final co = decode(await kv.read(Keys.checkout));
  final sess = decode(await kv.read('r007.session'));
  return AppState(
    serverUrl: (url != null && url.isNotEmpty)
        ? url
        : (config.presetApiBaseUrl.isNotEmpty ? config.presetApiBaseUrl : null),
    device: dev == null ? null : DeviceIdentity.fromJson(dev),
    checkout: co == null ? null : Checkout.fromJson(co),
    checkoutStaffId: co?.strOrNull('staffId'),
    session: sess == null ? null : AuthSession.fromStored(sess),
    // A restored session always needs the PIN again (device may have restarted).
    locked: sess != null,
  );
}

final initialAppStateProvider = Provider<AppState>(
  (_) => throw UnimplementedError('initialAppStateProvider must be overridden'),
);

/// Server address, held outside [appControllerProvider] on purpose:
/// [apiProvider] watches it and [AppController] reads [apiProvider], so
/// deriving it from the controller state created a provider cycle
/// (CircularDependencyError on enrolment in real mode).
final serverUrlProvider = StateProvider<String?>(
  (ref) => ref.read(initialAppStateProvider).serverUrl,
);

/// The single backend seam: Mock (`R007_MOCK=true`) or the real HTTP API.
final apiProvider = Provider<R007Api>((ref) {
  final config = ref.watch(appConfigProvider);
  final R007Api api;
  if (config.useMock) {
    api = MockR007Api();
  } else {
    api = HttpR007Api(
      baseUrl: ref.watch(serverUrlProvider) ?? 'http://localhost',
    );
  }
  final s = ref.read(appControllerProvider);
  api.setDeviceToken(s.device?.deviceToken);
  if (s.session != null) {
    api.setSession(
      s.session,
      onRefreshed: ref.read(appControllerProvider.notifier)._onRefreshed,
    );
  }
  ref.onDispose(api.close);
  return api;
});

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

class AppController extends Notifier<AppState> {
  @override
  AppState build() => ref.read(initialAppStateProvider);

  KvStore get _kv => ref.read(kvStoreProvider);
  R007Api get _api => ref.read(apiProvider);

  Future<void> _persistJson(String key, Json? value) async {
    if (value == null) {
      await _kv.delete(key);
    } else {
      await _kv.write(key, jsonEncode(value));
    }
  }

  void _onRefreshed(AuthSession s) {
    state = state.copyWith(session: s);
    unawaited(_persistJson('r007.session', s.toJson()));
  }

  // ------------------------------------------------------------ bootstrap

  /// Verifies the server answers `/system/info` before saving the URL.
  Future<SystemInfo> probeServer(String url) async {
    final probe = HttpR007Api(baseUrl: url);
    try {
      return await probe.systemInfo();
    } finally {
      probe.close();
    }
  }

  Future<void> setServerUrl(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    await _kv.write(Keys.serverUrl, clean);
    ref.read(serverUrlProvider.notifier).state = clean;
    state = state.copyWith(serverUrl: clean);
  }

  Future<void> forgetServer() async {
    await _kv.delete(Keys.serverUrl);
    await resetDevice();
    final preset = ref.read(appConfigProvider).presetApiBaseUrl;
    final url = preset.isEmpty ? null : preset;
    ref.read(serverUrlProvider.notifier).state = url;
    state = AppState(serverUrl: url);
  }

  Future<String> hardwareId() async {
    var id = await _kv.read(Keys.hardwareId);
    if (id == null) {
      id = newId();
      await _kv.write(Keys.hardwareId, id);
    }
    return id;
  }

  Future<void> enrol({
    required String name,
    required String code,
    String kind = 'MOBILE_TABLET',
    String? mode,
  }) async {
    final device = await _api.registerDevice(
      name: name,
      kind: kind,
      hardwareId: await hardwareId(),
      registrationCode: code,
      mode: mode,
      idempotencyKey: newId(),
    );
    _api.setDeviceToken(device.deviceToken);
    await _persistJson(Keys.device, device.toJson());
    state = state.copyWith(device: device);
  }

  Future<void> resetDevice() async {
    await _kv.delete(Keys.device);
    await _kv.delete(Keys.checkout);
    await _kv.delete('r007.session');
    _api.setDeviceToken(null);
    _api.setSession(null);
    state = AppState(serverUrl: state.serverUrl);
  }

  // ------------------------------------------------------------ session

  Future<void> login({
    String? identifier,
    required String secret,
    required String credentialType,
  }) async {
    final session = await _api.loginStaff(
      identifier: identifier,
      secret: secret,
      credentialType: credentialType,
    );
    _api.setSession(session, onRefreshed: _onRefreshed);
    await _persistJson('r007.session', session.toJson());
    // A different person picking up the tablet invalidates the old checkout.
    var next = state.copyWith(session: session, locked: false);
    if (state.checkout != null &&
        state.checkoutStaffId != null &&
        state.checkoutStaffId != session.staff.id) {
      await _kv.delete(Keys.checkout);
      next = next.copyWith(clearCheckout: true);
    }
    state = next;
    await _autoCheckout();
  }

  /// Dedicated tablets (supervisor, Sports Entrance/Store) bind to their home
  /// facility automatically; a 409 means it is already checked out.
  Future<void> _autoCheckout() async {
    final d = state.device;
    if (d == null ||
        !state.isDedicated ||
        state.checkout != null ||
        state.session == null) {
      return;
    }
    final Facility home = Facility(
      id: d.homeFacilityId!,
      name: d.homeFacilityName ?? '',
      kind: d.homeFacilityKind ?? '',
    );
    try {
      final c = await _api.checkoutDevice(
        deviceId: d.deviceId,
        staffId: state.session!.staff.id,
        facilityId: home.id,
        idempotencyKey: newId(),
      );
      state = state.copyWith(
        checkout: Checkout(
          facility: home,
          staffId: c.staffId,
          checkedOutAt: c.checkedOutAt,
        ),
        checkoutStaffId: state.session!.staff.id,
      );
    } on ApiProblem catch (e) {
      if (e.status != 409) rethrow;
      state = state.copyWith(
        checkout: Checkout(facility: home),
        checkoutStaffId: state.session!.staff.id,
      );
    }
  }

  Future<void> logout() async {
    final d = state.device;
    if (d != null && state.isDedicated && state.checkout != null) {
      try {
        await _api.checkinDevice(deviceId: d.deviceId, idempotencyKey: newId());
      } on Object {
        // best effort
      }
      state = state.copyWith(clearCheckout: true);
      await _kv.delete(Keys.checkout);
    }
    try {
      await _api.logout();
    } on Object {
      // best effort; local sign-out must always succeed
    }
    _api.setSession(null);
    await _kv.delete('r007.session');
    state = state.copyWith(clearSession: true, locked: false);
  }

  void lock() {
    if (state.session != null && !state.locked) {
      state = state.copyWith(locked: true);
    }
  }

  /// Re-authenticates the SAME staff member (PIN or NFC) to unlock.
  Future<void> unlock({
    required String secret,
    required String credentialType,
  }) async {
    final staff = state.staff;
    if (staff == null) return;
    final session = await _api.loginStaff(
      identifier: credentialType == 'NFC_CARD' ? null : staff.staffNumber,
      secret: secret,
      credentialType: credentialType,
    );
    if (session.staff.id != staff.id) {
      throw const ApiProblem(
        status: 403,
        code: 'wrong_staff',
        title: 'This tablet is signed in to someone else',
      );
    }
    _api.setSession(session, onRefreshed: _onRefreshed);
    await _persistJson('r007.session', session.toJson());
    state = state.copyWith(session: session, locked: false);
  }

  // ----------------------------------------------------------- checkout

  Future<void> checkoutTablet({required Facility facility}) async {
    final device = state.device!;
    final c = await _api.checkoutDevice(
      deviceId: device.deviceId,
      staffId: state.staff!.id,
      facilityId: facility.id,
      idempotencyKey: newId(),
    );
    final merged = Checkout(
      facility: facility,
      shiftId: c.shiftId,
      staffId: state.staff!.id,
      checkedOutAt: c.checkedOutAt,
    );
    await _persistJson(Keys.checkout, {
      ...merged.toJson(),
      'staffId': state.staff?.id,
    });
    state = state.copyWith(checkout: merged, checkoutStaffId: state.staff?.id);
  }

  /// End of shift: return the tablet, then sign out.
  Future<void> checkinTablet() async {
    final device = state.device!;
    await _api.checkinDevice(
      deviceId: device.deviceId,
      idempotencyKey: newId(),
    );
    await _kv.delete(Keys.checkout);
    state = state.copyWith(clearCheckout: true);
    await logout();
  }
}
