import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/app/app.dart';
import 'package:chess_auto_prep/app/exit_guard.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/net/lichess_login.dart';
import 'package:chess_auto_prep/storage/lichess_token.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';
import '../support/scripted_login.dart';
import '../support/session_fixture.dart';
import '../support/window_fixture.dart';

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

  test('exit honors logout while token revocation is pending', () {
    fakeAsync((time) {
      LichessAccount? saved = someone(personal: true);
      final removal = Completer<void>();
      final revoke = Completer<http.Response>();
      final methods = <String>[];
      final client = MockClient((request) {
        methods.add(request.method);
        return revoke.future;
      });
      final window = WindowFixture(
        login: LichessLoginApi(client, openBrowser: (_) async => false),
        readAccount: () async => saved,
        writeAccount: (account) async {
          await removal.future;
          saved = account;
          return true;
        },
      );
      final exit = AppExit(
        guard: window.parts.exit,
        prepare: window.parts.prepareToClose,
        onCancelled: window.parts.resumeAfterClose,
        stopEngines: window.parts.env.stopEngines,
        closeLog: () async {},
      );
      try {
        unawaited(window.parts.account.load());
        time.flushMicrotasks();
        unawaited(window.parts.account.logOut());
        AppExitResponse? response;
        unawaited(exit.leave().then((value) => response = value));
        time.elapse(Duration.zero);
        expect(response, isNull);

        removal.complete();
        time.elapse(Duration.zero);
        expect(response, AppExitResponse.exit);
        expect(saved, isNull);
        expect(methods, ['DELETE']);
        revoke.complete(http.Response('', 204));
        time.elapse(Duration.zero);
        expect(saved, isNull);
      } finally {
        window.dispose();
        exit.closing.dispose();
      }
    });
  });

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

  test('what waits for the close to go ahead runs before the engines stop, '
      'never on a close the user backs out of, and cannot keep the window '
      'open', () async {
    AppExit exit({
      required Future<void> Function() beforeExit,
      Duration? wait,
    }) => AppExit(
      guard: ExitGuard(
        saver: fixture.saver,
        question: question,
        wait: wait ?? const Duration(seconds: 5),
      ),
      prepare: () => events.add('prepare'),
      onCancelled: () => events.add('cancelled'),
      beforeExit: beforeExit,
      stopEngines: () async => events.add('engines'),
      closeLog: () async => events.add('log'),
    );

    fixture.store.hold = true;
    edit('last words');
    question.answer = DraftChoice.keepWaiting;
    final stayed = exit(
      beforeExit: () async => events.add('before exit'),
      wait: const Duration(milliseconds: 20),
    );
    expect(await stayed.leave(), AppExitResponse.cancel);
    expect(events, ['prepare', 'cancelled']);
    fixture.store.releaseAll();
    await fixture.saver.flush();

    events.clear();
    final left = exit(
      beforeExit: () async {
        events.add('before exit');
        throw StateError('the search would not stop');
      },
    );
    expect(await left.leave(), AppExitResponse.exit);
    expect(events, ['prepare', 'before exit', 'engines', 'log']);
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

  test('a log that fails to close does not keep the window open', () async {
    final exit = AppExit(
      guard: ExitGuard(saver: fixture.saver, question: question),
      stopEngines: () async {},
      closeLog: () async => throw const FileSystemException('disk full'),
    );
    addTearDown(exit.closing.dispose);
    expect(await exit.leave(), AppExitResponse.exit);
  });

  test('a log that never closes does not keep the window open', () async {
    final exit = AppExit(
      guard: ExitGuard(saver: fixture.saver, question: question),
      stopEngines: () async {},
      closeLog: () => Completer<void>().future,
    );
    addTearDown(exit.closing.dispose);
    expect(await exit.leave(), AppExitResponse.exit);
  });
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
