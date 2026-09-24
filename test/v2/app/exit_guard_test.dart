import 'dart:async';

import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show IoFailure, SaveRefused;
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  const moment = Duration(milliseconds: 20);
  late SessionFixture fixture;

  setUp(() async {
    fixture = await openSession(blackChapter);
  });

  tearDown(() => fixture.dispose());

  /// Comments the first move, which is one edit of the file.
  void edit(String words) =>
      fixture.session.setComment(NodePath.of([0]), words);

  /// A disk that stays full: the edit's save fails, and so does every try a
  /// flush of the guard's makes after it.
  void diskFull() => fixture.store.saves.addAll(
    List.filled(4, const IoFailure('No space left on device')),
  );

  ExitGuard guardWith(_Question question) =>
      ExitGuard(saver: fixture.saver, question: question, wait: moment);

  test('the window closes as soon as the file has the words', () async {
    final question = _Question(answer: DraftChoice.closeAnyway);
    expect(await guardWith(question).mayClose(), isTrue);
    expect(question.asked, isEmpty, reason: 'there was nothing to ask about');
  });

  test('a save that is still going is put to the user', () async {
    fixture.store.hold = true;
    edit('one');
    final question = _Question(answer: DraftChoice.closeAnyway);
    expect(await guardWith(question).mayClose(), isTrue);
    expect(question.asked.single, contains('has not finished'));
    fixture.store.releaseAll();
  });

  test('a question about leaving does not answer one about closing', () async {
    diskFull();
    edit('one');
    await pumpEventQueue();
    final question = _Question(answer: DraftChoice.closeAnyway, waits: true);
    final guard = guardWith(question);

    final leaving = guard.mayLeaveDocument();
    await question.first;
    final closing = guard.mayClose();
    question.answerNow(DraftChoice.closeAnyway);
    expect(await leaving, isA<Go>());
    await question.first;
    question.answerNow(DraftChoice.keepWaiting);
    expect(await closing, isFalse, reason: 'the close asked its own question');
    expect(question.asked, hasLength(2));
  });

  test(
    'staying on a document does not refuse a close without asking',
    () async {
      diskFull();
      edit('one');
      await pumpEventQueue();
      final question = _Question(answer: DraftChoice.keepWaiting, waits: true);
      final guard = guardWith(question);

      final leaving = guard.mayLeaveDocument();
      await question.first;
      final closing = guard.mayClose();
      question.answerNow(DraftChoice.keepWaiting);
      expect(await leaving, isA<Stay>());
      await question.first;
      question.answerNow(DraftChoice.closeAnyway);
      expect(await closing, isTrue, reason: 'the close asked its own question');
      expect(question.asked, hasLength(2));
    },
  );

  test('a conflicted document is not told that waiting will help', () async {
    fixture.externalEdit('// Color: Black\n\n1. d4 *\n');
    edit('one');
    await pumpEventQueue();
    final question = _Question(answer: DraftChoice.closeAnyway);
    expect(await guardWith(question).mayClose(), isTrue);
    expect(
      question.asked.single,
      contains('Nothing more will be written until you reload or save a copy'),
    );
    expect(question.asked.single, isNot(contains('stay until it is saved')));
  });

  test('a save that is only slow says waiting will help', () async {
    fixture.store.hold = true;
    edit('one');
    final question = _Question(answer: DraftChoice.closeAnyway);
    expect(await guardWith(question).mayClose(), isTrue);
    expect(question.asked.single, contains('You can stay until it is saved'));
    fixture.store.releaseAll();
  });

  test('a save that failed is not taken for a save', () async {
    diskFull();
    edit('one');
    await pumpEventQueue();
    final question = _Question();
    expect(
      await guardWith(question).mayClose(),
      isFalse,
      reason: 'the user answered nothing, so the window stays',
    );
    expect(question.asked.single, contains('No space left on device'));
  });

  test('a save the store stopped says what it was, not a stopwatch', () async {
    fixture.store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    edit('one');
    await pumpEventQueue();
    final question = _Question(answer: DraftChoice.closeAnyway);
    expect(await guardWith(question).mayClose(), isTrue);
    expect(question.asked.single, contains('was stopped because'));
    expect(question.asked.single, contains('still on screen'));
    expect(question.asked.single, contains('Closing now loses them'));
    expect(
      question.asked.single,
      contains('waiting will not help'),
      reason: 'a frozen document is not going to write itself',
    );
    expect(question.asked.single, isNot(contains('has not finished')));
  });

  test('words typed over a conflict are asked about too', () async {
    fixture.externalEdit('// Color: Black\n\n1. d4 *\n');
    edit('one');
    await pumpEventQueue();
    edit('two'); // never reaches the saver: a conflicted file takes nothing
    final question = _Question(answer: DraftChoice.closeAnyway);
    expect(await guardWith(question).mayClose(), isTrue);
    expect(question.asked.single, contains('was changed somewhere else'));
  });

  test('two clicks on the close button ask once', () async {
    fixture.store.hold = true;
    edit('one');
    final question = _Question(answer: DraftChoice.closeAnyway);
    final guard = guardWith(question);
    final first = guard.mayClose();
    final second = guard.mayClose();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(question.asked, hasLength(1));
    fixture.store.releaseAll();
  });

  test(
    'two close requests share the background-write failure decision',
    () async {
      final question = _Question(answer: DraftChoice.keepWaiting);
      var drains = 0;
      final guard = ExitGuard(
        saver: fixture.saver,
        question: question,
        settleFeatures: () async {
          drains++;
          return 'A rating was not saved';
        },
      );
      final first = guard.mayClose();
      final second = guard.mayClose();
      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(question.asked, hasLength(1));
      expect(drains, 1);
    },
  );

  test(
    'closing cancels a navigation question before its input is covered',
    () async {
      diskFull();
      edit('one');
      await pumpEventQueue();
      final question = _Question(waits: true);
      final guard = guardWith(question);
      final navigating = guard.mayLeaveDocument();
      await question.first;
      guard.cancelNavigation();
      expect(await navigating, isA<Stay>());
      expect(question.withdrawn, 1);
      final closing = guard.mayClose();
      await question.first;
      question.answerNow(DraftChoice.keepWaiting);
      expect(await closing, isFalse);
      expect(question.asked, hasLength(2));
    },
  );

  test(
    'a pending copy dialog cannot hold closing behind its barrier',
    () async {
      diskFull();
      edit('one');
      await pumpEventQueue();
      final question = _Question(waits: true);
      final copying = Completer<String?>();
      final guard = ExitGuard(
        saver: fixture.saver,
        question: question,
        saveCopy: () => copying.future,
        wait: moment,
      );
      final navigating = guard.mayLeaveDocument();
      await question.first;
      question.answerNow(DraftChoice.saveACopy);
      await pumpEventQueue();
      guard.cancelNavigation();
      expect(await navigating, isA<Stay>());
      final closing = guard.mayClose();
      await question.first;
      question.answerNow(DraftChoice.keepWaiting);
      expect(await closing, isFalse);
      copying.complete('Accepted copy.pgn');
      await pumpEventQueue();
    },
  );

  test('the question comes down when the save lands', () async {
    fixture.store.hold = true;
    edit('one');
    final question = _Question(waits: true);
    final closing = guardWith(question).mayClose();
    await question.first;
    expect(question.asked, hasLength(1));
    fixture.store.releaseAll();
    expect(await closing, isTrue);
    expect(question.withdrawn, 1);
  });

  test('a copy saved on the way out is named in the answer, for every '
      'caller asking at once', () async {
    diskFull();
    edit('one');
    await pumpEventQueue();
    final question = _Question(answer: DraftChoice.saveACopy);
    final guard = ExitGuard(
      saver: fixture.saver,
      question: question,
      saveCopy: () async => 'Main copy.pgn',
      wait: moment,
    );
    final first = guard.mayLeaveDocument();
    final second = guard.mayLeaveDocument();
    expect((await first as Go).copy, 'Main copy.pgn');
    expect((await second as Go).copy, 'Main copy.pgn');
    expect(question.asked, hasLength(1));
  });

  test('a copy that was not written keeps the user where they are', () async {
    diskFull();
    edit('one');
    await pumpEventQueue();
    final guard = ExitGuard(
      saver: fixture.saver,
      question: _Question(answer: DraftChoice.saveACopy),
      saveCopy: () async => null,
      wait: moment,
    );
    expect(await guard.mayLeaveDocument(), isA<Stay>());
    expect(await guard.mayClose(), isFalse);
  });

  testWidgets('the dialog says what is known and offers both ways', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: darkTheme(),
        home: const Scaffold(body: Text('workspace')),
      ),
    );
    final dialog = DraftDialog(navigator);
    final answer = dialog.put((
      body: 'The save of Main.pgn has not finished.',
      leave: 'Close and lose the words',
      offerCopy: true,
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('has not finished'), findsOneWidget);
    expect(find.text('Stay here'), findsOneWidget);
    expect(find.text('Save a copy…'), findsOneWidget);

    await tester.tap(find.text('Close and lose the words'));
    await tester.pumpAndSettle();
    expect(await answer, DraftChoice.closeAnyway);
  });

  testWidgets('a withdrawn question takes its dialog away', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: darkTheme(),
        home: const Scaffold(body: Text('workspace')),
      ),
    );
    final dialog = DraftDialog(navigator);
    final answer = dialog.put((
      body: 'The save of Main.pgn has not finished.',
      leave: 'Close and lose the words',
      offerCopy: false,
    ));
    await tester.pumpAndSettle();
    dialog.withdraw();
    await tester.pumpAndSettle();
    expect(find.textContaining('has not finished'), findsNothing);
    expect(await answer, isNull);
  });
}

