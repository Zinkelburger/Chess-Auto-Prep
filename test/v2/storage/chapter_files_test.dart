import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-chapters-');
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> put(String relative, String text) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<List<RepertoireFolder>> list() async =>
      ((await ChapterDirectory(root).list()) as Repertoires).folders;

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
    final files = ChapterDirectory(Directory(p.join(root.path, 'none')));
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
      final listing = (await ChapterDirectory(root).list()) as Repertoires;
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
    final files = ChapterDirectory(root);
    await files.removeIfEmpty(empty.path);
    await files.removeIfEmpty(p.join(root.path, 'Gone'));
    expect(empty.existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'Gone')).existsSync(), isTrue);
  });

  Future<List<DeletedChapter>> deleted() async =>
      ((await ChapterDirectory(root).deleted()) as DeletedChapters).chapters;

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
    final files = ChapterDirectory(Directory(p.join(root.path, 'none')));
    expect(((await files.deleted()) as DeletedChapters).chapters, isEmpty);
  });
}

final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;
