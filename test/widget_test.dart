import 'package:flutter_test/flutter_test.dart';
import 'package:aqua_tilt/main.dart';

void main() {
  testWidgets('AquaTilt smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AquaTiltApp());
    expect(find.byType(AquaTiltApp), findsOneWidget);
  });
}
