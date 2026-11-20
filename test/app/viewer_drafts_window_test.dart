import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/app/app.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:chess_auto_prep/storage/viewer_drafts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// The viewer's checkpoints of held edits, kept in a real folder, through
/// the app's own wiring: its tabs, its exit and its status bar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  final games = collectionRef('games');
  final other = collectionRef('other');

  setUp(() => support = Directory.systemTemp.createTempSync('viewer-drafts'));
  tearDown(() => support.deleteSync(recursive: true));

  /// One run of the app, its viewer checkpoints kept in [support], with
  /// `games` open in the viewer.
  Future<WindowFixture> start() async {
    final w = WindowFixture(
      viewerDrafts: ViewerDraftFiles(support),
      // What a real close allows: a checkpoint on a busy disk takes longer
      // than the fixture's usual 20 ms.
      exitWait: const Duration(seconds: 5),
    );
    for (final ref in [games, other]) {
      w.store.documents[ref] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
    }
    await w.parts.start();
    w.requests.switchTo(Mode.pgnViewer);
    await w.requests.openFile(games, game: 0);
    w.session.holdsEdits = true;
    return w;
  }

  List<File> files(String folder) {
    final dir = Directory(p.join(support.path, folder));
    if (!dir.existsSync()) return const [];
    return [
      for (final file in dir.listSync(recursive: true).whereType<File>())
        if (p.extension(file.path) == '.json') file,
    ];
  }

  List<File> checkpoints() => files(ViewerDraftFiles.folder);
  List<File> quarantined() => files(quarantineFolder);
  bool checkpointHas(String words) =>
      checkpoints().singleOrNull?.readAsStringSync().contains(words) ?? false;

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue);
  }

  test('viewer edits made just before the window closes are offered back '
      'the next time the file opens', () async {
    final first = await start();
    first.session.setComment(NodePath.of(const [0]), 'Closing note');
    expect(first.session.hasHeldEdits, isTrue);
    final exit = AppExit(
      guard: first.parts.exit,
      prepare: first.parts.prepareToClose,
      onCancelled: first.parts.resumeAfterClose,
      stopEngines: () async {},
      closeLog: () async {},
    );
    addTearDown(exit.closing.dispose);
    // Well inside the keeper's second.
    final response = await exit.leave();
    expect(first.question.asked, isEmpty);
    expect(response, AppExitResponse.exit);
    expect(checkpointHas('Closing note'), isTrue);
    first.dispose();

    final second = await start();
    addTearDown(second.dispose);
    await until(() => second.requests.statusAction != null);
    expect(second.requests.statusAction?.label, 'Restore unsaved edits');
  });

  test('edits left in a closed tab are offered when the file opens again, '
      'and are neither dropped nor written over unseen', () async {
    final w = await start();
    addTearDown(w.dispose);
    w.session.setComment(NodePath.of(const [0]), 'Parked note');
    await w.requests.openFile(other, game: 0);
    await w.requests.documents.close(games);
    expect(w.requests.documents.tabs.isOpen(games), isFalse);
    // The tab let go of the edits only once they were on disk.
    expect(checkpointHas('Parked note'), isTrue);

    // Opened again at once.
    await w.requests.openFile(games, game: 0);
    await until(() => w.requests.statusAction != null);
    expect(w.requests.statusAction!.label, 'Restore unsaved edits');

    // Going through the file's games leaves the checkpoint where it is.
    w.viewer.showGame(1);
    w.viewer.showGame(0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(checkpointHas('Parked note'), isTrue);

    // New edits in its place set it aside whole first.
    w.session.setComment(NodePath.of(const [0]), 'Fresh note');
    await w.parts.exit.mayClose();
    expect(checkpointHas('Fresh note'), isTrue);
    expect(quarantined().single.readAsStringSync(), contains('Parked note'));
  });

  test('closing a parked tab preserves its note after another window '
      'checkpoints the same PGN', () async {
    final parked = await start();
    addTearDown(parked.dispose);
    final editing = await start();
    addTearDown(editing.dispose);
    final documents = parked.requests.documents;
    final editingDrafts = editing.requests.documents.drafts!;
    final move = NodePath.of(const [0]);
    const note = 'Note from the parked tab';

    editing.session.setComment(move, 'First note from the other window');
    expect(await editingDrafts.settle(), isNull);

    parked.session.setComment(move, note);
    await parked.requests.openFile(other, game: 0);
    expect(parked.session.source, other);
    expect(await documents.drafts!.settle(), isNull);

    editing.session.setComment(move, 'Revised note from the other window');
    expect(await editingDrafts.settle(), isNull);
    expect(await parked.parts.exit.mayClose(), isTrue);
    expect(
      quarantined().map((f) => f.readAsStringSync()),
      contains(contains(note)),
    );
    expect(checkpointHas('Revised note from the other window'), isTrue);
    await documents.close(games);

    if (documents.tabs.isOpen(games)) {
      await documents.select(games);
      expect(parked.session.commentAt(move), note);
      await documents.drafts!.settle();
    } else {
      final copies = [...checkpoints(), ...quarantined()];
      expect(
        copies.map((file) => file.readAsStringSync()),
        contains(contains(note)),
      );
    }
  });

  test('the former tab can close after its held note moves', () async {
    final w = await start();
    addTearDown(w.dispose);
    final documents = w.requests.documents;
    final renamed = collectionRef('renamed');
    w.session.setComment(NodePath.of(const [0]), 'Note follows the file');
    expect(await documents.drafts!.settle(), isNull);
    w.store.documents[renamed] = w.store.documents.remove(games)!;
    w.session.relocated(renamed);
    await documents.close(games);
    expect(documents.tabs.isOpen(games), isFalse);
    expect(w.session.source, renamed);
    expect(await documents.drafts!.settle(), isNull);
    final disk = ViewerDraftFiles(support);
    expect(await disk.find(games.path), isNull);
    expect(
      (await disk.find(renamed.path))?.text,
      contains('Note follows the file'),
    );
  });

  test('a parked tab reads the note saved by the restoring window', () async {
    final w = await start();
    addTearDown(w.dispose);
    final documents = w.requests.documents;
    final move = NodePath.of(const [0]);
    w.session.setComment(move, 'Already saved');
    await w.requests.openFile(other, game: 0);
    expect(await documents.drafts!.settle(), isNull);

    final editing = await start();
    addTearDown(editing.dispose);
    final keeper = editing.requests.documents.drafts!;
    await keeper.settle();
    await keeper.restore();
    expect(editing.session.hasHeldEdits, isTrue);
    editing.session.keepHeld();
    expect(await editing.parts.exit.mayClose(), isTrue);
    expect(await keeper.settle(), isNull);
    expect(checkpoints(), isEmpty);
    // Both windows read the same committed PGN in the app.
    w.store.documents[games] = editing.store.documents[games]!;
    await documents.select(games);
    expect(w.session.commentAt(move), 'Already saved');
    expect(w.session.hasHeldEdits, isFalse);
    expect(w.requests.statusAction, isNull);
  });

  test('a temporarily unavailable checkpoint can still offer a copy when '
      'the file reopens', () async {
    final w = await start();
    addTearDown(w.dispose);
    final documents = w.requests.documents;
    w.session.setComment(NodePath.of(const [0]), 'Parked note');
    await w.requests.openFile(other, game: 0);
    expect(await documents.drafts!.settle(), isNull);
    final checkpoint = checkpoints().single;
    final away = await checkpoint.rename('${checkpoint.path}.away');
    await documents.close(games);
    expect(documents.tabs.isOpen(games), isFalse);
    await away.rename(checkpoint.path);
    final changed = threeGameFile.replaceFirst('3. Bb5', '3. Bc4');
    w.store.documents[games] = Opened(changed, scriptedRevision(changed));
    await w.requests.openFile(games, game: 0);
    await documents.drafts!.settle();
    expect(w.session.hasHeldEdits, isFalse);
    expect(w.requests.statusAction?.label, 'Save them as a copy');
  });

  test('edits parked in a tab come back with it and carry on in their own '
      'checkpoint', () async {
    final w = await start();
    addTearDown(w.dispose);
    w.session.setComment(NodePath.of(const [0]), 'Parked note');
    await w.requests.openFile(other, game: 0);
    await until(() => checkpointHas('Parked note'));

    await w.requests.documents.select(games);
    expect(w.session.hasHeldEdits, isTrue);
    expect(w.requests.statusAction, isNull);
    w.session.setComment(NodePath.of(const [0]), 'Parked note, more');
    await w.parts.exit.mayClose();
    expect(checkpointHas('more'), isTrue);
    expect(quarantined(), isEmpty);
  });

  test('edits parked in a tab are not put back over a file that changed '
      'since: their checkpoint offers them as a copy', () async {
    final w = await start();
    addTearDown(w.dispose);
    w.session.setComment(NodePath.of(const [0]), 'Parked note');
    w.session.cursor.forward();
    final cursor = w.session.cursor.value;
    await w.requests.openFile(other, game: 0);
    await until(() => checkpointHas('Parked note'));
    final changed = threeGameFile.replaceFirst(
      '[Event ',
      '[Site "Updated elsewhere"]\n[Event ',
    );
    w.store.documents[games] = Opened(changed, scriptedRevision(changed));

    await w.requests.documents.select(games);
    expect(w.session.source, games);
    expect(w.session.cursor.value, cursor);
    expect(w.session.hasHeldEdits, isFalse);
    expect(
      w.session.tree!.mainLine.first.comment ?? '',
      isNot(contains('Parked note')),
    );
    await until(() => w.requests.statusAction != null);
    expect(w.requests.statusAction!.label, 'Save them as a copy');
    expect(checkpointHas('Parked note'), isTrue);

    // A copy that cannot be written is said as a problem.
    w.store.creates.add(const IoFailure('Disk full'));
    w.requests.statusAction!.onPressed();
    await until(() => w.requests.status?.contains('Disk full') ?? false);
    expect(w.requests.statusIsProblem, isTrue);

    // Visiting another tab and back does not bring the old draft back.
    await w.requests.documents.select(other);
    await w.requests.documents.select(games);
    expect(w.session.hasHeldEdits, isFalse);
    expect(w.store.requestedSaves, isEmpty);
  });

  test('a tab closed on edits whose checkpoint cannot be written stays open '
      'with them', () async {
    // A file where the checkpoint folder goes: no checkpoint can be written.
    File(p.join(support.path, ViewerDraftFiles.folder)).writeAsStringSync('');
    final w = await start();
    addTearDown(w.dispose);
    w.session.setComment(NodePath.of(const [0]), 'Parked note');
    await w.requests.openFile(other, game: 0);
    await w.requests.documents.close(games);
    expect(w.requests.documents.tabs.isOpen(games), isTrue);
    expect(w.requests.status, contains('games'));

    await w.requests.documents.select(games);
    expect(w.session.hasHeldEdits, isTrue);
    expect(w.session.tree!.mainLine.first.comment, contains('Parked note'));
  });

  test('leaving the window writes the checkpoint without waiting for its '
      'second', () async {
    final w = await start();
    addTearDown(w.dispose);
    w.session.setComment(NodePath.of(const [0]), 'Hidden note');
    w.parts.windowLeft();
    final clock = Stopwatch()..start();
    while (!checkpointHas('Hidden note') &&
        clock.elapsed < const Duration(milliseconds: 600)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(checkpointHas('Hidden note'), isTrue);
  });
}
