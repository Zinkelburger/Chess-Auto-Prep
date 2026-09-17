import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoires/models/loaded_repertoire.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_decoder.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/repertoire_dependencies.dart';

class _Documents implements RepertoireDocumentRepository {
  @override
  Future<PgnOpenResult> read(String path) async => PgnOpened(
    PgnSnapshot(
      path: path,
      content: '1. d4 Nf6 2. e3 c5 *',
      revision: const PgnRevision(
        documentId: 'test',
        nativeIdentity: 'test',
        sha256: 'test',
      ),
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Decoder implements RepertoireDecoder {
  final source = OpeningTree()..appendLine(['d4', 'Nf6', 'e3', 'c5']);
  @override
  Future<LoadedRepertoire> build(
    String? pgnText, {
    required bool fallbackIsWhite,
  }) async => LoadedRepertoire(
    pgn: pgnText,
    openingTree: source,
    lines: const [],
    headers: null,
  );
}

void main() {
  test(
    'Builder owns decoder graph and exposes only protected query projections',
    () async {
      final decoder = _Decoder();
      final owner = testBuilderWorkspace(
        documents: _Documents(),
        decoder: decoder,
      );
      addTearDown(owner.dispose);
      await owner.document.setRepertoire(
        RepertoireMetadata(
          name: 'Graph',
          filePath: '/graph',
          lastModified: DateTime(2026),
        ),
      );
      final graph = owner.document.openingGraph!;
      expect(graph, isNot(isA<OpeningTree>()));
      expect(graph.root, isNot(isA<OpeningTreeNode>()));
      expect(() => graph.root.children.clear(), throwsUnsupportedError);
      expect(() => graph.fenToNodes.clear(), throwsUnsupportedError);
      expect(
        () => graph.fenToNodes.values.first.clear(),
        throwsUnsupportedError,
      );
      expect(() => graph.currentGroup.nodes.clear(), throwsUnsupportedError);
      expect(() => graph.continuations.clear(), throwsUnsupportedError);
      expect(() => graph.currentMovePath.add('e4'), throwsUnsupportedError);
      expect(
        () => (graph.root as dynamic).gamesPlayed = 99,
        throwsNoSuchMethodError,
      );
      decoder.source.root.children.clear();
      decoder.source.fenToNodes.clear();
      expect(graph.root.children.keys, ['d4']);
      owner.board.loadMoveHistory(['d4', 'c5', 'e3']);
      expect(graph.currentMovePath, ['d4', 'c5', 'e3']);
      expect(graph.inBook, isFalse);
      expect(graph.continuations.single.move, 'Nf6');
      expect(graph.continuations.single.viaTransposition, isTrue);
      expect(graph.currentFen, owner.board.fen);
      expect(graph.root.children['d4']!.parent, same(graph.root));
    },
  );
}
