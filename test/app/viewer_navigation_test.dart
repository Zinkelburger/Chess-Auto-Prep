import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  testWidgets('named handoff overrides remembered game and header slice', (
    tester,
  ) async {
    final parsed = await readChapter(name: '', text: threeGameFile);
    final stored = _StoredPlace(
      ReadingPlace(
        game: 1,
        key: readingGameKey(parsed.lines[1]),
        path: NodePath.of([0]),
        sort: GameOrder.dateDesc,
        filter: const GameFilter(rules: [HeaderRule(value: 'Ding')]),
      ),
    );
    final app = WindowFixture(viewerPlaces: stored);
    addTearDown(app.dispose);
    final ref = collectionRef('handoff');
    app.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await app.pumpShell(tester);
    await app.requests.openFile(ref);
    await tester.pumpAndSettle();
    expect(app.parts.session.game, 1);
    expect(app.parts.documents.filter.kept, 1);
    await app.requests.openFile(ref, game: 2);
    await tester.pumpAndSettle();
    expect(app.parts.session.game, 2);
    expect(app.parts.session.cursor.isRoot, isTrue);
    expect(app.parts.documents.filter.kept, 3);
    expect(find.text('of 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'sorted counter, number entry and keyboard share the visible list',
    (tester) async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      final ref = collectionRef('ordered');
      app.store.documents[ref] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      await app.pumpShell(tester);
      await app.requests.openFile(ref);
      await tester.pumpAndSettle();
      final viewer = app.parts.documents.viewer;
      viewer.sortBy(GameOrder.dateDesc);
      app.parts.documents.filter.apply(
        const GameFilter(
          rules: [HeaderRule(field: 'Event', value: 'Tata')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('of 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Previous game (↑)'));
      await tester.pumpAndSettle();
      expect(app.parts.session.game, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(app.parts.session.game, 0);
      final number = find.byWidgetPredicate(
        (w) => w is TextField && w.keyboardType == TextInputType.number,
      );
      await tester.enterText(number, '1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(app.parts.session.game, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _StoredPlace implements ViewerPlaces {
  _StoredPlace(this.place);
  ReadingPlace place;
  @override
  Future<ReadingPlace?> load(String path) async => place;
  @override
  Future<void> save(String path, ReadingPlace value) async {
    place = value;
  }
}
