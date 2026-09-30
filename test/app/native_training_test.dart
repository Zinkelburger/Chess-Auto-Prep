import 'dart:io';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/features/study/study_commands.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/native_window_fixture.dart';
import '../workspace/gap_hunt_test.dart' show TwoPositions;

const _study =
    '[Event "Prep: First"]\n[StudyName "Prep"]\n'
    '[ChapterName "First"]\n[Orientation "white"]\n[Result "*"]\n\n'
    '1. e4 e5 *\n\n'
    '[Event "Prep: Second"]\n[StudyName "Prep"]\n'
    '[ChapterName "Second"]\n[Orientation "black"]\n[Result "*"]\n\n'
    '1. d4 d5 *\n';
const _repertoire =
    '// Color: White\n\n[Event "First"]\n'
    '[LineID "same-line"]\n\n1. e4 e5 *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StoreFixture disk;
  late NativeWindowFixture app;
  setUp(() async {
    disk = await StoreFixture.create();
    app = NativeWindowFixture(disk, policy: TwoPositions());
    await app.ready();
  });
  tearDown(() async {
    app.dispose();
    await disk.dispose();
  });

  TrainerReady ready() => app.parts.training.lines.state as TrainerReady;

  for (final replacement in ['changed moves', 'same bytes, different file']) {
    test(
      'trainer refuses stale source after $replacement; reopening recovers',
      () async {
        final ref = ChapterRef.at(disk.ref('repertoires/Prep/Main.pgn').path);
        await disk.put(ref, _repertoire);
        await app.parts.session.open(ref);
        await app.parts.training.lines.reload();
        final old = ready();
        if (replacement == 'changed moves') {
          await File(
            ref.path,
          ).writeAsString(_repertoire.replaceFirst('e4 e5', 'd4 d5'));
        } else {
          final other = File('${ref.path}.replacement');
          await other.writeAsString(_repertoire);
          await other.rename(ref.path);
        }
        await app.parts.training.lines.reload();
        expect(app.parts.training.lines.state, isA<TrainerFailed>());
        // Retained callbacks from the disposed sitting cannot write a rating.
        await old.progress.finished(old.lines.single, Rating.good, clean: true);
        expect(
          File(p.join(disk.documents.path, reviewsFile)).existsSync(),
          isFalse,
        );
        await app.parts.session.reloadFromDisk();
        await app.parts.training.lines.reload();
        final fresh = ready();
        expect(
          fresh.lines.single.moves.first.san,
          replacement == 'changed moves' ? 'd4' : 'e4',
        );
        expect(
          await fresh.progress.finished(
            fresh.lines.single,
            Rating.good,
            clean: true,
          ),
          isA<ProgressWritten>(),
        );
      },
    );
  }

  test(
    'a scope cannot combine old displayed moves with newer chapters of the same file',
    () async {
      final file = ChapterRef.at(disk.ref('repertoires/Prep/Course.pgn').path);
      await disk.put(file, '// Color: White\n\n$_study');
      final ref = ChapterRef.at(file.path, section: 'First');
      await app.parts.catalog.synchronize();
      await app.parts.session.open(ref);
      await app.parts.training.lines.reload();
      expect(ready().lines.single.moves.first.san, 'e4');
      await File(file.path).writeAsString(
        '// Color: White\n\n${_study.replaceFirst('e4 e5', 'c4 e5')}',
      );
      app.parts.training.lines.setScope(TrainScope.repertoire);
      await app.parts.training.lines.reload();
      expect(app.parts.training.lines.state, isA<TrainerFailed>());
      expect(
        File(p.join(disk.documents.path, reviewsFile)).existsSync(),
        isFalse,
      );
      await app.parts.session.reloadFromDisk();
      await app.parts.training.lines.reload();
      expect(ready().lines.map((line) => line.moves.first.san), ['c4', 'd4']);
    },
  );

  test(
    'an unsaved local edit trains against its persisted source and follows its save',
    () async {
      final ref = ChapterRef.at(disk.ref('repertoires/Prep/Main.pgn').path);
      await disk.put(ref, _repertoire);
      await app.parts.session.open(ref);
      app.parts.session.goTo(NodePath.of([0, 0]));
      app.parts.session.playMove('g1f3');
      await app.parts.training.lines.reload();
      expect(ready().lines.single.moves.last.san, 'Nf3');
      expect(
        await ready().progress.finished(
          ready().lines.single,
          Rating.good,
          clean: true,
        ),
        isA<ProgressWritten>(),
      );
      await app.parts.saver.flush();
      await app.parts.training.lines.reload();
      expect(
        ready().progress.reviewOf(ready().lines.single).lastRating,
        'good',
      );
      expect(
        await ready().progress.finished(
          ready().lines.single,
          Rating.easy,
          clean: true,
        ),
        isA<ProgressWritten>(),
      );
    },
  );

  test(
    'group study trains both sides, reads the right game and preserves ratings through edit/reorder/restart',
    () async {
      final ref = ChapterRef.at(disk.ref('studies/Prep.pgn').path);
      await disk.put(ref, _study);
      final group = PlayerGroup.create('Club').edited({'study': ref.path});
      app.parts.training.lines.setScope(TrainScope.book);
      await app.parts.players.trainGroupStudy(group);
      await app.parts.training.lines.reload();
      expect(app.parts.requests.mode, Mode.trainer);
      expect(app.parts.training.lines.scope, TrainScope.chapter);
      expect(ready().lines.map((line) => line.moves.first.san), ['e4', 'd4']);
      expect(ready().lines.map((line) => line.side), [Side.white, Side.black]);
      final keys = ready().lines.map((line) => line.key).toList();
      final first = ready().lines.first;
      final second = ready().lines.last;
      expect(
        await ready().progress.finished(first, Rating.good, clean: true),
        isA<ProgressWritten>(),
      );
      expect(
        await ready().progress.finished(second, Rating.hard, clean: false),
        isA<ProgressWritten>(),
      );
      final read = ready().toRead(second, ReadIn.moves);
      await app.parts.requests.openAt(read.ref, read.sans, game: read.game);
      expect(app.parts.session.game, 1);
      expect(app.parts.session.orientation, Side.black);
      app.parts.session.playMove('c2c4');
      await app.parts.saver.flush();
      expect(moveStudyChapter(app.parts.session, index: 1, by: -1), isNull);
      await app.parts.saver.flush();
      await app.parts.training.lines.reload();
      expect(ready().lines.map((line) => line.key), keys.reversed);
      expect(ready().lines.first.moves.last.san, 'c4');
      app.dispose();
      app = NativeWindowFixture(disk, policy: TwoPositions());
      await app.ready();
      await app.parts.players.trainGroupStudy(group);
      await app.parts.training.lines.reload();
      expect(ready().lines.map((line) => line.key), keys.reversed);
      expect(
        ready().lines.map((line) => ready().progress.reviewOf(line).lastRating),
        ['hard', 'good'],
      );
      expect(deleteStudyChapter(app.parts.session, index: 0), isNull);
      await app.parts.saver.flush();
      await app.parts.training.lines.reload();
      expect(ready().lines.single.key, keys.first);
      expect(
        ready().progress.reviewOf(ready().lines.single).lastRating,
        'good',
      );
    },
  );
}
