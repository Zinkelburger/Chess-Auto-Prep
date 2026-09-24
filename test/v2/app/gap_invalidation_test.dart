import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/gap_walk.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';
import '../workspace/gap_hunt_test.dart' show TwoPositions, chapter;

const sicilian =
    '// Color: White\n\n[Event "Sicilian"]\n[Result "*"]\n\n1. e4 c5 2. Nf3 *\n';

void main() {
  test(
    'committed sibling delete and import update gaps and replies in place',
    () async {
      final fixture = WindowFixture(maia: TwoPositions());
      addTearDown(fixture.dispose);
      final sibling = ref('benko', 'Sicilian');
      fixture.store.documents[benkoMain] = Opened(
        chapter,
        scriptedRevision(chapter),
      );
      fixture.store.documents[sibling] = Opened(
        sicilian,
        scriptedRevision(sicilian),
      );
      fixture.chapterFiles.listing = Repertoires([
        folder('benko', ['Main', 'Sicilian']),
      ]);
      final workspace = fixture.parts.workspace;
      await fixture.library.refresh();
      await fixture.session.open(benkoMain);
      fixture.session.goTo(NodePath.of([0]));
      await pumpEventQueue();

      ReplyRow c5() => (workspace.replies.table as RepliesShown).rows
          .singleWhere((row) => row.uci == 'c7c5');
      bool missing() => workspace.gaps.walk!.gaps.whereType<MissingReply>().any(
        (gap) => gap.uci == 'c7c5',
      );

      expect(missing(), isFalse);
      expect(c5().elsewhere, 'Sicilian');
      final opened = fixture.session.chapter;
      fixture.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
      ]);
      expect(
        await fixture.parts.env.store.delete(
          sibling,
          expected: scriptedRevision(sicilian),
        ),
        isA<Deleted>(),
      );
      await fixture.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(fixture.session.chapter, same(opened));
      expect(missing(), isTrue);
      expect(c5().elsewhere, isNull);
      expect(c5().gap, isTrue);

      workspace.gaps.nextGap();
      expect(workspace.gaps.highlighted, isNotNull);
      fixture.chapterFiles.listing = Repertoires([
        folder('benko', ['Main', 'Sicilian']),
      ]);
      expect(
        await fixture.parts.env.store.create(sibling, sicilian),
        isA<Created>(),
      );
      await fixture.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(fixture.session.chapter, same(opened));
      expect(missing(), isFalse);
      expect(workspace.gaps.highlighted, isNull);
      expect(c5().elsewhere, 'Sicilian');
      expect(c5().gap, isFalse);
    },
  );
}
