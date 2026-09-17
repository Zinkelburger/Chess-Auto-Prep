import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/repertoires/models/builder_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/file_workspace_recovery_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/builder_workspace_codec.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/isolate_repertoire_decoder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Builder restart restores scratch and explicit copy retires only its checkpoint',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'builder-native-restart',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/source.pgn');
      final destination = File('${root.path}/destination.pgn');
      const original = '[Event "Original"]\n\n1. e4 e5 *';
      const target = '[Event "Destination"]\n\n1. d4 d5 *';
      final documents = NativePgnDocumentStore();
      await documents.create(source.path, original);
      await documents.create(destination.path, target);
      RepertoireMetadata metadata(File file) => RepertoireMetadata(
        filePath: file.path,
        name: file.uri.pathSegments.last,
        lastModified: DateTime(2026),
      );
      BuilderLifetime lifetime() => BuilderLifetime(
        documents: DocumentRepertoireRepository(documents),
        decoder: const IsolateRepertoireDecoder(),
        store: FileWorkspaceRecoveryStore<BuilderWorkspaceSnapshot>(
          directory: () async => Directory('${root.path}/recovery'),
          codec: const BuilderWorkspaceCodec(),
        ),
      );
      final first = lifetime();
      await first.workspace.document.setRepertoire(metadata(source));
      first.workspace.composeMoves(['e4', 'e5', 'Nf3']);
      first.workspace.board.jump(const TreePath([0]));
      first.workspace.board.playMove('c5');
      first.workspace.board.setCommentAtPath(
        first.workspace.board.path,
        'Native restart note',
      );
      first.workspace.board.toggleNagAtPath(first.workspace.board.path, 1);
      first.workspace.setTitle('Recovered scratch');
      final cursor = first.workspace.board.path;
      await first.shutdown();
      final second = lifetime();
      while (second.recovery.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final entry = second.recovery.listing.entries.single;
      expect(await second.recovery.restore(entry), isTrue);
      expect(second.workspace.board.path, cursor);
      expect(
        second.workspace.board.tree.toPgnMoveText(),
        contains('Native restart note'),
      );
      expect(second.workspace.board.tree.toPgnMoveText(), contains(r'$1'));
      expect(await source.readAsString(), original);
      await second.workspace.saveDraftToChapter(
        second.workspace.captureWorkspace().drafts.single,
        metadata(destination),
      );
      expect(await destination.readAsString(), startsWith(target));
      expect(await destination.readAsString(), contains('Recovered scratch'));
      expect(await destination.readAsString(), contains('Native restart note'));
      await second.shutdown();
      final third = lifetime();
      while (third.recovery.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(third.recovery.listing.entries, isEmpty);
      await third.shutdown();
    },
  );
}
