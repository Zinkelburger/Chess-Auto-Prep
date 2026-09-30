import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
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
      older: () async => {},
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
}