/// The question as a test puts it: it records what it was asked and answers
/// what the test said, either at once or only when it is withdrawn.
final class _Question implements DraftQuestion {
  _Question({this.answer, this.waits = false});

  /// What the user chooses; null is a question they never answered.
  final DraftChoice? answer;

  /// Whether the question stays up until something takes it down.
  final bool waits;

  final asked = <String>[];
  var withdrawn = 0;
  Completer<DraftChoice?>? _open;
  Completer<void> _first = Completer<void>();

  /// Completes when the question has been put, so a test need not guess how
  /// long the guard waits before asking. Asking again arms it again.
  Future<void> get first => _first.future;

  /// Answers the question that is up now.
  void answerNow(DraftChoice choice) {
    final open = _open;
    if (open != null && !open.isCompleted) open.complete(choice);
  }

  @override
  Future<DraftChoice?> put(DraftPrompt prompt) {
    asked.add(prompt.body);
    if (!_first.isCompleted) _first.complete();
    if (!waits) return Future<DraftChoice?>.value(answer);
    _first = Completer<void>();
    return (_open = Completer<DraftChoice?>()).future;
  }

  @override
  void withdraw() {
    withdrawn++;
    final open = _open;
    if (open != null && !open.isCompleted) open.complete(null);
  }
}
