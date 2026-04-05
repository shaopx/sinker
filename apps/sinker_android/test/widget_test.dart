import 'package:flutter_test/flutter_test.dart';

import 'package:sinker_android/main.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SinkerApp());

    expect(find.text('Sinker'), findsOneWidget);
    expect(find.text('Start Receiving'), findsOneWidget);
  });
}
