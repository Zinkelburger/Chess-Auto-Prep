import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory profile;
  late RecoveryGate recovery;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('v2-chapters-');
    root = await Directory(p.join(profile.path, 'repertoires')).create();
    recovery = RecoveryGate(
      documents: profile,
      support: Directory(p.join(profile.path, 'Support')),
    );
  });

  tearDown(() => profile.delete(recursive: true));

  Future<void> put(String relative, String text) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<List<RepertoireFolder>> list() async =>
      ((await ChapterDirectory(root, recovery: recovery).list()) as Repertoires)
          .folders;

  test(
    'equal size and timestamp do not reuse stale section metadata',
    () async {
      await put(
        'Course/Main.pgn',
        '[Event "Line"]\n[ChapterName "Old"]\n\n1. e4 *',
      );
      final file = File(p.join(root.path, 'Course', 'Main.pgn'));
      final modified = (await file.stat()).modified;
      final files = ChapterDirectory(root, recovery: recovery);
      final before = await files.list() as Repertoires;
      expect(before.folders.single.chapters.single.section, 'Old');
      await put(
        'Course/Main.pgn',
        '[Event "Line"]\n[ChapterName "New"]\n\n1. e4 *',
      );
      await file.setLastModified(modified);
      final after = await files.list() as Repertoires;
      expect(after.folders.single.chapters.single.section, 'New');
    },
  );

  test('one folder per repertoire, chapters by name', () async {
    await put('KID/Main.pgn', '*');
    await put('KID/aux.pgn', '*');
    await put('KID/index.json', '{}');
    await put('benko/Main.pgn', '*');
    await put('stray.pgn', '*');
    final folders = await list();
    expect(folders.map((f) => f.name), ['benko', 'KID', 'stray']);
    expect(folders[1].chapters.map((c) => c.name), ['aux', 'Main']);
    expect(
      folders.first.chapters.single.path,
      p.join(root.path, 'benko', 'Main.pgn'),
    );
  });

  test('raw-game sidecars and hidden folders are not chapters', () async {
    await put('KID/Main.pgn', '*');
    await put('KID/Main_raw_games.pgn', '*');
    await put('.cap-pgn-history/old.pgn', '*');
    final folders = await list();
    expect(folders.single.chapters.map((c) => c.name), ['Main']);
  });

  test(
    'a folder with nothing but recovery in it is not a repertoire',
    () async {
      await put('Sidelines/.cap-pgn-history/1-2-Main.pgn', '*');
      expect(await list(), isEmpty);
    },
  );

  test('a repertoire is as recent as its newest chapter', () async {
    await put('KID/Main.pgn', '*');
    final folder = (await list()).single;
    expect(
      folder.modified.difference(DateTime.now()).inMinutes.abs(),
      lessThan(2),
    );
  });

  test(
    'a chapter’s root and draft mark are read off the top of the file',
    () async {
      await put(
        'KID/Gambit.pgn',
        '// Gambit\n// Color: White\n// Draft\n// Root: 1. e4 e5 2. f4\n\n'
            '[Event "x"]\n\n1. e4 e5 2. f4 *\n',
      );
      await put('KID/Main.pgn', '// Main\n// Color: White\n\n');
      final chapters = (await list()).single.chapters;
      expect(chapters.first.heading.rootMoves, ['e4', 'e5', 'f4']);
      expect(chapters.first.heading.draft, isTrue);
      expect(chapters.last.heading, ChapterHeading.none);
    },
  );

  test('a missing repertoires folder is an empty library', () async {
    final files = ChapterDirectory(
      Directory(p.join(root.path, 'none')),
      recovery: recovery,
    );
    expect(((await files.list()) as Repertoires).folders, isEmpty);
  });

  test(
    'a repertoire this app may not read is named, and the rest are listed',
    () async {
      await put('KID/Main.pgn', '*');
      await put('Benko/Main.pgn', '*');
      final closed = p.join(root.path, 'Benko');
      await Process.run('chmod', ['000', closed]);
      addTearDown(() => Process.run('chmod', ['u+rwx', closed]));
      final listing =
          (await ChapterDirectory(root, recovery: recovery).list())
              as Repertoires;
      expect(listing.folders.map((f) => f.name), ['KID']);
      expect(listing.unreadable.single.name, 'Benko');
      expect(listing.unreadable.single.path, closed);
      expect(listing.unreadable.single.detail, isNotEmpty);
    },
    skip: _needsAPlainUser,
  );

  test('an empty folder is removed, one with anything in it is not', () async {
    await put('Gone/.cap-pgn-history/1-2-Main.pgn', '*');
    final empty = Directory(p.join(root.path, 'Empty'));
    await empty.create();
    final files = ChapterDirectory(root, recovery: recovery);
    await files.removeIfEmpty(empty.path);
    await files.removeIfEmpty(p.join(root.path, 'Gone'));
    expect(empty.existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'Gone')).existsSync(), isTrue);
  });

  test('an unused chapter goes with no recovery copy while it holds what '
      'was made; a changed one stays', () async {
    Revision of(String text) =>
        Revision(sha256.convert(utf8.encode(text)).toString());
    await put('KID/Indian.pgn', '// Indian\n');
    await put('KID/Edited.pgn', '// Edited\n1. d4 *\n');
    final files = ChapterDirectory(root, recovery: recovery);
    final indian = DocumentRef(p.join(root.path, 'KID', 'Indian.pgn'));
    final edited = DocumentRef(p.join(root.path, 'KID', 'Edited.pgn'));

    expect(await files.removeUnused(indian, of('// Indian\n')), isTrue);
    expect(await files.removeUnused(edited, of('// Edited\n')), isFalse);
    expect(
      await files.removeUnused(
        DocumentRef(p.join(profile.path, 'Elsewhere.pgn')),
        of(''),
      ),
      isFalse,
    );

    expect(File(indian.path).existsSync(), isFalse);
    expect(File(edited.path).existsSync(), isTrue);
    expect(
      Directory(p.join(root.path, 'KID', '.cap-pgn-history')).existsSync(),
      isFalse,
    );
  });

  Future<List<DeletedChapter>> deleted() async =>
      ((await ChapterDirectory(root, recovery: recovery).deleted())
              as DeletedChapters)
          .chapters;

  test(
    'deleted chapters are read off their recovery names, newest first',
    () async {
      await put('KID/.cap-pgn-history/1000000-a1-Main.pgn', '*');
      await put('KID/.cap-pgn-history/3000000-ff-Sämisch 5.f3.pgn', '*');
      await put('Gone/.cap-pgn-history/2000000-0c-Only.pgn', '*');
      final chapters = await deleted();
      expect(chapters.map((c) => c.name), ['Sämisch 5.f3', 'Only', 'Main']);
      final newest = chapters.first;
      expect(newest.repertoire, 'KID');
      expect(newest.deletedAt, DateTime.fromMicrosecondsSinceEpoch(3000000));
      expect(newest.restoredAs(), p.join(root.path, 'KID', 'Sämisch 5.f3.pgn'));
      expect(newest.restoredAs('Other'), p.join(root.path, 'KID', 'Other.pgn'));
    },
  );

  test(
    'kept versions, sidecars and stray files are not deleted chapters',
    () async {
      await put('KID/.cap-pgn-history/1-2-Main.pgn', '*');
      await put('KID/.cap-pgn-history/abcdef.bytes', '*');
      await put('KID/.cap-pgn-history/3-4-Main_raw_games.pgn', '*');
      await put('KID/.cap-pgn-history/notes.pgn', '*');
      await put('KID/.cap-pgn-history/x-4-Main.pgn', '*');
      await put('.import-1/.cap-pgn-history/5-6-Main.pgn', '*');
      expect((await deleted()).map((c) => c.name), ['Main']);
    },
  );

  test('no repertoires folder means nothing deleted', () async {
    final files = ChapterDirectory(
      Directory(p.join(root.path, 'none')),
      recovery: recovery,
    );
    expect(((await files.deleted()) as DeletedChapters).chapters, isEmpty);
  });

  test(
    '.PGN chapters list like .pgn, their raw-game sidecars do not',
    () async {
      await put('Sicilian/Najdorf.PGN', '[Event "Line"]\n\n1. e4 c5 *');
      await put('Sicilian/Najdorf_raw_games.PGN', '[Event "Game"]\n\n1. e4 *');
      await put('Upper/Only.PGN', '[Event "Line"]\n\n1. d4 *');
      final folders = await list();
      expect(folders.map((f) => f.name), ['Sicilian', 'Upper']);
      expect(folders.first.chapters.map((c) => c.name), ['Najdorf']);
      expect(
        readRecoveryName(
          p.join(
            root.path,
            'Sicilian',
            '.cap-pgn-history',
            '123-abc-Najdorf.PGN',
          ),
          folder: p.join(root.path, 'Sicilian'),
        )?.name,
        'Najdorf',
      );
    },
  );

  test('import staging left by an earlier run is swept on listing', () async {
    await put('.import-abc/X.pgn', '[Event "Line"]\n\n1. e4 *');
    await put('.cap-pgn-history/1-2-Main.pgn', '*');
    await put('KID/Main.pgn', '[Event "Line"]\n\n1. d4 *');
    // Directory times have millisecond precision; keep the orphan older.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final files = ChapterDirectory(root, recovery: recovery);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await put('.import-new/Y.pgn', '[Event "Line"]\n\n1. c4 *');
    final listed = await files.list() as Repertoires;
    expect(listed.folders.map((f) => f.name), ['KID']);
    expect(Directory(p.join(root.path, '.import-abc')).existsSync(), isFalse);
    expect(Directory(p.join(root.path, '.import-new')).existsSync(), isTrue);
    expect(
      File(p.join(root.path, '.cap-pgn-history', '1-2-Main.pgn')).existsSync(),
      isTrue,
    );
    expect(File(p.join(root.path, 'KID', 'Main.pgn')).existsSync(), isTrue);
  });
}

final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;
