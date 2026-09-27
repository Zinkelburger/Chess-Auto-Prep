import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/infrastructure/documents/file_workspace_recovery_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/pgn_workspace_codec.dart';
import '../../support/scripted_document_store.dart';

void main() {
  test(
    'a released viewer checkpoint preserves originals, drafts, revision and cursor',
    () async {
      final folder = await Directory.systemTemp.createTemp('pgn-workspace-');
      addTearDown(() => folder.delete(recursive: true));
      final writer = FileWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(
        directory: () async => folder,
        codec: const PgnWorkspaceCodec(),
      );
      final reader = FileWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(
        directory: () async => folder,
        codec: const PgnWorkspaceCodec(),
      );
      addTearDown(writer.close);
      addTearDown(reader.close);
      final original = snapshot('Original', path: '/games.pgn');
      await writer.write(
        PgnWorkspaceSnapshot(
          path: '/games.pgn',
          content: 'Draft',
          dirty: true,
          persistedGames: ['Game one', 'Game two'],
          baseline: original,
          gameIndex: 1,
          ply: 7,
          flipped: true,
          uncertain: true,
          uncertainPath: '/copy.pgn',
          retainedDrafts: [
            const RetainedDocumentDraft(
              path: '/retained.pgn',
              content: 'Retained',
              baseline: null,
            ),
          ],
        ),
      );
      expect((await reader.list()).entries, isEmpty);
      await writer.close();
      final entry = (await reader.list()).entries.single;
      final restored = entry.snapshot;
      expect(restored.persistedGames, ['Game one', 'Game two']);
      expect(restored.content, 'Draft');
      expect(restored.baseline!.revision, original.revision);
      expect(restored.gameIndex, 1);
      expect(restored.ply, 7);
      expect(restored.flipped, isTrue);
      expect(restored.uncertainPath, '/copy.pgn');
      expect(restored.retainedDrafts.single.content, 'Retained');
      await reader.resolve(entry);
      expect((await reader.list()).entries, isEmpty);
      expect(
        await File('${folder.path}/${entry.id}.json').readAsString(),
        contains('Retained'),
      );
    },
  );
  test('invalid cursor and mismatched source revision are rejected', () {
    const codec = PgnWorkspaceCodec();
    final encoded = codec.encode(
      PgnWorkspaceSnapshot(
        path: '/games.pgn',
        content: 'Game',
        dirty: true,
        persistedGames: ['Game'],
      ),
    );
    expect(
      () => codec.decode({...encoded, 'gameIndex': 2}),
      throwsFormatException,
    );
    expect(() => codec.decode({...encoded, 'ply': -1}), throwsFormatException);
    final mismatched = codec.encode(
      PgnWorkspaceSnapshot(
        path: '/games.pgn',
        content: 'Game',
        dirty: true,
        persistedGames: ['Game'],
        baseline: snapshot('Other source', path: '/other.pgn'),
      ),
    );
    expect(() => codec.decode(mismatched), throwsFormatException);
  });
}
