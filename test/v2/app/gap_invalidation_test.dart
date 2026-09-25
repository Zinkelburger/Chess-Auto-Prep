import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
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
    'unrelated commits and cursor movement preserve a gap walk and lesson',
    () async {
      final fixture = WindowFixture(maia: TwoPositions());
      addTearDown(fixture.dispose);
      fixture.store.documents[benkoMain] = Opened(
        chapter,
        scriptedRevision(chapter),
      );
      fixture.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
      ]);
      await fixture.library.refresh();
      await fixture.session.open(benkoMain);
      final workspace = fixture.parts.workspace;
      final trainer = fixture.parts.training.lines;
      trainer.setScope(TrainScope.repertoire);
      await trainer.reload();
      await pumpEventQueue();
      trainer.learn();
      final lesson = trainer.lesson;
      final walk = workspace.gaps.walk;
      expect(lesson, isNotNull);
      expect(walk, isNotNull);
      final unrelated = await fixture.parts.env.store.open(kidMain) as Opened;
      await fixture.parts.env.store.save(
        kidMain,
        '${unrelated.text}\n',
        expected: unrelated.revision,
        scope: const WholeDocument(),
      );
      await fixture.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(trainer.lesson, same(lesson));
      expect(workspace.gaps.currentWalk, same(walk));
      fixture.session.goTo(NodePath.of([0]));
      await pumpEventQueue();
      expect(workspace.gaps.currentWalk, same(walk));
      expect(trainer.lesson, same(lesson));

      // A subsequent sibling commit must revoke authority immediately, while
      // the shared catalog's replacement listing is still held.
      fixture.chapterFiles.hold = true;
      fixture.chapterFiles.listing = Repertoires([
        folder('benko', ['Main', 'Sibling']),
        folder('KID', ['Main']),
      ]);
      await fixture.parts.env.store.create(ref('benko', 'Sibling'), sicilian);
      expect(trainer.lesson, isNull);
      expect(workspace.gaps.currentWalk, isNull);
      expect(workspace.gaps.canNextGap, isFalse);
      // Let the affected trainer finish its pending-write barrier and begin
      // its held scope read before counting work caused by the next event.
      await pumpEventQueue();
      final reads = fixture.chapterFiles.listings;
      await fixture.parts.env.store.create(ref('Unrelated', 'Main'), sicilian);
      await pumpEventQueue();
      // The cumulative catalog batch still contains the sibling event, but
      // its later unrelated admission must not restart these held reads.
      expect(fixture.chapterFiles.listings, reads);
      fixture.chapterFiles.hold = false;
      fixture.chapterFiles.releaseAll();
      await fixture.parts.catalog.synchronize();
      await pumpEventQueue();
      expect(trainer.state, isA<TrainerReady>());
      expect(workspace.gaps.currentWalk, isNotNull);
    },
  );

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
