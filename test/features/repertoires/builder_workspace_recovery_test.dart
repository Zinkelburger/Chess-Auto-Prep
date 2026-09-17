import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
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
  @override
  Future<void> replace(
    String path,
    String content, {
    required String expectedContent,
  }) async {
    await saveGate?.future;
    if (files[path] != expectedContent)
      throw StateError('Concurrent destination change');
    files[path] = content;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CopyDocuments documents;
  BuilderWorkspaceController workspace() => BuilderWorkspaceController(
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
