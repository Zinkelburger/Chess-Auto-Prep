import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_loading_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps the workspace mounted and blocks edits during a load', (
    tester,
  ) async {
    var taps = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    Widget host(bool loading) => MaterialApp(
      home: RepertoireLoadingFrame(
        isLoading: loading,
        child: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: focus),
              TextButton(onPressed: () => taps++, child: const Text('Move')),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(false));
    await tester.enterText(find.byType(TextField), 'Comment draft');
    final editorState = tester.state(find.byType(TextField));
    final bounds = tester.getRect(find.byType(Scaffold));
    await tester.tap(find.text('Move'));
    expect(taps, 1);

    await tester.pumpWidget(host(true));
    await tester.pump();
    expect(tester.state(find.byType(TextField)), same(editorState));
    expect(tester.getRect(find.byType(Scaffold)), bounds);
    expect(find.text('Comment draft'), findsOneWidget);
    expect(focus.hasFocus, isFalse);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Move'), warnIfMissed: false);
    expect(taps, 1);

    await tester.pumpWidget(host(false));
    expect(tester.state(find.byType(TextField)), same(editorState));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Move'));
    expect(taps, 2);
  });
}
