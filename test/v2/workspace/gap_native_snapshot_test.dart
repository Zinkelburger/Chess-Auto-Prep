import 'dart:io';

import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/gap_hunt.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';

void main() {
  late StoreFixture disk;
  late RepertoireAnswers answers;
  late ChapterRef main;
  late ChapterRef sibling;
  const text = '// Color: White\n\n[Event "Line"]\n\n1. e4 c5 2. c3 *\n';
  setUp(() async {
    disk = await StoreFixture.create();
    main = ChapterRef.at(disk.ref('repertoires/Course/Main.pgn').path);
    sibling = ChapterRef.at(disk.ref('repertoires/Course/Sibling.pgn').path);
    await disk.put(main, text);
    await disk.put(sibling, text);
    answers = RepertoireAnswers(
      files: ChapterDirectory(
        Directory(p.join(disk.documents.path, 'repertoires')),
        recovery: disk.store.recovery,
      ),
      documents: disk.store,
    );
  });
  tearDown(() => disk.dispose());

  for (final change in [
    'sibling bytes',
    'same bytes replacement',
    'membership',
  ]) {
    test('answer snapshot rejects unannounced $change', () async {
      final snapshot = await answers.capture(
        main,
        Side.white,
        observed: {main.path: await disk.revisionOf(main)},
      );
      expect(snapshot.positions, isNotEmpty);
      switch (change) {
        case 'sibling bytes':
          await File(
            sibling.path,
          ).writeAsString(text.replaceAll('c5 2. c3', 'e5 2. Nf3'));
        case 'same bytes replacement':
          await File(sibling.path).rename('${sibling.path}.old');
          await File(sibling.path).writeAsString(text);
        case 'membership':
          await File(
            p.join(p.dirname(main.path), 'New.pgn'),
          ).writeAsString(text);
      }
      await expectLater(
        snapshot.validate(),
        throwsA(isA<RepertoireAnswersUnavailable>()),
      );
    });
  }

  test(
    'unrelated repertoire edits preserve the current answer snapshot',
    () async {
      final snapshot = await answers.capture(
        main,
        Side.white,
        observed: {main.path: await disk.revisionOf(main)},
      );
      await disk.put(disk.ref('repertoires/Unrelated/Main.pgn'), text);
      await snapshot.validate();
    },
  );

  test('unreadable sibling never becomes a current empty answer set', () async {
    final outside = await File(
      p.join(disk.root.path, 'outside.pgn'),
    ).writeAsString(text);
    await File(sibling.path).delete();
    await Link(sibling.path).create(outside.path);
    await expectLater(
      answers.capture(main, Side.white),
      throwsA(isA<RepertoireAnswersUnavailable>()),
    );
    await Link(sibling.path).delete();
    await File(sibling.path).writeAsString(text);
    expect(await answers.around(main, Side.white), isNotEmpty);
  });
}
