// A move is two writes: the rename, and the training rows that name the file.
// These are the cases where a machine stops between them, against real files
// in a disposable Documents folder.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';

import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

const _progress = 'repertoire_move_progress.csv';
const _header = 'repertoire_id,line_id,move_index,correct_streak,learned';

String _row(String id) => '$id,line_1,4,2,true';

void main() {
  late StoreFixture fixture;
  late PendingRepoints notes;

  setUp(() async {
    fixture = await StoreFixture.create();
    notes = PendingRepoints(fixture.support, documents: fixture.documents);
  });
  tearDown(() => fixture.dispose());

  String read() =>
      File(p.join(fixture.documents.path, _progress)).readAsStringSync();

  void writeRows(List<DocumentRef> chapters) =>
      File(p.join(fixture.documents.path, _progress)).writeAsStringSync(
        '$_header\n${chapters.map((c) => _row(c.path)).join('\n')}\n',
      );

  /// A chapter on disk with a training row naming it, and its revision.
  Future<Revision> chapter(DocumentRef ref) =>
      fixture.put(ref, '[Event "x"]\n\n1. d4 *\n');

  /// The store the next app session opens; it finishes the notes it finds.
  PgnFileStore restarted() =>
      PgnFileStore(documents: fixture.documents, support: fixture.support);

  /// Whether a note was set aside rather than finished.
  Future<bool> setAside(String id) async {
    final folder = Directory(
      p.join(fixture.support.path, 'recovery-quarantine'),
    );
    if (!await folder.exists()) return false;
    return folder
        .list(recursive: true)
        .any((entry) => p.basename(entry.path) == 'unfinished-moves-$id.json');
  }

  /// The native identity of the file at [ref], which is what a note
  /// carries.
  Future<String> identityOf(DocumentRef ref) async =>
      (await probeDocument(ref.path) as FileFound).identity;

  test(
    'a note for a move that never happened is dropped, rows and all',
    () async {
      final kid = fixture.ref('repertoires/KID/Main.pgn');
      final slav = fixture.ref('repertoires/Slav/Main.pgn');
      await chapter(kid);
      final identity = await identityOf(kid);
      final other = await chapter(slav);
      writeRows([kid]);
      // The machine stopped after the note and before the rename: the chapter
      // is still where it was.
      await notes.record(
        'stopped-early',
        from: kid.path,
        to: fixture.ref('repertoires/KID/Renamed.pgn').path,
        identity: identity,
        folder: false,
      );

      await restarted().rename(slav, 'Other.pgn', expected: other);

      expect(read(), contains(_row(kid.path)));
      expect(await notes.read(), isEmpty, reason: 'nothing is owed');
    },
  );

  test(
    'a note nobody can make sense of is kept and nothing is rewritten',
    () async {
      final kid = fixture.ref('repertoires/KID/Main.pgn');
      final renamed = fixture.ref('repertoires/KID/Renamed.pgn');
      final slav = fixture.ref('repertoires/Slav/Main.pgn');
      await chapter(kid);
      await chapter(renamed);
      final other = await chapter(slav);
      writeRows([kid]);
      // Both paths hold a chapter and neither is the file the note
      // describes, so nothing says which one the rows should name.
      await notes.record(
        'ambiguous',
        from: kid.path,
        to: renamed.path,
        identity: 'a file that is nowhere',
        folder: false,
      );

      expect(
        await restarted().rename(slav, 'Other.pgn', expected: other),
        isA<Moved>(),
      );

      expect(read(), contains(_row(kid.path)));
      expect(await notes.read(), isEmpty);
      expect(await setAside('ambiguous'), isTrue);
    },
  );

  test(
    'a note for a move that landed is finished by the next relocation',
    () async {
      final kid = fixture.ref('repertoires/KID/Main.pgn');
      final slav = fixture.ref('repertoires/Slav/Main.pgn');
      await chapter(kid);
      final identity = await identityOf(kid);
      final other = await chapter(slav);
      final renamed = fixture.ref('repertoires/KID/Renamed.pgn');
      writeRows([kid]);
      // The rename by hand, so nothing rewrote the rows with it.
      await File(kid.path).rename(renamed.path);
      await notes.record(
        'landed',
        from: kid.path,
        to: renamed.path,
        identity: identity,
        folder: false,
      );

      await restarted().rename(slav, 'Other.pgn', expected: other);

      expect(read(), contains(_row(renamed.path)));
      expect(read(), isNot(contains(_row(kid.path))));
      expect(await notes.read(), isEmpty);
    },
  );

  test(
    'a landed move whose identity was replaced is set aside, not blocking',
    () async {
      final kid = fixture.ref('repertoires/KID/Main.pgn');
      final slav = fixture.ref('repertoires/Slav/Main.pgn');
      await chapter(kid);
      final identity = await identityOf(kid);
      final other = await chapter(slav);
      final renamed = fixture.ref('repertoires/KID/Renamed.pgn');
      writeRows([kid]);
      await File(kid.path).rename(renamed.path);
      await notes.record(
        'landed',
        from: kid.path,
        to: renamed.path,
        identity: identity,
        folder: false,
      );
      // The first autosave after the move publishes a new file under the
      // new name.
      await replaceFile(
        renamed.path,
        utf8.encode('[Event "x"]\n\n1. d4 d5 *\n'),
      );
      expect(await identityOf(renamed), isNot(identity));

      expect(
        await restarted().rename(slav, 'Other.pgn', expected: other),
        isA<Moved>(),
      );

      expect(read(), contains(_row(kid.path)));
      expect(await notes.read(), isEmpty);
      expect(await setAside('landed'), isTrue);
    },
  );

  test(
    'an unperformed move whose identity was replaced is set aside',
    () async {
      final kid = fixture.ref('repertoires/KID/Main.pgn');
      final slav = fixture.ref('repertoires/Slav/Main.pgn');
      await chapter(kid);
      final identity = await identityOf(kid);
      final other = await chapter(slav);
      writeRows([kid]);
      // The machine stopped after the note, before the rename; the chapter
      // was saved where it still is.
      await notes.record(
        'stopped-early',
        from: kid.path,
        to: fixture.ref('repertoires/KID/Renamed.pgn').path,
        identity: identity,
        folder: false,
      );
      await replaceFile(kid.path, utf8.encode('[Event "x"]\n\n1. d4 d5 *\n'));
      expect(await identityOf(kid), isNot(identity));

      expect(
        await restarted().rename(slav, 'Other.pgn', expected: other),
        isA<Moved>(),
      );

      expect(read(), contains(_row(kid.path)));
      expect(await notes.read(), isEmpty);
      expect(await setAside('stopped-early'), isTrue);
    },
  );

  test(
    'rows a session could not write are finished by the next session',
    () async {
      final kid = fixture.ref('repertoires/KID/Main.pgn');
      final benko = fixture.ref('repertoires/Benko/Main.pgn');
      final slav = fixture.ref('repertoires/Slav/Main.pgn');
      await chapter(kid);
      final second = await chapter(benko);
      final third = await chapter(slav);
      writeRows([kid, benko, slav]);

      // An older supported v2 build left its original four-field note after
      // moving the PGN. The new owner must finish that protocol before starting.
      final moved = fixture.ref('repertoires/KID/A.pgn');
      final identity = await identityOf(kid);
      await notes.record(
        'older-move',
        from: kid.path,
        to: moved.path,
        identity: identity,
        folder: false,
      );
      await File(kid.path).rename(moved.path);
      await Process.run('chmod', ['a-w', fixture.documents.path]);
      final two = await restarted().rename(benko, 'B.pgn', expected: second);
      await Process.run('chmod', ['u+w', fixture.documents.path]);

      expect(two, isA<IoFailure>());
      expect(
        await notes.read(),
        hasLength(1),
        reason: 'a write that failed is kept for the next session',
      );

      await restarted().rename(slav, 'C.pgn', expected: third);

      final rows = read();
      expect(rows, contains(_row(fixture.ref('repertoires/KID/A.pgn').path)));
      expect(rows, contains(_row(benko.path)));
      expect(rows, contains(_row(fixture.ref('repertoires/Slav/C.pgn').path)));
      expect(await notes.read(), isEmpty);
    },
    skip: _needsAPlainUser,
  );

  test('a folder move that stopped half way is finished by identity', () async {
    final kid = fixture.ref('repertoires/KID/Main.pgn');
    final slav = fixture.ref('repertoires/Slav/Main.pgn');
    await chapter(kid);
    final other = await chapter(slav);
    writeRows([kid]);
    final from = fixture.ref('repertoires/KID').path;
    final to = fixture.ref('repertoires/Kings Indian').path;
    final identity = (await observeDirectory(from)).identity!;
    await Directory(from).rename(to);
    await notes.record(
      'folder',
      from: from,
      to: to,
      identity: identity,
      folder: true,
    );

    await restarted().rename(slav, 'Other.pgn', expected: other);

    expect(read(), contains(_row(p.join(to, 'Main.pgn'))));
    expect(await notes.read(), isEmpty);
  });
}

final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;
