// What a save is allowed to change, against real files. A chapter holds
// games the edit never looked at, and these are the ways a save that would
// have touched one of them is stopped before it reaches the disk.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('a save that changes only the game it declared goes through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final edited = _chapter([
      _game(1, '1. d4 Nf6'),
      _game(2, '1. e4'),
      _game(3, '1. c4'),
    ]);

    final saved = await fixture.store.save(
      ref,
      edited,
      expected: revision,
      scope: const GamesEdited({0}),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), edited);
  });

  test('a save that would also change a game nobody edited is refused and '
      'the file is byte for byte as it was', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final before = await File(ref.path).readAsBytes();
    // What a writer with a bug produces: the edit was to the first game and
    // the third one came out different anyway.
    final text = _chapter([
      _game(1, '1. d4 Nf6'),
      _game(2, '1. e4'),
      _game(3, '1. c4 g6'),
    ]);

    final result = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const GamesEdited({0}),
    );

    expect((result as SaveRefused).detail, contains('game 3 would change'));
    expect(result.detail, contains('the edit was to game 1'));
    expect(await File(ref.path).readAsBytes(), before);
    expect(fixture.keptTexts(ref), isEmpty, reason: 'nothing was replaced');
  });

  test('a writer that rewrites a game the edit never touched is refused, '
      'whatever the text says', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final before = await File(ref.path).readAsBytes();
    // A real edit: a move at the end of the first line, which writes that
    // game and says so. The scope is the edit's own answer, so a writer that
    // does more than the edit asked for cannot widen it.
    final chapter = parseChapter(name: 'Main', text: _threeGames);
    final edit =
        addMove(chapter, at: NodePath.of([0]), uci: 'g8f6') as MoveAdded;
    expect(edit.written.rewritten, {0});
    final damaged = writeChapter(
      edit.chapter,
    ).replaceFirst('1. c4 *', '1. c4 e5 *');

    final result = await fixture.store.save(
      ref,
      damaged,
      expected: revision,
      scope: GamesEdited(
        edit.written.rewritten,
        appended: edit.written.appended,
      ),
    );

    expect((result as SaveRefused).detail, contains('game 3 would change'));
    expect(await File(ref.path).readAsBytes(), before);
    expect(fixture.keptTexts(ref), isEmpty);
  });

  test('a save that would drop a game is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final before = await File(ref.path).readAsBytes();
    final text = _chapter([_game(1, '1. d4 Nf6'), _game(3, '1. c4')]);

    final result = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const GamesEdited({0}),
    );

    expect((result as SaveRefused).detail, contains('game 2 would change'));
    expect(await File(ref.path).readAsBytes(), before);
    expect(fixture.keptTexts(ref), isEmpty);
  });

  test('a save that adds a game at the end and says so goes through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final text = _chapter([
      _game(1, '1. d4'),
      _game(2, '1. e4'),
      _game(3, '1. c4'),
      _game(4, '1. Nf3'),
    ]);

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const GamesEdited({}, appended: 1),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
  });

  test('the first game of a chapter that had none may push the heading '
      'down', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, '// Main\n// Color: White\n');
    final text = '// Main\n// Color: White\n\n${_game(1, '1. d4')}\n';

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const GamesEdited({}, appended: 1),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
  });

  test('a save that would rewrite the heading is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final before = await File(ref.path).readAsBytes();
    final text = _threeGames.replaceFirst('Color: White', 'Color: Black');

    final result = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const GamesEdited({0}),
    );

    expect((result as SaveRefused).detail, contains('chapter heading'));
    expect(await File(ref.path).readAsBytes(), before);
  });

  test('a save that says it replaced the whole document goes through and is '
      'logged', () async {
    final entries = <LogEntry>[];
    void collect(LogEntry entry) => entries.add(entry);
    log.install(collect);
    addTearDown(() => log.remove(collect));
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final text = _chapter([_game(9, '1. f4')]);

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const WholeDocument(),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
    expect(
      entries
          .where((entry) => entry.level == LogLevel.warning)
          .map((entry) => '${entry.error}'),
      contains(contains('did not say which game')),
    );
  });

  test('a compressed chapter is refused before any of this', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final compressed = gzip.encode(utf8.encode(_threeGames));
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(compressed);
    final revision = await fixture.revisionOf(ref);

    final result = await fixture.store.save(
      ref,
      _chapter([_game(1, '1. d4 Nf6')]),
      expected: revision,
      scope: const GamesEdited({0}),
    );

    expect((result as IoFailure).detail, contains('compressed'));
    expect(await File(ref.path).readAsBytes(), compressed);
  });

  test('a save waits for a kept copy that really is the version being '
      'replaced', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final before = await File(ref.path).readAsBytes();
    // A kept version listed under the hash of what is on disk, holding
    // something else. Nothing may be replaced on the strength of that copy.
    await _keepInstead(fixture, ref, revision.contentHash, 'not the chapter\n');

    final result = await fixture.store.save(
      ref,
      _chapter([_game(1, '1. d4 Nf6'), _game(2, '1. e4'), _game(3, '1. c4')]),
      expected: revision,
      scope: const GamesEdited({0}),
    );

    expect((result as IoFailure).detail, contains('could not be read back'));
    expect(await File(ref.path).readAsBytes(), before);
  });

  test('a file that does not hold what was written to it is reported, and '
      'the version it replaced is named', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, _threeGames);
    final text = _chapter([
      _game(1, '1. d4 Nf6'),
      _game(2, '1. e4'),
      _game(3, '1. c4'),
    ]);

    final result = await IOOverrides.runWithIOOverrides(
      () => fixture.store.save(
        ref,
        text,
        expected: revision,
        scope: const GamesEdited({0}),
      ),
      _PublishesSomethingElse(ref.path),
    );

    expect(result, isA<WriteUnverified>());
    expect(
      (result as WriteUnverified).detail,
      contains(fixture.backupFolder(ref).path),
    );
    expect(fixture.keptTexts(ref), [_threeGames]);
  });
}

