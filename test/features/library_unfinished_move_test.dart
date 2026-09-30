import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/library/file_changes.dart';
import 'package:chess_auto_prep/features/library/library.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';

/// A rename, folder rename or delete of the open chapter that the store
/// recorded and could not finish: the recovery gate carries it out at a
/// later access, and the workspace follows it then, so the next autosave
/// lands in the file where it now is rather than stopping, as a conflict, at
/// the name the file left.
void main() {
  late Directory documents;
  late Directory support;
  late PgnFileStore store;
  late Library library;
  late DocumentSession session;
  late DocumentSaver saver;
  late DateTime now;

  /// The steps the next relocations stop at, each once; [always] stops
  /// at its step every time.
  final stops = <FileRelocationStep>[];
  FileRelocationStep? always;

  String at(String relative) => p.join(documents.path, relative);

  RepertoireFolder named(String name) =>
      library.repertoires.firstWhere((folder) => folder.name == name);

  ChapterRef chapter(String repertoire, String name) =>
      named(repertoire).chapters.firstWhere((c) => c.name == name);

  setUp(() async {
    stops.clear();
    always = null;
    now = DateTime.utc(2026, 9, 30, 12);
    documents = await Directory.systemTemp.createTemp('v2-unfinished-');
    support = await Directory.systemTemp.createTemp('v2-unfinished-support-');
    final root = p.join(documents.path, 'repertoires');
    store = PgnFileStore(
      documents: documents,
      support: support,
      recoveryClock: () => now,
      relocationHook: (step) async {
        if (step == always || stops.remove(step)) {
          throw const FileSystemException('held open');
        }
      },
    );
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    final files = ChapterDirectory(Directory(root), recovery: store.recovery);
    library = libraryOver(files, store, session, saver, root: root);
    File(at('repertoires/KID/Main.pgn'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '// KID\n// Color: Black\n\n[Event "Main"]\n\n1. d4 Nf6 2. c4 g6 *\n',
      );
    await library.refresh();
    await session.open(chapter('KID', 'Main'));
  });

  tearDown(() async {
    library.dispose();
    session.dispose();
    saver.dispose();
    await documents.delete(recursive: true);
    await support.delete(recursive: true);
  });

  /// Annotates the open chapter and lets the autosave run.
  Future<void> annotate(String words) async {
    session.setComment(NodePath.of([0]), words);
    await saver.flush();
    await saver.flush();
  }

  String text(String relative) => File(at(relative)).readAsStringSync();

  /// The library's own owner of file changes, without the catalog read that
  /// follows each library command: the first access after the change is
  /// the autosave's.
  FileChanges changes() =>
      FileChanges(store: store, saver: saver, session: session);

  test('a rename the store recorded is followed before the next autosave '
      'goes out', () async {
    stops.add(FileRelocationStep.intent);
    final renamed = await library.renameChapter(
      chapter('KID', 'Main'),
      'Mainline',
    );
    expect(renamed, isA<LibraryUnfinished>());

    await annotate('typed after the rename');

    expect(saver.state, isA<Saved>());
    expect(session.source?.path, at('repertoires/KID/Mainline.pgn'));
    expect(
      text('repertoires/KID/Mainline.pgn'),
      contains('typed after the rename'),
    );
    expect(File(at('repertoires/KID/Main.pgn')).existsSync(), isFalse);
  });

  test('an autosave that meets the rename the gate just carried out goes to '
      'the new name', () async {
    stops.add(FileRelocationStep.intent);
    final open = session.source!;
    final moved = await changes().move(
      open,
      DocumentRef(at('repertoires/KID/Mainline.pgn')),
    );
    expect(moved, isA<LibraryUnfinished>());
    expect(session.source, open, reason: 'nothing has moved yet');
    expect(saver.settled, isTrue, reason: 'exit need not ask about it');

    await annotate('typed while it was recorded');

    expect(saver.state, isA<Saved>());
    expect(session.source?.path, at('repertoires/KID/Mainline.pgn'));
    expect(
      text('repertoires/KID/Mainline.pgn'),
      contains('typed while it was recorded'),
    );
    expect(File(at('repertoires/KID/Main.pgn')).existsSync(), isFalse);
  });

  test(
    'a rename whose file landed but whose books did not is followed',
    () async {
      stops.add(FileRelocationStep.books);
      final renamed = await library.renameChapter(
        chapter('KID', 'Main'),
        'Mainline',
      );
      expect(renamed, isA<LibraryUnfinished>());

      await annotate('typed after the file moved');

      expect(saver.state, isA<Saved>());
      expect(session.source?.path, at('repertoires/KID/Mainline.pgn'));
      expect(
        text('repertoires/KID/Mainline.pgn'),
        contains('typed after the file moved'),
      );
    },
  );

  test(
    'a delete the store recorded closes the chapter, never a conflict',
    () async {
      stops.add(FileRelocationStep.intent);
      final deleted = await library.deleteChapter(chapter('KID', 'Main'));
      expect(deleted, isA<LibraryUnfinished>());

      await annotate('typed after the delete');

      expect(saver.state, isNot(isA<SaveConflict>()));
      expect(session.source, isNull);
      expect(File(at('repertoires/KID/Main.pgn')).existsSync(), isFalse);
    },
  );

  test('a folder rename the store recorded is followed into the new '
      'folder', () async {
    stops.add(FileRelocationStep.intent);
    final renamed = await library.renameRepertoire(named('KID'), 'KID2');
    expect(renamed, isA<LibraryUnfinished>());

    await annotate('typed after the folder moved');

    expect(saver.state, isA<Saved>());
    expect(session.source?.path, at('repertoires/KID2/Main.pgn'));
    expect(
      text('repertoires/KID2/Main.pgn'),
      contains('typed after the folder moved'),
    );
  });

  test('a delete that lands after words were typed keeps them on the '
      'screen', () async {
    stops.add(FileRelocationStep.intent);
    final open = session.source!;
    final deleted = await changes().delete(open);
    expect(deleted, isA<LibraryUnfinished>());

    await annotate('typed after the delete');

    expect(File(at('repertoires/KID/Main.pgn')).existsSync(), isFalse);
    expect(session.source, open, reason: 'not closed over unsaved words');
    expect(session.tree!.nodeAt(NodePath.of([0]))!.comment, contains('typed'));
    expect(saver.state, isA<SaveConflict>());
    expect(saver.settled, isFalse);
  });

  test('a write out while the document is followed to its new name goes '
      'there', () async {
    final canonical = await Directory(at('repertoires')).resolveSymbolicLinks();
    final release = Completer<void>();
    final holding = Completer<void>();
    final held = withDirectoryLock(
      Directory(p.join(canonical, '.cap-directory-domain')),
      () async {
        holding.complete();
        await release.future;
      },
    );
    await holding.future;
    session.setComment(NodePath.of([0]), 'typed during the follow');
    while (saver.state is! Saving) {
      await Future<void>.delayed(Duration.zero);
    }
    // The write to Main is waiting for the profile; the move lands and the
    // workspace follows it before the write gets there.
    File(
      at('repertoires/KID/Main.pgn'),
    ).renameSync(at('repertoires/KID/Mainline.pgn'));
    session.relocated(ChapterRef.at(at('repertoires/KID/Mainline.pgn')));
    release.complete();
    await held;
    await saver.flush();
    await saver.flush();

    expect(saver.state, isA<Saved>());
    expect(
      text('repertoires/KID/Mainline.pgn'),
      contains('typed during the follow'),
    );
    expect(File(at('repertoires/KID/Main.pgn')).existsSync(), isFalse);
  });

  test('a folder rename the gate sets aside is never carried out later from '
      'here', () async {
    stops.add(FileRelocationStep.intent);
    final owner = changes();
    final renamed = await owner.renameFolder(
      at('repertoires/KID'),
      at('repertoires/KID2'),
    );
    expect(renamed, isA<LibraryUnfinished>());
    // Something else takes the new name, so the gate sets the move aside.
    File(at('repertoires/KID2/Other.pgn'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// other\n');
    await annotate('typed after it was set aside');
    expect(saver.state, isA<Saved>());
    expect(text('repertoires/KID/Main.pgn'), contains('set aside'));

    // Later the name is free again and the open file goes by other means.
    Directory(at('repertoires/KID2')).deleteSync(recursive: true);
    File(at('repertoires/KID/Main.pgn')).deleteSync();
    expect(await owner.followPending(), isFalse);

    expect(Directory(at('repertoires/KID')).existsSync(), isTrue);
    expect(Directory(at('repertoires/KID2')).existsSync(), isFalse);
  });

  test('a rename whose file landed but did not settle lets the draft land '
      'once the gate stops guarding it', () async {
    always = FileRelocationStep.document;
    final renamed = await library.renameChapter(
      chapter('KID', 'Main'),
      'Mainline',
    );
    expect(renamed, isA<LibraryUnfinished>());

    await annotate('typed while the books wait');
    // Refused while the gate guards the file: kept, and not a conflict.
    expect(saver.state, isA<SaveFailed>());
    expect(saver.settled, isFalse);

    now = now.add(const Duration(minutes: 6));
    await saver.flush();
    await saver.flush();

    expect(saver.state, isA<Saved>());
    expect(session.source?.path, at('repertoires/KID/Mainline.pgn'));
    expect(
      text('repertoires/KID/Mainline.pgn'),
      contains('typed while the books wait'),
    );
  });

  test('a rename the gate sets aside leaves the autosave writing where the '
      'file still is', () async {
    stops.add(FileRelocationStep.intent);
    final open = session.source!;
    final owner = changes();
    final moved = await owner.move(
      open,
      DocumentRef(at('repertoires/KID/Mainline.pgn')),
    );
    expect(moved, isA<LibraryUnfinished>());
    // Something else takes the new name before the gate finishes the move.
    File(at('repertoires/KID/Mainline.pgn')).writeAsStringSync('// other\n');

    await annotate('typed after it was set aside');

    expect(saver.state, isA<Saved>());
    expect(session.source, open);
    expect(
      text('repertoires/KID/Main.pgn'),
      contains('typed after it was set aside'),
    );
    expect(text('repertoires/KID/Mainline.pgn'), '// other\n');
    expect(await owner.followPending(), isFalse);
  });
}
