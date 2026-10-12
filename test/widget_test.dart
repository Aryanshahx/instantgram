import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/app.dart';
import 'package:instantgram/features/auth/presentation/login_screen.dart';

void main() {
  testWidgets('Login screen renders', (tester) async {
    await tester.pumpWidget(const InstantGramApp(home: LoginScreen()));
    await tester.pump();

    expect(find.text('InstantGram'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('Login validates empty fields', (tester) async {
    await tester.pumpWidget(const InstantGramApp(home: LoginScreen()));
    await tester.tap(find.text('Log in'));
    await tester.pump();

    expect(find.text('Enter your email or username'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });
}
