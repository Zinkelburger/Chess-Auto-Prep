import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/v2/app/app.dart';
import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SessionFixture fixture;
  late _Question question;

  /// What the way out did, in order: `engines` when it began stopping
  /// them, `engines stopped` when they were, `log` when it closed the log.
  late List<String> events;

  /// Held open until the test lets the engines finish quitting.
  late Completer<void> enginesQuit;

  setUp(() async {
    fixture = await openSession(blackChapter);
    question = _Question();
    events = [];
    enginesQuit = Completer<void>();
  });

  tearDown(() => fixture.dispose());

  AppExit exitWith({Duration wait = const Duration(seconds: 5)}) => AppExit(
    guard: ExitGuard(saver: fixture.saver, question: question, wait: wait),
    stopEngines: () async {
      events.add('engines');
      await enginesQuit.future;
      events.add('engines stopped');
    },
    closeLog: () async => events.add('log'),
  );

  void edit(String words) =>
      fixture.session.setComment(NodePath.of([0]), words);

  test('a save still going lands before the engines stop and the log '
      'closes', () async {
    fixture.store.hold = true;
    edit('last words');
    final leaving = exitWith().leave();
    await pumpEventQueue();
    expect(events, isEmpty, reason: 'the engines wait for the file');

    fixture.store.releaseAll();
    await pumpEventQueue();
    expect(events, ['engines']);
    expect(fixture.onDisk, contains('last words'));

    enginesQuit.complete();
    expect(await leaving, AppExitResponse.exit);
    expect(events, ['engines', 'engines stopped', 'log']);
    expect(question.asked, isEmpty, reason: 'the save landed in time');
  });

  test('a close asked for again while the engines shut down gets the same '
      'answer, and nothing is stopped or closed twice', () async {
    final exit = exitWith();
    final first = exit.leave();
    await pumpEventQueue();
    expect(events, ['engines']);

    final second = exit.leave();
    enginesQuit.complete();
    expect(await first, AppExitResponse.exit);
    expect(await second, AppExitResponse.exit);
    expect(events, ['engines', 'engines stopped', 'log']);
  });

  test('a save that does not land in time is asked about, and staying '
      'keeps the engines and the log', () async {
    fixture.store.hold = true;
    edit('last words');
    question.answer = DraftChoice.keepWaiting;
    final exit = exitWith(wait: const Duration(milliseconds: 20));

    expect(await exit.leave(), AppExitResponse.cancel);
    expect(events, isEmpty);
    expect(question.asked.single, contains('has not finished'));

    // The stay is forgotten, so the next click asks again.
    expect(await exit.leave(), AppExitResponse.cancel);
    expect(question.asked, hasLength(2));
    fixture.store.releaseAll();
  });

  test('closing anyway over a pending save shuts everything once', () async {
    fixture.store.hold = true;
    edit('last words');
    question.answer = DraftChoice.closeAnyway;
    final leaving = exitWith(wait: const Duration(milliseconds: 20)).leave();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(events, ['engines']);

    enginesQuit.complete();
    expect(await leaving, AppExitResponse.exit);
    expect(events, ['engines', 'engines stopped', 'log']);
    fixture.store.releaseAll();
  });

  test(
    'a shutdown failure releases input and permits a new close request',
    () async {
      var attempts = 0;
      final exit = AppExit(
        guard: ExitGuard(saver: fixture.saver, question: question),
        stopEngines: () async {
          if (++attempts == 1) throw StateError('Engine shutdown failed');
        },
        closeLog: () async => events.add('log'),
      );
      addTearDown(exit.closing.dispose);
      await expectLater(exit.leave(), throwsStateError);
      expect(exit.closing.value, isFalse);
      expect(events, isEmpty);
      expect(await exit.leave(), AppExitResponse.exit);
      expect(attempts, 2);
      expect(events, ['log']);
    },
  );
}

/// The question on the way out: it records what it was asked and answers
/// what the test set.
final class _Question implements DraftQuestion {
  DraftChoice? answer;
  final asked = <String>[];

  @override
  Future<DraftChoice?> put(DraftPrompt prompt) {
    asked.add(prompt.body);
    return Future<DraftChoice?>.value(answer);
  }

  @override
  void withdraw() {}
}
