import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/main.dart';

void main() {
  testWidgets('Game screen renders hex grid', (WidgetTester tester) async {
    await tester.pumpWidget(const RuneDuelApp());
    expect(find.text('Rune Duel'), findsOneWidget);
    expect(find.text('Step'), findsOneWidget);
    expect(find.text('Fire'), findsOneWidget);
  });
}
