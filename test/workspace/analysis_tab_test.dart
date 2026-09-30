import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/scripted_store.dart';

void main() {
  test(
    'inner analysis keeps collection, filters and draft and restores scratch undo',
    () async {
      final w = WindowFixture();
      addTearDown(w.dispose);
      final ref = collectionRef('Collection');
      w.store.documents[ref] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      await w.requests.openFile(ref, game: 0);
      w.session.holdsEdits = true;
      w.session.forward();
      final cursor = w.session.cursor;
      w.session.setComment(cursor, 'Unsaved source note');
      final filter = w.parts.documents.filter;
      filter.apply(const GameFilter(rules: [HeaderRule(value: 'Carlsen')]));
      final docs = w.requests.documents.tabs.open;
      final inspection = w.parts.workspace.inspection!;
      expect(await inspection.show(), isTrue);
      expect(w.requests.documents.tabs.open, docs);
      expect(w.viewer.file, ref);
      expect(filter.kept, 1);
      expect(w.session.cursor, cursor);
      expect(inspection.session.cursor, cursor);
      expect(inspection.session.commentAt(cursor), 'Unsaved source note');
      inspection.session.playMove('c7c5');
      final scratchCursor = inspection.session.cursor;
      inspection.session.setComment(scratchCursor, 'Scratch only');
      inspection.hide();
      expect(w.session.cursor, cursor);
      expect(w.session.hasHeldEdits, isTrue);
      expect(await inspection.show(), isTrue);
      expect(inspection.session.cursor, scratchCursor);
      expect(inspection.session.commentAt(scratchCursor), 'Scratch only');
      await inspection.session.undo();
      expect(
        inspection.session.commentAt(scratchCursor),
        isNot('Scratch only'),
      );
      expect(w.store.requestedSaves, isEmpty);
      w.viewer.showGame(1);
      expect(inspection.active, isFalse);
      expect(await inspection.show(), isTrue);
      expect(inspection.session.tree!.children.first.san, 'd4');
      w.viewer.showGame(0);
      expect(await inspection.show(), isTrue);
      expect(inspection.session.cursor, scratchCursor);
      expect(w.session.commentAt(NodePath.of([0])), 'Unsaved source note');
      final other = collectionRef('Other collection');
      w.store.documents[other] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      await w.requests.openFile(other, game: 1);
      expect(inspection.active, isFalse);
      expect(await inspection.show(), isTrue);
      expect(inspection.session.tree!.children.first.san, 'd4');
      await w.requests.documents.select(ref);
      expect(await inspection.show(), isTrue);
      expect(inspection.session.cursor, scratchCursor);
      expect(w.session.hasHeldEdits, isTrue);
    },
  );
}
