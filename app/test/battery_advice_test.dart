import 'package:argus_wallet/services/battery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('battery advice says what will happen and where the fix is', () {
    expect(batteryAdvice(unrestricted: true, manufacturer: 'Google'), contains('runs on time'));
    expect(batteryAdvice(unrestricted: false, manufacturer: 'Google'), contains('Unrestricted'));
    expect(batteryAdvice(unrestricted: null, manufacturer: ''), startsWith('Could not read'));
    final samsung = batteryAdvice(unrestricted: false, manufacturer: 'samsung');
    expect(samsung, contains('dontkillmyapp.com'));
    expect(batteryAdvice(unrestricted: true, manufacturer: 'Fairphone'), isNot(contains('dontkillmyapp')));
  });
}
