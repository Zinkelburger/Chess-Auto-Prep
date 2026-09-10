import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'success messages stay quiet and do not dismiss an existing error',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                context = ctx;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      showAppSnackBar(context, 'Saved', actionLabel: 'Open', onAction: () {});
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      showAppSnackBar(context, 'Save failed', isError: true);
      await tester.pumpAndSettle();
      expect(find.text('Save failed'), findsOneWidget);
      showAppSnackBar(context, 'Copied');
      await tester.pumpAndSettle();
      expect(find.text('Save failed'), findsOneWidget);
      expect(find.text('Copied'), findsNothing);
    },
  );

  testWidgets('necessary guidance and its action remain available', (
    tester,
  ) async {
    late BuildContext context;
    var acted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    showAppSnackBar(
      context,
      'Choose an account first',
      requiresAttention: true,
      actionLabel: 'Accounts',
      onAction: () => acted = true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    expect(acted, isTrue);
  });
}
