import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' hide Saved;
import 'package:chess_auto_prep/storage/viewer_drafts.dart';
import 'package:chess_auto_prep/ui/status_bar.dart' show StatusAction;
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:chess_auto_prep/workspace/draft_keeper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

/// One run of the app over the file: a session showing it game by game,
/// with the viewer's held edits, and the keeper watching it.
final class _Run {
  _Run(
    PgnDocumentStore store,
    ViewerDrafts drafts, {
    Duration delay = const Duration(milliseconds: 5),
  }) {
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver)..holdsEdits = true;
    keeper = DraftKeeper(
      session: session,
      saver: saver,
      drafts: drafts,
      say: (sentence, {action, problem = true}) => said.add((sentence, action)),
      delay: delay,
    )..start();
  }

  late final DocumentSaver saver;
  late final DocumentSession session;
  late final DraftKeeper keeper;
  final said = <(String?, StatusAction?)>[];

  StatusAction? get offer => said.lastOrNull?.$2;

  /// The process ends here: nothing is saved.
  void kill() {
    keeper.dispose();
    session.dispose();
    saver.dispose();
  }
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  late Directory support;
  late ScriptedDocumentStore store;
  final ref = collectionRef('games');

  setUp(() {
    support = Directory.systemTemp.createTempSync('draft-keeper');
    store = ScriptedDocumentStore()
      ..documents[ref] = Opened(threeGameFile, scriptedRevision(threeGameFile));
  });
  tearDown(() => support.deleteSync(recursive: true));

  String onDisk() => (store.documents[ref]! as Opened).text;

  test('killed before saving, the edits are offered when the file opens '
      'again, restored as held edits and dropped once saved', () async {
    final drafts = ViewerDraftFiles(support);
    final first = _Run(store, drafts);
    await first.session.open(ref, game: 1);
    first.session
      ..goTo(NodePath.of(const [0, 0, 0, 0]))
      ..playMove('b1c3');
    expect(first.session.hasHeldEdits, isTrue);
    await until(() => Directory('${support.path}/viewer-drafts').existsSync());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.kill();
    expect(onDisk(), threeGameFile, reason: 'nothing reached the file');

    final second = _Run(store, ViewerDraftFiles(support));
    await second.session.open(ref, game: 0);
    await until(() => second.offer != null);
    expect(second.offer!.label, 'Restore unsaved edits');
    expect(second.said.last.$1, contains('earlier session'));
    second.offer!.onPressed();
    await until(() => second.session.hasHeldEdits);
    expect(second.session.game, 1, reason: 'back on the game edited');
    expect(second.session.tree!.mainLine.map((m) => m.san), [
      'd4',
      'Nf6',
      'c4',
      'e6',
      'Nc3',
    ]);
    expect(second.said.last.$1, isNull, reason: 'the offer is taken down');

    second.session.keepHeld();
    await until(() => onDisk().contains('Nc3'));
    await until(() => !File(_draftPath(support)).existsSync());
    expect(
      Directory('${support.path}/recovery-quarantine').existsSync(),
      isFalse,
      reason: 'the restored edits were the checkpoint, not newer ones',
    );
    second.kill();
  });

  test('discarding the edits forgets their copy', () async {
    final drafts = _MemoryDrafts();
    final run = _Run(store, drafts);
    await run.session.open(ref, game: 0);
    run.session.setComment(NodePath.of(const [0]), 'A note');
    await until(() => drafts.kept.isNotEmpty);
    run.session.discardHeld();
    await until(() => drafts.kept.isEmpty);
    run.kill();
  });

  test('new edits on a file with an offered draft set the old one aside, '
      'whole', () async {
    final drafts = _MemoryDrafts()
      ..kept[ref.path] = ViewerDraft(
        path: ref.path,
        game: 0,
        revision: scriptedRevision(threeGameFile),
        text: threeGameFile.replaceFirst('3. Bb5', '3. Bc4'),
      );
    final run = _Run(store, drafts);
    await run.session.open(ref, game: 0);
    await until(() => run.offer != null);
    run.session.setComment(NodePath.of(const [0]), 'Newer');
    expect(run.keeper.offered, isNull);
    await until(() => drafts.kept[ref.path]?.text.contains('Newer') ?? false);
    expect(drafts.setAsideFor, [ref.path], reason: 'before the newer copy');
    run.kill();
  });

  group('on disk', () {
    late StoreFixture disk;
    late ChapterRef games;
    late ChapterRef other;

    setUp(() async {
      disk = await StoreFixture.create();
      games = ChapterRef.at(
        p.join(disk.documents.path, 'pgn_collections', 'games.pgn'),
      );
      other = ChapterRef.at(
        p.join(disk.documents.path, 'pgn_collections', 'other.pgn'),
      );
      await disk.put(games, threeGameFile);
      await disk.put(other, threeGameFile);
    });
    tearDown(() => disk.dispose());

    _Run run({Duration delay = const Duration(hours: 1)}) =>
        _Run(disk.store, ViewerDraftFiles(disk.support), delay: delay);

    String fileText(ChapterRef ref) => File(ref.path).readAsStringSync();
    List<File> draftFiles() => _checkpoints(disk.support);

    List<File> quarantined() {
      final folder = Directory(p.join(disk.support.path, quarantineFolder));
      return folder.existsSync()
          ? folder.listSync(recursive: true).whereType<File>().toList()
          : const [];
    }

    test('an edit made just before the window closes is kept: settling '
        'writes it before its second is up', () async {
      final first = run();
      await first.session.open(games, game: 0);
      first.session.setComment(NodePath.of(const [0]), 'Last second');
      expect(await first.keeper.settle(), isNull);
      expect(draftFiles(), hasLength(1));
      first.kill();
      expect(fileText(games), threeGameFile);

      final second = run();
      await second.session.open(games, game: 0);
      await until(() => second.offer != null);
      expect(second.offer!.label, 'Restore unsaved edits');
      second.kill();
    });

    test('taking the keeper down writes what is waiting', () async {
      final first = run();
      await first.session.open(games, game: 0);
      first.session.setComment(NodePath.of(const [0]), 'On the way down');
      first.kill();
      await until(() => draftFiles().isNotEmpty);
      expect(draftFiles().single.readAsStringSync(), contains('way down'));
    });

    test('a checkpoint that could not be written is named when settling, '
        'so the window asks before closing on the edits', () async {
      final app = _Run(
        disk.store,
        _RefusingDrafts(),
        delay: const Duration(hours: 1),
      );
      await app.session.open(games, game: 0);
      app.session.setComment(NodePath.of(const [0]), 'Nowhere to go');
      expect(await app.keeper.settle(), contains('games.pgn'));
      app.kill();
    });

    test('a checkpoint left behind by a closed tab is offered when its file '
        'opens again, and is neither dropped nor overwritten unseen', () async {
      final app = run(delay: const Duration(milliseconds: 5));
      await app.session.open(games, game: 0);
      app.session.setComment(NodePath.of(const [0]), 'Parked note');
      // Another tab: the edits are parked there, then the tab is closed.
      await app.session.open(other, game: 0);
      await until(() => draftFiles().isNotEmpty);

      await app.session.open(games, game: 0);
      await until(() => app.offer != null);
      expect(app.offer!.label, 'Restore unsaved edits');
      expect(app.said.last.$1, isNot(contains('earlier session')));
      // Stepping to another game of the file keeps it.
      await app.session.open(games, game: 1);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(draftFiles(), hasLength(1));
      expect(draftFiles().single.readAsStringSync(), contains('Parked note'));

      // New edits set it aside whole before they take its place.
      await until(() => app.offer != null);
      app.session.setComment(NodePath.of(const [0]), 'Fresh note');
      await until(
        () =>
            draftFiles().singleOrNull?.readAsStringSync().contains(
              'Fresh note',
            ) ??
            false,
      );
      expect(draftFiles().single.readAsStringSync(), isNot(contains('Parked')));
      expect(quarantined().single.readAsStringSync(), contains('Parked note'));
      app.kill();
    });

    test('opening another game of the file holding edits keeps the edits '
        'and their checkpoint', () async {
      final app = run(delay: const Duration(milliseconds: 5));
      await app.session.open(games, game: 0);
      app.session.setComment(NodePath.of(const [0]), 'Held note');
      await until(() => draftFiles().isNotEmpty);
      await app.session.open(games, game: 1);
      await app.keeper.settle();
      expect(app.session.hasHeldEdits, isTrue);
      expect(app.session.game, 1);
      expect(draftFiles().single.readAsStringSync(), contains('Held note'));
      app.kill();
    });

    test('a reread of the same file that drops held edits leaves their '
        'checkpoint and offers it back', () async {
      final app = run(delay: const Duration(milliseconds: 5));
      await app.session.open(games, game: 0);
      app.session.setComment(NodePath.of(const [0]), 'Held note');
      await until(() => draftFiles().isNotEmpty);
      // Merged, not one game at a time: the file is read again.
      await app.session.open(games);
      await app.keeper.settle();
      expect(app.session.hasHeldEdits, isFalse);
      expect(draftFiles().single.readAsStringSync(), contains('Held note'));
      await app.session.open(games, game: 0);
      await until(() => app.offer != null);
      expect(app.offer!.label, 'Restore unsaved edits');
      app.kill();
    });

    test('a file opened again at once, before the checkpoint its edits '
        'left is written, is still offered it', () async {
      final app = run();
      await app.session.open(games, game: 0);
      app.session.setComment(NodePath.of(const [0]), 'Parked note');
      // Leaving the file queues its checkpoint; it opens again without
      // waiting for the write.
      await app.session.open(other, game: 0);
      await app.session.open(games, game: 0);
      await until(() => app.offer != null);
      expect(app.offer!.label, 'Restore unsaved edits');
      app.kill();
    });

    test('edits parked in a tab and brought back by it replace their own '
        'checkpoint without setting it aside', () async {
      final app = run(delay: const Duration(milliseconds: 5));
      await app.session.open(games, game: 0);
      app.session.setComment(NodePath.of(const [0]), 'Parked note');
      final parked = app.session.retainedDraft!;
      await app.session.open(other, game: 0);
      await until(() => draftFiles().isNotEmpty);
      await app.session.open(games, game: 0);
      app.session.restoreDraft(parked);
      app.session.setComment(NodePath.of(const [0, 0]), 'More');
      await until(
        () => draftFiles().single.readAsStringSync().contains('More'),
      );
      expect(quarantined(), isEmpty);
      app.kill();
    });

    test('a draft of a file changed since is saved as a copy, not restored '
        'over it, and the file still takes saves', () async {
      final first = run();
      await first.session.open(games, game: 0);
      first.session.setComment(NodePath.of(const [0]), 'Old draft note');
      await first.keeper.settle();
      first.kill();
      final changed = threeGameFile.replaceFirst('3. Bb5', '3. Bc4');
      await disk.replace(games, changed, await disk.revisionOf(games));

      final second = run();
      await second.session.open(games, game: 0);
      await until(() => second.offer != null);
      expect(second.said.last.$1, contains('changed since'));
      expect(second.offer!.label, 'Save them as a copy');
      second.offer!.onPressed();
      await until(() => second.said.last.$1?.startsWith('Saved') ?? false);
      final copy = File(
        p.join(p.dirname(games.path), 'games unsaved edits.pgn'),
      );
      expect(copy.readAsStringSync(), contains('Old draft note'));
      expect(second.session.hasHeldEdits, isFalse);
      expect(fileText(games), changed);
      await until(() => draftFiles().isEmpty);

      second.session.setComment(NodePath.of(const [0]), 'New note');
      second.session.keepHeld();
      await until(() => fileText(games).contains('New note'));
      expect(fileText(games), contains('Bc4'));
      // The file lands a moment before the saver says so.
      await until(() => second.saver.state is Saved);
      second.kill();
    });
  });
}

