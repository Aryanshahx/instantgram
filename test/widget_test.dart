import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/app.dart';

void main() {
  testWidgets('App launches and shows the app name', (tester) async {
    await tester.pumpWidget(const InstantGramApp());
    expect(find.text('InstantGram'), findsOneWidget);
  });
}
