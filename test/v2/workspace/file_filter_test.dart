import 'package:chess_auto_prep/v2/chess/game_filter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/file_filter.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

const byCarlsen = GameFilter(rules: [HeaderRule(value: 'Carlsen')]);

void main() {
  late ViewerFixture fixture;

  tearDown(() => fixture.dispose());

  List<int> kept(FileFilter filter) => [
    for (var game = 0; game < filter.total; game++)
      if (filter.keeps(game)) game,
  ];

  test('with no rules every game passes', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    final filter = fixture.filter;
    expect(filter.narrowing, isFalse);
    expect(filter.total, 3);
    expect(filter.kept, 3);
    expect(kept(filter), [0, 1, 2]);
  });

  test('rules typed apply once typing rests; added or removed, at once', () {
    fakeAsync((time) {
      viewerOver(threeGameFile).then((made) => fixture = made);
      time.flushMicrotasks();
      fixture.open();
      time.flushMicrotasks();
      final filter = FileFilter(fixture.session);
      addTearDown(filter.dispose);
      filter.edit(byCarlsen);
      expect(filter.filter, byCarlsen);
      expect(filter.narrowing, isFalse, reason: 'still typing');
      time.elapse(const Duration(milliseconds: 299));
      expect(filter.narrowing, isFalse);
      time.elapse(const Duration(milliseconds: 1));
      expect(kept(filter), [0]);
      expect(filter.kept, 1);
      filter.apply(GameFilter.none);
      expect(filter.narrowing, isFalse);
      expect(filter.kept, 3);
    });
  });

  test('another file clears the rules and drops a change still waiting', () {
    fakeAsync((time) {
      viewerOver(threeGameFile).then((made) => fixture = made);
      time.flushMicrotasks();
      fixture.open();
      time.flushMicrotasks();
      final other = collectionRef('other');
      fixture.store.documents[other] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      final filter = FileFilter(fixture.session);
      addTearDown(filter.dispose);
      filter.apply(byCarlsen);
      filter.edit(const GameFilter(rules: [HeaderRule(value: 'Ding')]));
      fixture.session.open(other, game: 0);
      time.flushMicrotasks();
      expect(filter.filter, GameFilter.none);
      time.elapse(const Duration(seconds: 1));
      expect(filter.applied, GameFilter.none, reason: 'the typing was lost');
      expect(filter.kept, 3);
    });
  });

  test('closing the file clears the rules', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    fixture.filter.apply(byCarlsen);
    expect(fixture.filter.kept, 1);
    fixture.session.closed();
    expect(fixture.filter.applied, GameFilter.none);
    expect(fixture.filter.narrowing, isFalse);
  });

  test('a paste onto the board clears the rules', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    fixture.filter.apply(byCarlsen);
    await fixture.session.showAnalysisBoard(analysisBoard(side: Side.white));
    expect(fixture.filter.applied, GameFilter.none);
    expect(fixture.filter.file, isNull);
  });

  test('switching games keeps the rules; the file edited is filtered '
      'again', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    final filter = fixture.filter..apply(byCarlsen);
    fixture.session.showGame(2);
    expect(filter.applied, byCarlsen);
    fixture.session.setComment(NodePath.of([0]), 'A note');
    await pumpEventQueue();
    expect(fixture.onDisk, contains('{A note}'));
    expect(filter.applied, byCarlsen);
    expect(kept(filter), [0]);
  });

  test('a value box is offered the values the file has, each once', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    final filter = fixture.filter;
    expect(filter.valuesOf('Event'), ['Club night', 'Tata Steel']);
    expect(filter.valuesOf('Player'), [
      'Carlsen, Magnus',
      'Ding, Liren',
      'Giri, Anish',
      'Nakamura, Hikaru',
    ]);
    expect(filter.fields, containsAll(['Event', 'White', 'Site', 'Result']));
  });
}
