import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/builder_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/infrastructure/documents/builder_workspace_codec.dart';
import 'package:chess_auto_prep/infrastructure/documents/file_workspace_recovery_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/isolate_repertoire_decoder.dart';
import 'repertoire_document_session_test.dart' show MemoryDocuments;
import '../../support/repertoire_dependencies.dart'
    show MemoryBuilderRecoveryStore, GatedRepertoireDecoder;

const pgn = '[Event "Original"]\n[Result "*"]\n\n1. e4 e5 *';
RepertoireMetadata chapter(String path) => RepertoireMetadata(
  filePath: path,
  name: path,
  lastModified: DateTime(2026),
);

class CopyDocuments extends MemoryDocuments {
  Completer<void>? saveGate;
  Completer<void>? appendStarted;
  PgnWriteResult? appendOutcome;
  int appendCalls = 0;
  @override
  Future<PgnWriteResult> appendPgn(String path, String content) async {
    appendCalls++;
    appendStarted?.complete();
    final opened = await read(path);
    if (opened is! PgnOpened) {
      return PgnWriteFailed(StateError('Missing destination'));
    }
    final before = opened.snapshot;
    await saveGate?.future;
    if (appendOutcome case final outcome?) return outcome;
    if (files[path] != before.content) return const PgnConflict(null);
    files[path] = '${before.content}\n\n$content\n';
    return PgnSaved(
      before: before,
      after: (await read(path) as PgnOpened).snapshot,
    );
  }

  @override
  Future<void> replace(
    String path,
    String content, {
    required String expectedContent,
  }) async {
    await saveGate?.future;
    if (files[path] != expectedContent) {
      throw StateError('Concurrent destination change');
    }
    files[path] = content;
  }
}

class SlowLineDocuments extends CopyDocuments {
  final firstStarted = Completer<void>();
  final firstGate = Completer<void>();
  final writes = <String>[];
  bool failLineWrites = false;
  @override
  Future<RepertoireLineSaveReceipt?> updateLineContent(
    String path,
    String lineId,
    String content, {
    required String expectedContent,
  }) async {
    writes.add(content);
    if (writes.length == 1) {
      firstStarted.complete();
      await firstGate.future;
    }
    if (failLineWrites) throw StateError('slow store unavailable');
    return super.updateLineContent(
      path,
      lineId,
      content,
      expectedContent: expectedContent,
    );
  }
}

