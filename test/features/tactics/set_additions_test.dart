import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart'
    hide Saved;
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/my_games_fixture.dart';
import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';

void main() {
  late ScriptedDocumentStore store;
  late DocumentSaver saver;
  late DocumentSession session;
  late SettingsStore settings;
  late TacticsSet set;
  late SetAdditions additions;

  setUp(() {
    store = ScriptedDocumentStore()
      ..documents[tacticsRef] = Opened(
        tacticsSet,
        scriptedRevision(tacticsSet),
      );
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    settings = SettingsStore();
    set = TacticsSet(
      documents: store,
      session: session,
      settings: settings,
      ref: tacticsRef,
    );
    additions = SetAdditions(
      documents: store,
      session: session,
      saver: saver,
      set: set,
    );
  });

  tearDown(() {
    set.dispose();
    session.dispose();
    saver.dispose();
    settings.dispose();
  });

  String setText() => (store.documents[tacticsRef]! as Opened).text;

  const first = 'lichess_AbCd1234';
  const second = 'lichess_Other001';

  void expectSavedOnce(String id) {
    expect(analyzedIn(setText()), contains(id));
    expect(
      puzzlesOf(
        parseChapter(name: 'Default', text: setText()).lines,
      ).where((puzzle) => puzzle.gameId == id),
      hasLength(1),
    );
  }

  void expectBothSaved() {
    expect(analyzedIn(setText()), containsAll([first, second]));
    expect(
      puzzlesOf(
        parseChapter(name: 'Default', text: setText()).lines,
      ).where((puzzle) => puzzle.gameId == first),
      hasLength(1),
    );
    expect(additions.pendingWrites.unfinished(additions), isEmpty);
  }

  test('a later game saves the earlier unsaved one first', () async {
    store.saves.add(const IoFailure('set disk full'));
    expect(await additions.add(first, [minedScholarsMate()]), isA<NotAdded>());
    expect(await additions.add(second, const []), isA<Added>());
    expectBothSaved();
    expect(await additions.pendingWrites.settle(), isNull);
  });

  test('retrying a later game retries the earlier one first', () async {
    store.saves.addAll([
      const IoFailure('set disk full'),
      const IoFailure('set disk full'),
    ]);
    expect(await additions.add(first, [minedScholarsMate()]), isA<NotAdded>());
    expect(await additions.add(second, const []), isA<NotAdded>());
    expect(additions.pendingWrites.unfinished(additions), hasLength(2));
    expect(await additions.retry(second), isA<Added>());
    expectBothSaved();
  });

  group('on disk', () {
    test('a write that keeps losing its race is tried three times', () async {
      store.saves.addAll(List.filled(3, const Conflict(null)));
      final result = await additions.add(first, [minedScholarsMate()]);
      expect((result as NotAdded).reason, contains('kept changing'));
      expect(store.requestedSaves, hasLength(3));
    });

    test('a write that loses twice lands on the third try', () async {
      store.saves.addAll(List.filled(2, const Conflict(null)));
      final result = await additions.add(first, [minedScholarsMate()]);
      expect((result as Added).added, 1);
      expect(analyzedIn(setText()), contains(first));
    });

    test('a game already in the set adds nothing', () async {
      final result = await additions.add('lichess_abc', [minedScholarsMate()]);
      expect((result as Added).added, 0);
      expect(setText(), tacticsSet);
    });

    test('an unconfirmed checkpoint whose puzzle changed its answer is not '
        'confirmed', () async {
      store.saves.add(const IoFailure('set disk full'));
      expect(
        await additions.add(first, [minedScholarsMate()]),
        isA<NotAdded>(),
      );
      final written = store.requestedSaves.single.text;
      final at = written.lastIndexOf('Qxf7#');
      final changed = written.replaceRange(at, at + 5, 'Qxf6');
      store.documents[tacticsRef] = Opened(changed, scriptedRevision(changed));
      final result = await additions.retry(first);
      expect((result! as NotAdded).reason, contains('changed after'));
    });
  });

  group('in the open set', () {
    setUp(() async {
      await session.open(tacticsRef, game: 0);
      expect(set.isOpen, isTrue);
    });

    test('a game is added, counted and confirmed', () async {
      final result = await additions.add(first, [minedScholarsMate()]);
      expect((result as Added).added, 1);
      expect(analyzedIn(setText()), contains(first));
    });

    test('a game already in the set adds nothing', () async {
      final result = await additions.add('lichess_abc', const []);
      expect((result as Added).added, 0);
    });

    test('a retry after a failed save adds the puzzle once', () async {
      store.saves.add(const IoFailure('set disk full'));
      expect(
        await additions.add(first, [minedScholarsMate()]),
        isA<NotAdded>(),
      );
      expect(await additions.retry(first), isA<Added>());
      expectSavedOnce(first);
    });

    test(
      'a retry after the game was taken out of the draft adds the game again',
      () async {
        store.saves.add(const IoFailure('set disk full'));
        expect(
          await additions.add(first, [minedScholarsMate()]),
          isA<NotAdded>(),
        );
        // The user takes the mined game back out of the draft by hand.
        final original = parseChapter(name: 'Default', text: tacticsSet);
        expect(
          session.apply(
            (draft) => ChapterEdited(
              original,
              GamesArranged(
                order: [for (var i = 0; i < original.lines.length; i++) i],
                before: draft.lines.length,
              ),
            ),
          ),
          isNull,
        );
        expect(analyzedIn(session.chapter!.preamble), isNot(contains(first)));
        expect(await additions.retry(first), isA<Added>());
        expectSavedOnce(first);
      },
    );

    Future<Addition?> retryReading(String Function(String) persisted) async {
      store.saves.add(const IoFailure('set disk full'));
      expect(
        await additions.add(first, [minedScholarsMate()]),
        isA<NotAdded>(),
      );
      final draft = store.requestedSaves.single.text;
      final read = persisted(draft);
      store.documents[tacticsRef] = Opened(read, scriptedRevision(read));
      store.saves.add(
        Saved(
          Receipt(
            committed: scriptedRevision(read),
            before: tacticsSet,
            beforeRevision: scriptedRevision(tacticsSet),
          ),
        ),
      );
      return additions.retry(first);
    }

    String preambleLine(String text) =>
        text.split('\n').firstWhere((l) => l.startsWith('; ChessAutoPrep'));

    test('a save whose file lost the game\'s mark is not confirmed', () async {
      final result = await retryReading(
        (draft) =>
            draft.replaceFirst(preambleLine(draft), preambleLine(tacticsSet)),
      );
      expect(result, isA<NotAdded>());
    });

    test('a save whose file\'s mark cannot be read is not confirmed', () async {
      final result = await retryReading(
        (draft) => draft.replaceFirst(
          preambleLine(draft),
          '; ChessAutoPrep-Analyzed-v1: !!!',
        ),
      );
      expect(result, isA<NotAdded>());
    });
  });
}
