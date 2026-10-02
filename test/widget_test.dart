import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/services/auth_service.dart';

void main() {
  test('username regex accepts valid and rejects invalid names', () {
    expect(AuthService.usernameRegex.hasMatch('aryan.shah_1'), isTrue);
    expect(AuthService.usernameRegex.hasMatch('ab'), isFalse);
    expect(AuthService.usernameRegex.hasMatch('Has Space'), isFalse);
  });
}
