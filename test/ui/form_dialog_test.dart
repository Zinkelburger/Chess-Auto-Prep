import 'dart:async';

import 'package:chess_auto_prep/ui/confirm_dialog.dart';
import 'package:chess_auto_prep/ui/form_dialog.dart';
import 'package:chess_auto_prep/ui/number_field.dart';
import 'package:chess_auto_prep/ui/options_dialog.dart';
import 'package:chess_auto_prep/ui/problem_line.dart';
import 'package:chess_auto_prep/ui/progress_line.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens [dialog] from a button and answers what it popped with, read
/// after the test is done with it.
Future<List<Object?>> _open(
  WidgetTester tester,
  Future<Object?> Function(BuildContext context) dialog, {
  bool settles = true,
}) async {
  final answers = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answers.add(await dialog(context)),
          child: const Text('Ask'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Ask'));
  // A busy dialog's progress line runs until the work ends.
  settles
      ? await tester.pumpAndSettle()
      : await tester.pump(const Duration(seconds: 1));
  return answers;
}

/// A form with a one-line field, a field of several lines and a number,
/// which answers the three when confirmed.
class _Form extends StatefulWidget {
  const _Form({this.busy = false});
  final bool busy;
  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  final _name = TextEditingController();
  final _notes = TextEditingController();
  int _count = 1;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: 'Form',
    confirm: 'Save',
    busy: widget.busy,
    onConfirm: _name.text.isEmpty
        ? null
        : () => Navigator.pop(context, '${_name.text}|${_notes.text}|$_count'),
    body: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('name'),
          controller: _name,
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const ValueKey('notes'),
          controller: _notes,
          minLines: 2,
          maxLines: 4,
        ),
        NumberField(
          label: 'Count',
          value: _count,
          min: 1,
          max: 9,
          onChanged: (value) => setState(() => _count = value),
        ),
      ],
    ),
  );
}

Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Enter in a one-line field confirms once the button is on', (
    tester,
  ) async {
    final answers = await _open(
      tester,
      (context) =>
          showDialog<String>(context: context, builder: (_) => const _Form()),
    );
    await _enter(tester);
    expect(find.text('Form'), findsOneWidget, reason: 'nothing typed yet');
    await tester.enterText(find.byKey(const ValueKey('name')), 'Alex');
    await tester.pump();
    await _enter(tester);
    expect(find.text('Form'), findsNothing);
    expect(answers, ['Alex||1']);
  });

  testWidgets('a field of several lines keeps Enter for its new line', (
    tester,
  ) async {
    await _open(
      tester,
      (context) =>
          showDialog<String>(context: context, builder: (_) => const _Form()),
    );
    await tester.enterText(find.byKey(const ValueKey('name')), 'Alex');
    await tester.tap(find.byKey(const ValueKey('notes')));
    await tester.pump();
    await _enter(tester);
    expect(find.text('Form'), findsOneWidget);
  });

  testWidgets('Enter in a number box takes the number before confirming', (
    tester,
  ) async {
    final answers = await _open(
      tester,
      (context) =>
          showDialog<String>(context: context, builder: (_) => const _Form()),
    );
    await tester.enterText(find.byKey(const ValueKey('name')), 'Alex');
    final box = find.descendant(
      of: find.byType(NumberField),
      matching: find.byType(TextField),
    );
    await tester.enterText(box, '7');
    await _enter(tester);
    expect(answers, ['Alex||7']);
  });

  testWidgets('Escape cancels an idle form', (tester) async {
    final answers = await _open(
      tester,
      (context) =>
          showDialog<String>(context: context, builder: (_) => const _Form()),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Form'), findsNothing);
    expect(answers, [null]);
  });

  testWidgets('a busy form stays up on Escape with its buttons off', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showDialog<String>(
        context: context,
        builder: (_) => const _Form(busy: true),
      ),
      settles: false,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Form'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a destructive confirm starts on Cancel, so Enter keeps all', (
    tester,
  ) async {
    final answers = await _open(
      tester,
      (context) => confirmAction(
        context,
        title: 'Delete chapter “Najdorf”?',
        message: 'Its lines go to Deleted chapters.',
        confirm: 'Delete',
      ),
    );
    await _enter(tester);
    expect(find.text('Delete chapter “Najdorf”?'), findsNothing);
    expect(answers, [false]);
  });

  testWidgets('a confirm that only adds starts on its button', (tester) async {
    final answers = await _open(
      tester,
      (context) => confirmAction(
        context,
        title: 'Add this line to “Main”?',
        message: 'No chapter plays this line yet; training needs one.',
        confirm: 'Add and train',
        destructive: false,
      ),
    );
    await _enter(tester);
    expect(answers, [true]);
  });

  testWidgets('an options dialog answers the row clicked, null on Cancel', (
    tester,
  ) async {
    final answers = await _open(
      tester,
      (context) => showOptionsDialog(
        context,
        title: 'Promote to',
        options: const [(1, 'Queen'), (2, 'Knight')],
      ),
    );
    await tester.tap(find.text('Knight'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answers, [2, null]);
  });
  testWidgets('a confirm put away with Escape is a no', (tester) async {
    final answers = await _open(
      tester,
      (context) => confirmAction(
        context,
        title: 'Delete chapter “Najdorf”?',
        message: 'Its lines go to Deleted chapters.',
        confirm: 'Delete',
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  group('a form', () {
    late List<String> confirmed;

    Future<void> plain(
      WidgetTester tester, {
      bool canFail = false,
      String? problem,
      bool working = false,
      double? width = dialogNarrow,
      IconData? icon,
      Widget body = const SizedBox(key: ValueKey('body'), height: 10),
    }) async {
      confirmed = [];
      await tester.pumpWidget(
        MaterialApp(
          // A new window each time, not the last one with its dialog up.
          key: UniqueKey(),
          theme: darkTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => FormDialog(
                  title: 'Plain',
                  body: body,
                  confirm: 'Run',
                  confirmIcon: icon,
                  width: width,
                  canFail: canFail,
                  problem: problem,
                  working: working,
                  onConfirm: () => confirmed.add('run'),
                ),
              ),
              child: const Text('Ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      // The dialog takes the focus a turn after it is built.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    testWidgets('with no field, Enter and the keypad Enter confirm; another '
        'key does not', (tester) async {
      await plain(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(confirmed, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      expect(confirmed, ['run', 'run']);
    });

    testWidgets('Enter with a modifier held does not confirm', (tester) async {
      await plain(tester);
      for (final modifier in [
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
      }
      expect(confirmed, isEmpty);
    });

    testWidgets('a field asking for the focus keeps it, and Tab never stops '
        'on the dialog itself', (tester) async {
      await plain(
        tester,
        body: const TextField(key: ValueKey('field'), autofocus: true),
      );
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot('Form dialog'),
        );
      }
    });

    testWidgets('holds a line for a problem only when it can have one', (
      tester,
    ) async {
      await plain(tester);
      expect(find.byType(ProblemLine), findsNothing);
      await plain(tester, canFail: true);
      expect(find.byType(ProblemLine), findsOneWidget);
      await plain(tester, problem: 'Disk full');
      expect(find.text('Disk full'), findsOneWidget);
    });

    testWidgets('is not busy unless said, and its line runs while it reads', (
      tester,
    ) async {
      await plain(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Run'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester.widget<ProgressLine>(find.byType(ProgressLine)).active,
        isFalse,
      );
      await plain(tester, working: true);
      expect(
        tester.widget<ProgressLine>(find.byType(ProgressLine)).active,
        isTrue,
      );
    });

    testWidgets('is as wide as it is told, and its verb carries its symbol', (
      tester,
    ) async {
      await plain(tester, width: dialogMedium, icon: Icons.play_arrow);
      expect(
        tester.getSize(find.byKey(const ValueKey('body'))).width,
        dialogMedium,
      );
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });

  for (final then in _AfterEnter.values) {
    testWidgets(
      'Enter in a field that ${then.name == 'working' ? 'set the '
                'form working' : 'put another dialog up'} does not confirm as well',
      (tester) async {
        final answers = await _open(
          tester,
          (context) =>
              showDialog<String>(context: context, builder: (_) => _Busy(then)),
        );
        await tester.enterText(find.byType(TextField), 'Alex');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump();
        expect(answers, isEmpty);
        if (then == _AfterEnter.asks) {
          expect(find.text('Sure?'), findsOneWidget);
        }
      },
    );
  }

  testWidgets('a form not said to fail holds no line for a problem', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showDialog<String>(
        context: context,
        builder: (_) => const _Busy(_AfterEnter.working),
      ),
    );
    expect(find.text('Busy'), findsOneWidget);
    expect(find.byType(ProblemLine), findsNothing);
  });
}

enum _AfterEnter { working, asks }

/// A form whose field, on Enter, sets it working or asks something else.
class _Busy extends StatefulWidget {
  const _Busy(this.then);
  final _AfterEnter then;
  @override
  State<_Busy> createState() => _BusyState();
}

class _BusyState extends State<_Busy> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) => FormDialog(
    title: 'Busy',
    confirm: 'Save',
    busy: _busy,
    onConfirm: () => Navigator.pop(context, 'saved'),
    body: TextField(
      autofocus: true,
      onSubmitted: (_) => switch (widget.then) {
        _AfterEnter.working => setState(() => _busy = true),
        _AfterEnter.asks => unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(content: Text('Sure?')),
          ),
        ),
      },
    ),
  );
}
