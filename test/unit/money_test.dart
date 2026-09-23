import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/util/money.dart';

void main() {
  test('parses decimal strings without floats', () {
    expect(Money.toMinor('1500.0000'), BigInt.from(150000));
    expect(Money.toMinor('0.1'), BigInt.from(10));
    expect(Money.toMinor('-2.50'), BigInt.from(-250));
    expect(Money.toMinor(null), BigInt.zero);
  });

  test('formats naira with grouping', () {
    expect(Money.format('1234567.5'), '₦1,234,567.50');
    expect(Money.format('0'), '₦0.00');
    expect(Money.format('-12.00'), '-₦12.00');
  });

  test('estimates: 0.1 + 0.2 is exact and quantities multiply', () {
    expect(Money.sum(['0.10', '0.20']), '0.30');
    expect(Money.times('3500.00', 3), '10500.00');
  });
}
