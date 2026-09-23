/// Display-only helpers for server-provided decimal-string money.
///
/// The client NEVER computes authoritative prices, tax or totals; the server
/// returns them. These helpers only format strings for display and produce a
/// clearly labelled *estimate* for offline-pending carts. No floats are used.
abstract final class Money {
  /// Parses "1500.0000" / "1,500" style strings into hundredths (minor units).
  static BigInt toMinor(String? value) {
    if (value == null || value.trim().isEmpty) return BigInt.zero;
    var v = value.trim().replaceAll(',', '');
    var negative = false;
    if (v.startsWith('-')) {
      negative = true;
      v = v.substring(1);
    }
    final parts = v.split('.');
    final whole =
        BigInt.tryParse(parts[0].isEmpty ? '0' : parts[0]) ?? BigInt.zero;
    var frac = parts.length > 1 ? parts[1] : '';
    frac = ('${frac}00').substring(0, 2);
    final minor =
        whole * BigInt.from(100) + (BigInt.tryParse(frac) ?? BigInt.zero);
    return negative ? -minor : minor;
  }

  static String fromMinor(BigInt minor) {
    final negative = minor.isNegative;
    final abs = minor.abs();
    final whole = abs ~/ BigInt.from(100);
    final frac = (abs % BigInt.from(100)).toString().padLeft(2, '0');
    return '${negative ? '-' : ''}$whole.$frac';
  }

  /// Multiply a decimal string by an integer quantity (estimate only).
  static String times(String? unit, int qty) =>
      fromMinor(toMinor(unit) * BigInt.from(qty));

  static String sum(Iterable<String?> values) =>
      fromMinor(values.fold<BigInt>(BigInt.zero, (a, b) => a + toMinor(b)));

  /// "₦1,500.00" style display string.
  static String format(String? value, {String currency = 'NGN'}) {
    final minor = toMinor(value);
    final neg = minor.isNegative;
    final abs = minor.abs();
    final whole = (abs ~/ BigInt.from(100)).toString();
    final frac = (abs % BigInt.from(100)).toString().padLeft(2, '0');
    final buf = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
      buf.write(whole[i]);
    }
    final symbol = currency == 'NGN' ? '₦' : '$currency ';
    return '${neg ? '-' : ''}$symbol$buf.$frac';
  }
}
