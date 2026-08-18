import 'package:chess_auto_prep/widgets/common/list_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('search box is compact chrome, not a padded Material field', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.all(8),
            child: ListSearchField(hintText: 'Search games', onChanged: _noop),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(TextField));
    expect(size.height, lessThan(40));
    expect(size.height, greaterThanOrEqualTo(28));
    expect(find.byIcon(Icons.search), findsOneWidget);
  });
}

void _noop(String _) {}
