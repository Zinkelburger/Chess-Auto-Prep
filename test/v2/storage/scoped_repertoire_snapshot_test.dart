import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/workspace/gap_hunt.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture disk;
  late ChapterDirectory files;
  late ChapterRef nested;
  late ChapterRef sibling;
  late DocumentRef unrelated;
  const text = '// Color: White\n\n[Event "Line"]\n\n1. e4 c5 2. c3 *';

  setUp(() async {
    disk = await StoreFixture.create();
    files = ChapterDirectory(
      Directory(p.join(disk.documents.path, 'repertoires')),
      recovery: disk.store.recovery,
    );
    nested = ChapterRef.at(disk.ref('repertoires/Course/Sub/A.pgn').path);
    sibling = ChapterRef.at(disk.ref('repertoires/Course/B.pgn').path);
    unrelated = disk.ref('repertoires/Other/X.pgn');
    await disk.put(nested, text);
    await disk.put(sibling, text);
    await disk.put(unrelated, text);
  });
  tearDown(() => disk.dispose());

  test(
    'nested chapters include answers from the whole top-level repertoire',
    () async {
      final answers = RepertoireAnswers(files: files, documents: disk.store);
      final positions = await answers.around(nested, Side.white);
      expect(positions[Fen.initial.position], 'B');
    },
  );
  test(
    'directory boundary captures every nested file and excludes other repertoires',
    () async {
      final full = await files.list() as Repertoires;
      final scoped = full.within({p.dirname(sibling.path)});
      expect(
        scoped.revisions.keys,
        unorderedEquals([nested.path, sibling.path]),
      );
      expect(
        await files.validate(scoped, observed: scoped.revisions),
        isA<RepertoireCurrent>(),
      );
      await File(unrelated.path).rename('${unrelated.path}.old');
      await File(unrelated.path).writeAsString(text);
      expect(
        await files.validate(scoped, observed: scoped.revisions),
        isA<RepertoireCurrent>(),
      );
      expect(
        await files.validate(full, observed: full.revisions),
        isA<RepertoireChanged>(),
      );
    },
  );

  test('an individual file boundary excludes a changed sibling', () async {
    final full = await files.list() as Repertoires;
    final scoped = full.within({nested.path});
    expect(scoped.revisions.keys, [nested.path]);
    await File(sibling.path).writeAsString(text.replaceFirst('e4 c5', 'e4 e5'));
    expect(
      await files.validate(scoped, observed: scoped.revisions),
      isA<RepertoireCurrent>(),
    );
    await File(nested.path).rename('${nested.path}.old');
    await File(nested.path).writeAsString(text);
    expect(
      await files.validate(scoped, observed: scoped.revisions),
      isA<RepertoireChanged>(),
    );
  });

  test('directory scope rejects a newly created nested member', () async {
    final full = await files.list() as Repertoires;
    final scoped = full.within({p.dirname(sibling.path)});
    await disk.put(disk.ref('repertoires/Course/Sub/New.pgn'), text);
    expect(
      await files.validate(scoped, observed: scoped.revisions),
      isA<RepertoireChanged>(),
    );
  });

  for (final boundary in [
    'repertoires/Missing',
    'repertoires/Missing/New.pgn',
  ]) {
    test(
      'absent boundary $boundary rejects later membership creation',
      () async {
        final full = await files.list() as Repertoires;
        final scoped = full.within({disk.ref(boundary).path});
        expect(scoped.revisions, isEmpty);
        await disk.put(disk.ref('repertoires/Unrelated/New.pgn'), text);
        expect(
          await files.validate(scoped, observed: const {}),
          isA<RepertoireCurrent>(),
        );
        await disk.put(disk.ref('repertoires/Missing/New.pgn'), text);
        expect(
          await files.validate(scoped, observed: const {}),
          isA<RepertoireChanged>(),
        );
      },
    );
  }

  test(
    'moving a directory ancestor invalidates a nested file boundary',
    () async {
      final full = await files.list() as Repertoires;
      final scoped = full.within({nested.path});
      final course = Directory(p.dirname(sibling.path));
      await course.rename('${course.path}-moved');
      expect(
        await files.validate(scoped, observed: scoped.revisions),
        isA<RepertoireChanged>(),
      );
    },
  );
}
