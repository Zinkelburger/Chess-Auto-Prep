// What a save does about the write itself: the copy it keeps of the version
// it is replacing, and reading the file back afterwards. The filesystem is
// made to misbehave here, because nothing else shows it.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
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

  test('a save waits for a kept copy that really is the version being '
      'replaced', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final before = await File(ref.path).readAsBytes();
    // A kept version listed under the hash of what is on disk, holding
    // something else. Nothing may be replaced on the strength of that copy.
    await _keepInstead(fixture, ref, revision.contentHash, 'not the chapter\n');

    final result = await fixture.store.save(
      ref,
      chapterOf([
        gameOf(1, '1. d4 Nf6'),
        gameOf(2, '1. e4'),
        gameOf(3, '1. c4'),
      ]),
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect((result as IoFailure).detail, contains('could not be read back'));
    expect(await File(ref.path).readAsBytes(), before);
  });

  test(
    'putting back a version the store kept is not logged as a guess',
    () async {
      final entries = <LogEntry>[];
      void collect(LogEntry entry) => entries.add(entry);
      log.install(collect);
      addTearDown(() => log.remove(collect));
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, threeGames);
      final receipt =
          (await fixture.store.save(
                    ref,
                    chapterOf([
                      gameOf(1, '1. d4 Nf6'),
                      gameOf(2, '1. e4'),
                      gameOf(3, '1. c4'),
                    ]),
                    expected: revision,
                    scope: GamesEdited(GamesWritten(rewritten: {0})),
                  )
                  as Saved)
              .receipt;

      final undone = await fixture.restore(
        ref,
        receipt.before,
        receipt.committed,
      );

      expect(undone, isA<Saved>());
      expect(await File(ref.path).readAsString(), threeGames);
      expect(
        entries.map((entry) => '${entry.error}'),
        isNot(contains(contains('did not say which game'))),
      );
    },
  );

  test(
    'a file nothing can read after the write is not a save that failed',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, threeGames);
      final text = chapterOf([
        gameOf(1, '1. d4 Nf6'),
        gameOf(2, '1. e4'),
        gameOf(3, '1. c4'),
      ]);

      final result = await IOOverrides.runWithIOOverrides(
        () => fixture.store.save(
          ref,
          text,
          expected: revision,
          scope: GamesEdited(GamesWritten(rewritten: {0})),
        ),
        _ShutsTheDoorAfterRename(ref.path),
      );

      // The rename landed, so this is not "the document is as it was": the
      // saver must not go on expecting the revision it read.
      expect(result, isA<WriteUnverified>());
      expect(
        (result as WriteUnverified).detail,
        contains(fixture.backupFolder(ref).path),
      );
    },
    skip: _needsAPlainUser,
  );

  test('a file that does not hold what was written to it is reported, and '
      'the version it replaced is named', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final text = chapterOf([
      gameOf(1, '1. d4 Nf6'),
      gameOf(2, '1. e4'),
      gameOf(3, '1. c4'),
    ]);

    final result = await IOOverrides.runWithIOOverrides(
      () => fixture.store.save(
        ref,
        text,
        expected: revision,
        scope: GamesEdited(GamesWritten(rewritten: {0})),
      ),
      _PublishesSomethingElse(ref.path),
    );

    expect(result, isA<WriteUnverified>());
    expect(
      (result as WriteUnverified).detail,
      contains(fixture.backupFolder(ref).path),
    );
    expect(fixture.keptTexts(ref), [threeGames]);
  });
}

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

final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;

/// A filesystem that takes the document's permissions away as it is
/// published, so nothing can read back what was written.
final class _ShutsTheDoorAfterRename extends IOOverrides {
  _ShutsTheDoorAfterRename(this.document);

  final String document;

  @override
  File createFile(String path) => path == temporaryPathFor(document)
      ? _ClosedOnRename(super.createFile(path))
      : super.createFile(path);
}

final class _ClosedOnRename implements File {
  _ClosedOnRename(this._staged);

  final File _staged;

  @override
  String get path => _staged.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _staged.open(mode: mode);

  @override
  Future<File> rename(String newPath) async {
    final renamed = await _staged.rename(newPath);
    await Process.run('chmod', ['000', newPath]);
    return renamed;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _staged.delete(recursive: recursive);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
