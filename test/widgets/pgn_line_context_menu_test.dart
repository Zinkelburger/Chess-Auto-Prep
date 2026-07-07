/// Right-click context menu in the PGN movetext: "Copy line PGN" copies the
/// numbered line from the game start through the clicked move (and through a
/// variation path when a variation node is clicked).
library;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? clipboardText;

  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<PgnViewerWidgetController> pumpViewer(WidgetTester tester) async {
    final controller = PgnViewerWidgetController();
    await tester.pumpWidget(MaterialApp(
      // The app theme uses floating snackbars; showAppSnackBar sets a width,
      // which asserts under the default fixed behavior.
      theme: ThemeData(
        snackBarTheme:
            const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: Scaffold(
        body: PgnViewerWidget(
          pgnText: '1. e4 e5 2. Nf3 Nc6 3. Bb5',
          controller: controller,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('copy line from a mainline move', (tester) async {
    await pumpViewer(tester);

    await tester.tap(find.text('Nf3'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy line PGN'));
    await tester.pumpAndSettle();

    expect(clipboardText, '1. e4 e5 2. Nf3 *');
  });

  testWidgets('copy line from an ephemeral variation node', (tester) async {
    final controller = await pumpViewer(tester);

    // Branch off after 1. e4 e5 with a scratch line.
    controller.goToMainLineIndex(2);
    await tester.pumpAndSettle();
    controller.addEphemeralMove('Bc4');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bc4'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Delete variation'), findsOneWidget);
    await tester.tap(find.text('Copy line PGN'));
    await tester.pumpAndSettle();

    expect(clipboardText, '1. e4 e5 2. Bc4 *');
  });
}
