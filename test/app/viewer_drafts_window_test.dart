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
    await w.requests.openFile(other, game: 0);
    await until(() => checkpointHas('Parked note'));
    final changed = threeGameFile.replaceFirst(
      '[Event ',
      '[Site "Updated elsewhere"]\n[Event ',
    );
    w.store.documents[games] = Opened(changed, scriptedRevision(changed));

    await w.requests.documents.select(games);
    expect(w.session.source, games);
    expect(w.session.hasHeldEdits, isFalse);
    expect(
      w.session.tree!.mainLine.first.comment ?? '',
      isNot(contains('Parked note')),
    );
    await until(() => w.requests.statusAction != null);
    expect(w.requests.statusAction!.label, 'Save them as a copy');
    expect(checkpointHas('Parked note'), isTrue);

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