const _heading = '// Main\n// Color: White\n\n';

String _game(int number, String moves) =>
    '[Event "Line $number"]\n[Result "*"]\n\n$moves *';

String _chapter(List<String> games) =>
    '$_heading${games.map((game) => '$game\n\n').join()}';

final _threeGames = _chapter([
  _game(1, '1. d4'),
  _game(2, '1. e4'),
  _game(3, '1. c4'),
]);

/// Puts [text] in the archive as the newest version of [ref], under [hash],
/// which is not its hash. Only a save that reads the copy it kept, rather
/// than believing the list, notices.
Future<void> _keepInstead(
  StoreFixture fixture,
  DocumentRef ref,
  String hash,
  String text,
) async {
  final folder = fixture.backupFolder(ref);
  await folder.create(recursive: true);
  const name = '20260101T000000000Z-abcdef01.pgn.gz';
  await File(
    p.join(folder.path, name),
  ).writeAsBytes(gzip.encode(utf8.encode(text)));
  await File(p.join(folder.path, 'index.json')).writeAsString(
    jsonEncode({
      'path': ref.path,
      'versions': [
        {
          'file': name,
          'time': '2026-01-01T00:00:00.000Z',
          'size': text.length,
          'hash': hash,
        },
      ],
    }),
  );
}

/// A filesystem that writes a line of its own into the document as it is
/// published. There is no other way to see what a save does when the file
/// does not end up holding what went out to it.
final class _PublishesSomethingElse extends IOOverrides {
  _PublishesSomethingElse(this.document);

  final String document;

  @override
  File createFile(String path) => path == temporaryPathFor(document)
      ? _TamperedOnRename(super.createFile(path))
      : super.createFile(path);
}

final class _TamperedOnRename implements File {
  _TamperedOnRename(this._staged);

  final File _staged;

  @override
  String get path => _staged.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _staged.open(mode: mode);

  @override
  Future<File> rename(String newPath) async {
    final renamed = await _staged.rename(newPath);
    return renamed..writeAsStringSync('tampered\n', mode: FileMode.append);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _staged.delete(recursive: recursive);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