class GatedRecoveryStore extends MemoryBuilderRecoveryStore {
  Future<void> Function(BuilderWorkspaceSnapshot)? beforeWrite;
  bool closed = false;
  @override
  Future<void> write(BuilderWorkspaceSnapshot value) async {
    expect(closed, isFalse);
    await beforeWrite?.call(value);
    await super.write(value);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CopyDocuments documents;
  BuilderWorkspaceController workspace() => BuilderWorkspaceController(
    checkpoint: () async {},
    documents: documents,
    decoder: const IsolateRepertoireDecoder(),
  );
  setUp(() {
    documents = CopyDocuments()..files['/a'] = pgn;
    documents.files['/b'] = pgn;
  });

  test(
    'capture is synchronous before editor debounce and preserves outgoing chapters',
    () async {
      final owner = workspace();
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(chapter('/a'));
      owner.composeMoves(['e4', 'e5']);
      owner.board.setCommentAtPath(const TreePath([0]), 'before debounce');
      owner.board.toggleNagAtPath(const TreePath([0]), 1);
      owner.setTitle('Scratch A');
      final capture = owner.captureWorkspace();
      expect(capture.drafts.single.content, contains('before debounce'));
      expect(capture.drafts.single.content, contains(r'$1'));
      await owner.document.setRepertoire(chapter('/b'));
      owner.composeMoves(['d4', 'd5']);
      owner.setTitle('Scratch B');
      final snapshot = owner.captureWorkspace();
      expect(
        snapshot.drafts.map((d) => d.title),
        containsAll(['Scratch A', 'Scratch B']),
      );
      final decoded = const BuilderWorkspaceCodec().decode(
        const BuilderWorkspaceCodec().encode(snapshot),
      );
      final restarted = workspace();
      addTearDown(restarted.dispose);
      await restarted.restoreWorkspace(decoded);
      expect(restarted.board.moveHistory, ['d4', 'd5']);
      final a = restarted.retainedDrafts.firstWhere(
        (d) => d.title == 'Scratch A',
      );
      await restarted.openRetainedDraft(a);
      expect(restarted.board.tree.toPgnMoveText(), contains('before debounce'));
      expect(
        restarted.retainedDrafts.any((d) => d.title == 'Scratch B'),
        isTrue,
      );
      expect(documents.files['/a'], pgn);
    },
  );

  test('opening a retained scratch supersedes an older chapter load', () async {
    final owner = workspace();
    addTearDown(owner.dispose);
    owner.composeMoves(['d4', 'd5']);
    final scratch = owner.captureWorkspace().drafts.single;
    expect(scratch.repertoire, isNull);
    documents.readGate = Completer<void>();
    documents.readStarted = Completer<void>();
    final loading = owner.document.setRepertoire(chapter('/a'));
    await documents.readStarted!.future;
    await owner.openRetainedDraft(scratch);
    documents.readGate!.complete();
    await loading;
    expect(owner.captureWorkspace().activeKey, scratch.key);
    expect(owner.board.moveHistory, ['d4', 'd5']);
    expect(owner.document.currentRepertoire, isNull);
  });

  test(
    'failed line save keeps draft and retry after failed switch remains bound to A',
    () async {
      final owner = workspace();
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(chapter('/a'));
      owner.selectLine(owner.document.repertoireLines.single);
      documents.files['/a'] = owner.document.repertoireLines.single.fullPgn;
      documents.failure = StateError('disk unavailable');
      owner.board.setCommentAtPath(const TreePath([0]), 'retry annotation');
      await expectLater(
        owner.document.flushDocumentForClose(),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(owner.saveError, isNotNull);
      expect(
        owner.captureWorkspace().drafts.single.content,
        contains('retry annotation'),
      );
      await owner.document.setRepertoire(chapter('/b'));
      expect(owner.document.currentRepertoire!.filePath, '/a');
      documents.failure = null;
      expect(await owner.saveActiveLine(), isTrue);
      expect(owner.saveError, isNull);
      expect(owner.captureWorkspace().needsRecovery, isFalse);
      expect(documents.files['/a'], contains('retry annotation'));
      expect(documents.files['/b'], pgn);
    },
  );

  test(
    'changed and missing source recovery never autosaves over external work',
    () async {
      final owner = workspace();
      await owner.document.setRepertoire(chapter('/a'));
      owner.selectLine(owner.document.repertoireLines.single);
      documents.files['/a'] = owner.document.repertoireLines.single.fullPgn;
      documents.failure = StateError('disk unavailable');
      owner.board.setCommentAtPath(const TreePath([0]), 'my draft');
      await expectLater(
        owner.document.flushDocumentForClose(),
        throwsStateError,
      );
      final snapshot = owner.captureWorkspace();
      owner.dispose();
      documents.failure = null;
      const external = '[Event "External"]\n\n1. d4 d5 *';
      documents.files['/a'] = external;
      final restarted = workspace();
      addTearDown(restarted.dispose);
      await restarted.restoreWorkspace(snapshot);
      expect(restarted.sourceChanged, isTrue);
      expect(restarted.document.selectedPgnLine, isNull);
      restarted.board.setCommentAtPath(const TreePath([0]), 'still mine');
      expect(await restarted.saveActiveLine(), isFalse);
      expect(documents.files['/a'], external);
      documents.files.remove('/a');
      await restarted.openRetainedDraft(snapshot.drafts.single);
      expect(restarted.board.tree.toPgnMoveText(), contains('my draft'));
      expect(await restarted.saveActiveLine(), isFalse);
      expect(documents.files.containsKey('/a'), isFalse);
    },
  );

  test(
    'checkpoint failure blocks close, retains previous checkpoint, then retries',
    () async {
      final store = MemoryBuilderRecoveryStore();
      final lifetime = BuilderLifetime(
        documents: documents,
        decoder: const IsolateRepertoireDecoder(),
        store: store,
      );
      lifetime.workspace.composeMoves(['e4']);
      await lifetime.recovery.flush();
      final previous = store.snapshot;
      store.failure = StateError('checkpoint disk full');
      lifetime.workspace.board.playMove('e5');
      await expectLater(lifetime.flushForClose(), throwsStateError);
      expect(store.snapshot, same(previous));
      expect(lifetime.recovery.writeError, isNotNull);
      store.failure = null;
      await lifetime.flushForClose();
      expect(store.snapshot!.drafts.single.content, contains('e5'));
      await lifetime.shutdown();
    },
  );

  test(
    'explicit copy preserves variations and headers, resolves only the copied draft',
    () async {
      final owner = workspace();
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(chapter('/a'));
      owner.composeMoves(['e4', 'e5']);
      owner.board.jump(TreePath.empty);
      owner.board.playMove('d4');
      owner.board.setCommentAtPath(owner.board.path, 'variation note');
      owner.setTitle('My "copy"');
      final draft = owner.captureWorkspace().drafts.single;
      final gate = documents.saveGate = Completer<void>();
      final copying = owner.saveDraftToChapter(draft, chapter('/b'));
      owner.setTitle('Newer edit');
      gate.complete();
      await copying;
      expect(documents.files['/b'], contains('variation note'));
      expect(documents.files['/b'], contains(r'My \"copy\"'));
      expect(documents.files['/a'], pgn);
      expect(owner.captureWorkspace().drafts.single.title, 'Newer edit');
      final latest = owner.captureWorkspace().drafts.single;
      await owner.saveDraftToChapter(latest, chapter('/b'));
      expect(owner.captureWorkspace().needsRecovery, isFalse);
    },
  );

  test(
    'unknown recovery schema and invalid cursor retain an error instead of adopting empty data',
    () async {
      expect(
        () => const BuilderWorkspaceCodec().decode({'version': 99}),
        throwsFormatException,
      );
      final owner = workspace();
      addTearDown(owner.dispose);
      final invalid = BuilderDraft(
        key: 'bad',
        repertoire: null,
        content: pgn,
        sourcePgn: null,
        lineId: null,
        linePgn: null,
        title: 'Bad',
        cursor: [99],
      );
      await expectLater(
        owner.restoreWorkspace(
          BuilderWorkspaceSnapshot(drafts: [invalid], activeKey: 'bad'),
        ),
        throwsFormatException,
      );
      expect(owner.board.tree.isEmpty, isTrue);
    },
  );

  test(
    'restoring a same-key checkpoint retains both versions of unsaved work',
    () async {
      final first = workspace();
      first.composeMoves(['e4']);
      first.setTitle('Older');
      final incoming = first.captureWorkspace();
      first.dispose();
      final current = workspace();
      addTearDown(current.dispose);
      current.composeMoves(['d4']);
      current.setTitle('Newer');
      await current.restoreWorkspace(incoming);
      expect(current.title, 'Older');
      expect(
        current.captureWorkspace().drafts.map((d) => d.title),
        containsAll(['Older', 'Newer']),
      );
    },
  );

  test(
    'newer chapter intent prevents a late restore from replacing its board',
    () async {
      final decoder = GatedRepertoireDecoder();
      final owner = BuilderWorkspaceController(
        checkpoint: () async {},
        documents: documents,
        decoder: decoder,
      );
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(chapter('/a'));
      owner.composeMoves(['e4']);
      final draft = owner.captureWorkspace().drafts.single;
      final gate = Completer<void>();
      decoder.beforeBuild = () => gate.future;
      final restoring = owner.openRetainedDraft(draft);
      final failed = expectLater(restoring, throwsStateError);
      final newer = owner.document.setRepertoire(chapter('/b'));
      gate.complete();
      await Future.wait([failed, newer]);
      expect(owner.document.currentRepertoire!.filePath, '/b');
      expect(owner.board.moveHistory, isEmpty);
      expect(
        owner.retainedDrafts.any((item) => item.content == draft.content),
        isTrue,
      );
    },
  );

  test(
    'copying a conflicted line resolves its failed writer without touching external source',
    () async {
      final owner = workspace();
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(chapter('/a'));
      owner.selectLine(owner.document.repertoireLines.single);
      const external = '[Event "External"]\n\n1. d4 *';
      documents.files['/a'] = external;
      owner.board.setCommentAtPath(const TreePath([0]), 'my recovered comment');
      await expectLater(
        owner.document.flushDocumentForClose(),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      final draft = owner.captureWorkspace().drafts.single;
      await owner.saveDraftToChapter(draft, chapter('/b'));
      await owner.document.setRepertoire(chapter('/b'));
      expect(owner.document.currentRepertoire!.filePath, '/b');
      expect(documents.files['/a'], external);
      expect(documents.files['/b'], contains('my recovered comment'));
      expect(owner.captureWorkspace().needsRecovery, isFalse);
    },
  );

  test(
    'cursor capture reuses serialized tree and invalidates a prior close revision',
    () {
      final owner = workspace();
      addTearDown(owner.dispose);
      owner.composeMoves(['e4', 'e5', 'Nf3']);
      final before = owner.captureWorkspace().drafts.single;
      final close = owner.closeRevision;
      owner.board.jump(TreePath.empty);
      final after = owner.captureWorkspace().drafts.single;
      expect(identical(before.content, after.content), isTrue);
      expect(after.cursor, isEmpty);
      expect(owner.closeRevision, isNot(close));
    },
  );

  for (final titleOnly in [false, true]) {
    test(
      'edit supersedes pending recovery before document adoption; titleOnly=$titleOnly',
      () async {
        final owner = workspace();
        addTearDown(owner.dispose);
        await owner.document.setRepertoire(chapter('/a'));
        owner.composeMoves(['e4']);
        final draft = owner.captureWorkspace().drafts.single;
        final gate = documents.readGate = Completer<void>();
        final restoring = owner.openRetainedDraft(draft);
        final failed = expectLater(restoring, throwsStateError);
        if (titleOnly) {
          owner.setTitle('New intent');
        } else {
          owner.inspectAnnotatedTree(
            MoveTree.fromPgn('1. d4 d5 *'),
            label: 'New inspection',
          );
        }
        final board = owner.board.tree;
        gate.complete();
        await failed;
        expect(owner.board.tree, same(board));
        expect(owner.document.isLoading, isFalse);
        expect(
          titleOnly ? owner.title : owner.annotatedLineLabel,
          titleOnly ? 'New intent' : 'New inspection',
        );
      },
    );
  }

  for (final navigationOnly in [false, true]) {
    test(
      'same-destination copy cannot reload over newer board intent; navigationOnly=$navigationOnly',
      () async {
        final owner = workspace();
        addTearDown(owner.dispose);
        await owner.document.setRepertoire(chapter('/a'));
        owner.composeMoves(['e4', 'e5']);
        final draft = owner.captureWorkspace().drafts.single;
        final gate = documents.saveGate = Completer<void>();
        final copying = owner.saveDraftToChapter(draft, chapter('/a'));
        if (navigationOnly) {
          owner.board.jump(TreePath.empty);
        } else {
          owner.inspectAnnotatedTree(MoveTree.fromPgn('1. d4 d5 *'));
        }
        final tree = owner.board.tree;
        final cursor = owner.board.path;
        gate.complete();
        await copying;
        expect(owner.board.tree, same(tree));
        expect(owner.board.path, cursor);
        expect(documents.files['/a'], contains(draft.content));
      },
    );
  }

  test(
    'copy intent is checkpointed before publication and survives an interrupted acknowledgement',
    () async {
      BuilderWorkspaceSnapshot? durable;
      late BuilderWorkspaceController owner;
      owner = BuilderWorkspaceController(
        documents: documents,
        decoder: const IsolateRepertoireDecoder(),
        checkpoint: () async {
          durable = owner.captureWorkspace();
          expect(documents.appendCalls, 0);
          throw StateError('process stopped before publication');
        },
      );
      owner.composeMoves(['e4']);
      final draft = owner.captureWorkspace().drafts.single;
      await expectLater(
        owner.saveDraftToChapter(draft, chapter('/b')),
        throwsStateError,
      );
      expect(documents.appendCalls, 0);
      owner.dispose();
      final encoded = const BuilderWorkspaceCodec().encode(durable!);
      final restarted = workspace();
      addTearDown(restarted.dispose);
      await restarted.restoreWorkspace(
        const BuilderWorkspaceCodec().decode(encoded),
      );
      expect(restarted.uncertainCopies, hasLength(1));
      await expectLater(
        restarted.saveDraftToChapter(
          restarted.captureWorkspace().drafts.single,
          chapter('/b'),
        ),
        throwsStateError,
      );
      await restarted.inspectCopy(restarted.uncertainCopies.single);
      // No prior native baseline: observing equal source text does not prove an interrupted append did not happen.
      expect(restarted.uncertainCopies, hasLength(1));
      expect(documents.appendCalls, 0);
    },
  );

  for (final newerEdit in [false, true]) {
    test(
      'autosave retains draft referenced by unresolved copy, newerEdit=$newerEdit',
      () async {
        final slow = SlowLineDocuments()
          ..files['/a'] = pgn
          ..files['/b'] = pgn
          ..saveGate = Completer<void>()
          ..appendStarted = Completer<void>();
        final checkpoints = <BuilderWorkspaceSnapshot>[];
        late BuilderWorkspaceController owner;
        owner = BuilderWorkspaceController(
          documents: slow,
          decoder: const IsolateRepertoireDecoder(),
          checkpoint: () async => checkpoints.add(owner.captureWorkspace()),
        );
        addTearDown(owner.dispose);
        await owner.document.setRepertoire(chapter('/a'));
        owner.selectLine(owner.document.repertoireLines.single);
        slow.files['/a'] = owner.document.repertoireLines.single.fullPgn;
        owner.setTitle('Copied edit');
        await slow.firstStarted.future;
        final draft = owner.captureWorkspace().drafts.single;
        final before = (await slow.read('/b') as PgnOpened).snapshot;
        slow.appendOutcome = PgnWriteUncertain(
          error: 'acknowledgement lost',
          before: null,
          observed: before,
        );
        final copying = owner.saveDraftToChapter(draft, chapter('/b'));
        if (newerEdit) owner.setTitle('Newer source edit');
        slow.firstGate.complete();
        await slow.appendStarted!.future;
        const codec = BuilderWorkspaceCodec();
        // A crash during append must leave a decodable checkpoint even after
        // the source autosave was acknowledged.
        final inFlight = owner.captureWorkspace();
        expect(inFlight.drafts, hasLength(1));
        expect(
          codec.decode(codec.encode(inFlight)).uncertainCopies,
          hasLength(1),
        );
        slow.saveGate!.complete();
        await copying;
        for (final checkpoint in checkpoints) {
          codec.decode(codec.encode(checkpoint));
        }
        final restarted = BuilderWorkspaceController(
          documents: slow,
          decoder: const IsolateRepertoireDecoder(),
          checkpoint: () async {},
        );
        addTearDown(restarted.dispose);
        await restarted.restoreWorkspace(
          codec.decode(codec.encode(owner.captureWorkspace())),
        );
        expect(restarted.uncertainCopies, hasLength(1));
        await expectLater(
          restarted.saveDraftToChapter(
            restarted.retainedDrafts.single,
            chapter('/b'),
          ),
          throwsStateError,
        );
        await restarted.acknowledgeInspectedCopy(
          restarted.uncertainCopies.single,
        );
        expect(restarted.uncertainCopies, isEmpty);
        expect(restarted.retainedDrafts, hasLength(newerEdit ? 1 : 0));
        if (newerEdit)
          expect(
            restarted.retainedDrafts.single.content,
            contains('Newer source edit'),
          );
        expect(slow.appendCalls, 1);
      },
    );
  }

  test(
    'uncertain native install is not repeated and a proven installed revision resolves it',
    () async {
      final owner = workspace();
      addTearDown(owner.dispose);
      owner.composeMoves(['e4']);
      final draft = owner.captureWorkspace().drafts.single;
      final before = (await documents.read('/b') as PgnOpened).snapshot;
      documents.files['/b'] = '${before.content}\n\n${draft.content}\n';
      final after = (await documents.read('/b') as PgnOpened).snapshot;
      documents.appendOutcome = PgnWriteUncertain(
        error: 'ack lost',
        before: before,
        observed: after,
        installedRevision: after.revision,
        recoveryPath: '/journal',
      );
      await owner.saveDraftToChapter(draft, chapter('/b'));
      expect(owner.uncertainCopies, hasLength(1));
      await expectLater(
        owner.saveDraftToChapter(draft, chapter('/b')),
        throwsStateError,
      );
      final encoded = const BuilderWorkspaceCodec().encode(
        owner.captureWorkspace(),
      );
      final restarted = workspace();
      addTearDown(restarted.dispose);
      await restarted.restoreWorkspace(
        const BuilderWorkspaceCodec().decode(encoded),
      );
      expect(restarted.uncertainCopies.single.outcome.recoveryPath, '/journal');
      await restarted.inspectCopy(restarted.uncertainCopies.single);
      expect(restarted.uncertainCopies, isEmpty);
      expect(restarted.captureWorkspace().needsRecovery, isFalse);
      expect(documents.appendCalls, 1);
    },
  );

  test(
    'uncertain equal-text observation needs explicit inspected-copy acknowledgement',
    () async {
      final owner = workspace();
      addTearDown(owner.dispose);
      owner.composeMoves(['e4']);
      final draft = owner.captureWorkspace().drafts.single;
      final before = (await documents.read('/b') as PgnOpened).snapshot;
      documents.files['/b'] = '${before.content}\n\n${draft.content}\n';
      final observed = (await documents.read('/b') as PgnOpened).snapshot;
      documents.appendOutcome = PgnWriteUncertain(
        error: 'unproven copy',
        before: before,
        observed: observed,
      );
      await owner.saveDraftToChapter(draft, chapter('/b'));
      await owner.inspectCopy(owner.uncertainCopies.single);
      expect(owner.uncertainCopies, hasLength(1));
      await expectLater(
        owner.saveDraftToChapter(draft, chapter('/b')),
        throwsStateError,
      );
      await owner.acknowledgeInspectedCopy(owner.uncertainCopies.single);
      expect(owner.captureWorkspace().needsRecovery, isFalse);
      expect(documents.appendCalls, 1);
    },
  );

  for (final copyFirst in [true, false]) {
    test(
      'close joins whole copy including checkpoint, copyFirst=$copyFirst',
      () async {
        final store = GatedRecoveryStore();
        final lifetime = BuilderLifetime(
          documents: documents,
          decoder: const IsolateRepertoireDecoder(),
          store: store,
        );
        final owner = lifetime.workspace;
        owner.composeMoves(['e4']);
        final draft = owner.captureWorkspace().drafts.single;
        final firstEntered = Completer<void>();
        final firstGate = Completer<void>();
        final finalEntered = Completer<void>();
        final finalGate = Completer<void>();
        store.beforeWrite = (snapshot) async {
          if (!firstEntered.isCompleted) {
            firstEntered.complete();
            await firstGate.future;
          }
          if (documents.appendCalls > 0 &&
              snapshot.uncertainCopies.isEmpty &&
              !finalEntered.isCompleted) {
            finalEntered.complete();
            await finalGate.future;
          }
        };
        var closed = false;
        late Future<void> copy;
        late Future<void> close;
        final before = owner.closeRevision;
        if (copyFirst) {
          copy = owner.saveDraftToChapter(draft, chapter('/b'));
          await firstEntered.future;
          close = lifetime.flushForClose().then((_) => closed = true);
        } else {
          close = lifetime.flushForClose().then((_) => closed = true);
          await firstEntered.future;
          copy = owner.saveDraftToChapter(draft, chapter('/b'));
        }
        expect(owner.closeRevision, isNot(before));
        expect(documents.appendCalls, 0);
        firstGate.complete();
        await finalEntered.future;
        expect(closed, isFalse);
        final shutdown = lifetime.shutdown();
        await Future<void>.delayed(Duration.zero);
        expect(store.closed, isFalse);
        finalGate.complete();
        await Future.wait([copy, close, shutdown]);
        expect(closed, isTrue);
        expect(store.closed, isTrue);
        expect(store.snapshot!.needsRecovery, isFalse);
        expect(documents.appendCalls, 1);
      },
    );
  }

  test(
    'shutdown joins pending inspection and its observation checkpoint',
    () async {
      final store = GatedRecoveryStore();
      final lifetime = BuilderLifetime(
        documents: documents,
        decoder: const IsolateRepertoireDecoder(),
        store: store,
      );
      final owner = lifetime.workspace;
      owner.composeMoves(['e4']);
      final draft = owner.captureWorkspace().drafts.single;
      documents.appendOutcome = const PgnWriteUncertain(
        error: 'lost reply',
        before: null,
        observed: null,
      );
      await owner.saveDraftToChapter(draft, chapter('/b'));
      documents.readGate = Completer<void>();
      documents.readStarted = Completer<void>();
      final inspect = owner.inspectCopy(owner.uncertainCopies.single);
      await documents.readStarted!.future;
      final shutdown = lifetime.shutdown();
      await Future<void>.delayed(Duration.zero);
      expect(store.closed, isFalse);
      documents.readGate!.complete();
      await inspect;
      await shutdown;
      expect(store.closed, isTrue);
      expect(
        store.snapshot!.uncertainCopies.single.outcome.observed,
        isNotNull,
      );
      await expectLater(
        owner.acknowledgeInspectedCopy(owner.uncertainCopies.single),
        throwsStateError,
      );
    },
  );

  test('shutdown joins explicit copy acknowledgement checkpoint', () async {
    final store = GatedRecoveryStore();
    final lifetime = BuilderLifetime(
      documents: documents,
      decoder: const IsolateRepertoireDecoder(),
      store: store,
    );
    final owner = lifetime.workspace;
    owner.composeMoves(['e4']);
    final draft = owner.captureWorkspace().drafts.single;
    final observed = (await documents.read('/b') as PgnOpened).snapshot;
    documents.appendOutcome = PgnWriteUncertain(
      error: 'lost reply',
      before: null,
      observed: observed,
    );
    await owner.saveDraftToChapter(draft, chapter('/b'));
    final entered = Completer<void>();
    final gate = Completer<void>();
    store.beforeWrite = (_) async {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
    };
    final ack = owner.acknowledgeInspectedCopy(owner.uncertainCopies.single);
    await entered.future;
    final shutdown = lifetime.shutdown();
    await Future<void>.delayed(Duration.zero);
    expect(store.closed, isFalse);
    gate.complete();
    await Future.wait([ack, shutdown]);
    expect(store.closed, isTrue);
    expect(store.snapshot!.needsRecovery, isFalse);
  });

  test(
    'unreadable source restores detached exact draft and permits explicit copy',
    () async {
      final first = workspace();
      await first.document.setRepertoire(chapter('/a'));
      first.selectLine(first.document.repertoireLines.single);
      documents.files['/a'] = first.document.repertoireLines.single.fullPgn;
      first.board.setCommentAtPath(const TreePath([0]), 'retained annotation');
      final snapshot = first.captureWorkspace();
      await first.document.flushDocumentForClose();
      first.dispose();
      documents.failure = StateError('source permission denied');
      final restarted = workspace();
      addTearDown(restarted.dispose);
      await restarted.restoreWorkspace(snapshot);
      expect(restarted.sourceChanged, isTrue);
      expect(
        restarted.document.loadError,
        contains('source permission denied'),
      );
      expect(restarted.document.selectedPgnLine, isNull);
      expect(
        restarted.board.tree.toPgnMoveText(),
        contains('retained annotation'),
      );
      expect(
        restarted.captureWorkspace().drafts.single.content,
        snapshot.drafts.single.content,
      );
      final original = documents.files['/a'];
      documents.failure = null;
      await restarted.saveDraftToChapter(
        restarted.captureWorkspace().drafts.single,
        chapter('/b'),
      );
      expect(documents.files['/a'], original);
      expect(documents.files['/b'], contains('retained annotation'));
    },
  );

  test(
    'older checkpoint without native source evidence remains detached despite equal source text',
    () async {
      final first = workspace();
      await first.document.setRepertoire(chapter('/a'));
      final line = first.document.repertoireLines.single;
      final key = '/a\u0000${line.id}';
      final snapshot = BuilderWorkspaceSnapshot(
        activeKey: key,
        drafts: [
          BuilderDraft(
            key: key,
            repertoire: chapter('/a'),
            content: line.fullPgn,
            sourcePgn: first.document.repertoirePgn,
            lineId: line.id,
            linePgn: line.fullPgn,
            title: 'Old checkpoint',
            cursor: const [],
          ),
        ],
      );
      first.dispose();
      final decoded = const BuilderWorkspaceCodec().decode(
        const BuilderWorkspaceCodec().encode(snapshot),
      );
      final restarted = workspace();
      addTearDown(restarted.dispose);
      await restarted.restoreWorkspace(decoded);
      expect(
        restarted.document.repertoirePgn,
        snapshot.drafts.single.sourcePgn,
      );
      expect(restarted.sourceChanged, isTrue);
      expect(restarted.document.selectedPgnLine, isNull);
      expect(await restarted.saveActiveLine(), isFalse);
      restarted.selectLine(restarted.document.repertoireLines.single);
      restarted.setTitle('Still detached after selecting its outline row');
      expect(restarted.sourceChanged, isTrue);
      expect(restarted.document.selectedPgnLine, isNull);
      expect(await restarted.saveActiveLine(), isFalse);
      expect(documents.files['/a'], pgn);
    },
  );

  for (final fail in [false, true]) {
    test(
      'slow-store annotation burst retains only latest pending save, fail=$fail',
      () async {
        final slow = SlowLineDocuments()..files['/a'] = pgn;
        slow.files['/b'] = pgn;
        final owner = BuilderWorkspaceController(
          checkpoint: () async {},
          documents: slow,
          decoder: const IsolateRepertoireDecoder(),
        );
        addTearDown(owner.dispose);
        await owner.document.setRepertoire(chapter('/a'));
        owner.selectLine(owner.document.repertoireLines.single);
        slow.files['/a'] = owner.document.repertoireLines.single.fullPgn;
        owner.setTitle('First write');
        await slow.firstStarted.future;
        slow.failLineWrites = fail;
        final timer = Stopwatch()..start();
        Future<bool>? sharedPending;
        for (var i = 0; i < 250; i++) {
          owner.board.setCommentAtPath(
            const TreePath([0]),
            '${'long annotation ' * 200}revision $i',
          );
          final pending = owner.saveActiveLine();
          if (sharedPending != null) {
            expect(identical(pending, sharedPending), isTrue);
          }
          sharedPending = pending;
        }
        timer.stop();
        // This is a recorded workload, not a timing assertion on a shared host.
        debugPrint(
          'Builder250 edits x3200-char annotation: ${timer.elapsedMilliseconds}ms; ${slow.writes.length} active write, one shared pending completion',
        );
        expect(slow.writes, hasLength(1));
        expect(
          owner.captureWorkspace().drafts.single.content,
          contains('revision 249'),
        );
        var switched = false;
        final switching = owner.document
            .setRepertoire(chapter('/b'))
            .then((_) => switched = true);
        var closed = false;
        final close = owner.document.flushDocumentForClose().then(
          (_) => closed = true,
        );
        final checkedClose = fail
            ? expectLater(close, throwsStateError)
            : close;
        await Future<void>.delayed(Duration.zero);
        expect(switched, isFalse);
        expect(closed, isFalse);
        slow.firstGate.complete();
        await switching;
        await checkedClose;
        expect(slow.writes, hasLength(2));
        expect(slow.writes.last, contains('revision 249'));
        if (fail) {
          expect(
            owner.captureWorkspace().drafts.single.content,
            contains('revision 249'),
          );
          expect(owner.document.currentRepertoire!.filePath, '/a');
          slow.failLineWrites = false;
          expect(await owner.saveActiveLine(), isTrue);
          await owner.document.flushDocumentForClose();
          expect(slow.writes, hasLength(3));
          expect(slow.files['/a'], contains('revision 249'));
        } else {
          expect(owner.captureWorkspace().drafts, isEmpty);
          expect(owner.document.currentRepertoire!.filePath, '/b');
          expect(slow.files['/a'], contains('revision 249'));
        }
        expect(slow.files['/b'], pgn);
      },
    );
  }

  test(
    'explicit document command preserves ordering between coalesced edit bursts',
    () async {
      final slow = SlowLineDocuments()..files['/a'] = pgn;
      final owner = BuilderWorkspaceController(
        checkpoint: () async {},
        documents: slow,
        decoder: const IsolateRepertoireDecoder(),
      );
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(chapter('/a'));
      owner.selectLine(owner.document.repertoireLines.single);
      slow.files['/a'] = owner.document.repertoireLines.single.fullPgn;
      final save = owner.document.selectedLineSaver!;
      final first = save(pgn.replaceFirst('Original', 'active'));
      await slow.firstStarted.future;
      final before = save(pgn.replaceFirst('Original', 'before command'));
      final beforeLatest = save(
        pgn.replaceFirst('Original', 'latest before command'),
      );
      expect(identical(before, beforeLatest), isTrue);
      String? observedAtCommand;
      final command = owner.document.runDocumentMutation(() async {
        observedAtCommand = slow.files['/a'];
      });
      final after = save(pgn.replaceFirst('Original', 'after command'));
      expect(identical(before, after), isFalse);
      final afterLatest = save(
        pgn.replaceFirst('Original', 'latest after command'),
      );
      expect(identical(after, afterLatest), isTrue);
      slow.firstGate.complete();
      await Future.wait([first, before, command, after]);
      await owner.document.flushDocumentForClose();
      expect(slow.writes, hasLength(3));
      expect(observedAtCommand, contains('latest before command'));
      expect(slow.files['/a'], contains('latest after command'));
    },
  );

  test(
    'native recovery store reopens annotations, custom FEN and cursor after lifetime ends',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'builder-checkpoint',
      );
      addTearDown(() => directory.delete(recursive: true));
      FileWorkspaceRecoveryStore<BuilderWorkspaceSnapshot> store() =>
          FileWorkspaceRecoveryStore(
            directory: () async => directory,
            codec: const BuilderWorkspaceCodec(),
          );
      final first = BuilderLifetime(
        documents: documents,
        decoder: const IsolateRepertoireDecoder(),
        store: store(),
      );
      first.workspace.board.setPositionFromFen('8/8/8/8/8/2k5/8/4K3 w - - 0 1');
      first.workspace.board.playMove('Kd1');
      first.workspace.board.setCommentAtPath(
        const TreePath([0]),
        'king ending',
      );
      first.workspace.board.jump(TreePath.empty);
      await first.shutdown();
      final second = BuilderLifetime(
        documents: documents,
        decoder: const IsolateRepertoireDecoder(),
        store: store(),
      );
      await second.recovery.refresh();
      // Constructor starts refresh; allow that first read to complete.
      while (second.recovery.loading) {
        await Future<void>.delayed(Duration.zero);
      }
      final entry = second.recovery.listing.entries.single;
      expect(await second.recovery.restore(entry), isTrue);
      expect(
        second.workspace.board.startingFen,
        '8/8/8/8/8/2k5/8/4K3 w - - 0 1',
      );
      expect(second.workspace.board.path, TreePath.empty);
      expect(
        second.workspace.board.tree.toPgnMoveText(),
        contains('king ending'),
      );
      await second.shutdown();
    },
  );
}
