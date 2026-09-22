/// Operating mode of a tablet.
///
/// The mode comes from the device registration returned by the API; it is
/// NEVER hardcoded per build. All 18 tablets run the same APK.
enum DeviceMode {
  /// Not (yet) registered with the API. Shows a placeholder only.
  unregistered('UNREGISTERED', 'Unregistered'),

  /// Shared moving-attendant (waiter) tablet, checked out per shift.
  attendant('ATTENDANT', 'Attendant'),

  /// Outlet supervisor tablet (Restaurant, Indoor Club, Pool Bar,
  /// Bush Bar/Event Centre).
  supervisor('SUPERVISOR', 'Supervisor'),

  /// Sports entrance QR validation tablet.
  sportsEntrance('SPORTS_ENTRANCE', 'Sports Entrance'),

  /// Sports store release/return tablet.
  sportsStore('SPORTS_STORE', 'Sports Store');

  const DeviceMode(this.apiValue, this.label);

  /// Wire value used by the API.
  final String apiValue;

  /// Human readable label.
  final String label;

  /// Parses the API value. Unknown, empty or null values fall back to
  /// [DeviceMode.unregistered] so an unrecognised mode never unlocks a UI.
  static DeviceMode fromApi(String? value) {
    if (value == null) return DeviceMode.unregistered;
    final normalised = value.trim().toUpperCase().replaceAll('-', '_');
    for (final mode in DeviceMode.values) {
      if (mode.apiValue == normalised) return mode;
    }
    return DeviceMode.unregistered;
  }
}
