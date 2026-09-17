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
    show MemoryBuilderRecoveryStore;

const pgn = '[Event "Original"]\n[Result "*"]\n\n1. e4 e5 *';
RepertoireMetadata chapter(String path) => RepertoireMetadata(
  filePath: path,
  name: path,
  lastModified: DateTime(2026),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryDocuments documents;
  BuilderWorkspaceController workspace() => BuilderWorkspaceController(
    documents: documents,
    decoder: const IsolateRepertoireDecoder(),
  );
  setUp(() {
    documents = MemoryDocuments()..files['/a'] = pgn;
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