String _draftPath(Directory support) {
  final files = _checkpoints(support);
  return files.isEmpty
      ? p.join(support.path, ViewerDraftFiles.folder, 'none')
      : files.single.path;
}

/// The checkpoints written whole; a write still staged is not one yet.
List<File> _checkpoints(Directory support) {
  final folder = Directory(p.join(support.path, ViewerDraftFiles.folder));
  if (!folder.existsSync()) return const [];
  return [
    for (final file in folder.listSync().whereType<File>())
      if (p.extension(file.path) == '.json') file,
  ];
}

final class _MemoryDrafts implements ViewerDrafts {
  final kept = <String, ViewerDraft>{};
  final setAsideFor = <String>[];

  @override
  Future<void> keep(ViewerDraft draft) async => kept[draft.path] = draft;

  @override
  Future<ViewerDraft?> find(String path) async => kept[path];

  @override
  Future<void> drop(String path) async => kept.remove(path);

  @override
  Future<void> setAside(String path) async {
    setAsideFor.add(path);
    kept.remove(path);
  }
}

/// A disk that takes no checkpoint.
final class _RefusingDrafts implements ViewerDrafts {
  @override
  Future<void> keep(ViewerDraft draft) async =>
      throw const FileSystemException('disk full');

  @override
  Future<ViewerDraft?> find(String path) async => null;

  @override
  Future<void> drop(String path) async {}

  @override
  Future<void> setAside(String path) async {}
}
