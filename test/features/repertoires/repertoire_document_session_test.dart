import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'dart:async';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_document_session.dart';
import 'package:chess_auto_prep/features/repertoires/models/loaded_repertoire.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_authoring.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_decoder.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';

RepertoireMetadata metadata(String path) => RepertoireMetadata(
  filePath: path,
  name: path,
  lastModified: DateTime(2026),
);

class MemoryDocuments implements RepertoireDocumentRepository {
  final files = <String, String>{'/a': 'a', '/b': 'b'};
  Object? failure;
  Completer<void>? readGate;
  Completer<void>? readStarted;
  @override
  Future<PgnOpenResult> read(String path) async {
    if (readStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await readGate?.future;
    if (failure case final error?) throw error;
    final content = files[path];
    return content == null
        ? const PgnMissing()
        : PgnOpened(
            PgnSnapshot(
              path: path,
              content: content,
              revision: PgnRevision(
                documentId: path,
                nativeIdentity: '$path:$content',
                sha256: content.hashCode.toString(),
              ),
            ),
          );
  }

  @override
  Future<RepertoireLineSaveReceipt?> updateLineContent(
    String path,
    String lineId,
    String content, {
    required String expectedContent,
  }) async {
    if (failure case final error?) throw error;
    if (files[path] != expectedContent) return null;
    files[path] = content;
    return (
      documentPgn: content,
      snapshot: (await read(path) as PgnOpened).snapshot,
      linePgn: content,
      lineIndex: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class MemoryDecoder implements RepertoireDecoder {
  Completer<void>? gate;
  Object? failure;
  @override
  Future<LoadedRepertoire> build(
    String? pgn, {
    required bool fallbackIsWhite,
  }) async {
    await gate?.future;
    if (failure case final error?) throw error;
    return LoadedRepertoire(
      pgn: pgn,
      openingTree: null,
      lines: [
        const RepertoireAuthoring().buildNewLine(
          moves: const ['e4'],
          title: pgn!,
          pgnContent: pgn,
          index: 0,
          isWhite: true,
          existingIds: const [],
        ),
      ],
      headers: null,
    );
  }
}

void main() {
  late MemoryDocuments documents;
  late MemoryDecoder decoder;
  late RepertoireDocumentSession session;
  late int resets;
  late int changes;
  setUp(() {
    documents = MemoryDocuments();
    decoder = MemoryDecoder();
    resets = 0;
    changes = 0;
    session = RepertoireDocumentSession(
      documents: documents,
      decoder: decoder,
      onChanged: () => changes++,
      onLoadStarted: () {},
      onResetBoard: () => resets++,
      onClearSelectionAndTree: () {},
      onNavigate: (_) {},
      onNavigateToRoot: () {},
      startingFen: () => null,
      currentMoveSequence: () => const [],
    );
  });
  tearDown(() => session.dispose());

  test(
    'published line values reject mutation and detach caller collections',
    () {
      final moves = ['e4'];
      final comments = {'0': 'original'};
      final headers = {'Event': 'Original'};
      final line = RepertoireLine(
        id: 'line',
        name: 'Line',
        moves: moves,
        color: 'white',
        startPosition: Chess.initial,
        fullPgn: '1. e4 *',
        comments: comments,
        headers: headers,
      );
      moves.add('e5');
      comments['0'] = 'changed';
      headers.clear();
      expect(line.moves, ['e4']);
      expect(line.comments['0'], 'original');
      expect(line.headers['Event'], 'Original');
      expect(() => line.moves.clear(), throwsUnsupportedError);
      expect(() => line.comments.clear(), throwsUnsupportedError);
      expect(() => line.headers.clear(), throwsUnsupportedError);
    },
  );

  test('destination changes only together with decoded chapter', () async {
    await session.setRepertoire(metadata('/a'));
    final originalLines = session.repertoireLines;
    final gate = decoder.gate = Completer<void>();
    final loading = session.setRepertoire(metadata('/b'));
    expect(session.isLoading, isTrue);
    expect(session.currentRepertoire!.filePath, '/a');
    expect(session.repertoireLines, same(originalLines));
    gate.complete();
    await loading;
    expect(session.currentRepertoire!.filePath, '/b');
    expect(session.repertoirePgn, 'b');
    expect(resets, 2);
  });

  test(
    'failed switch retains document, selection and board; retry recovers',
    () async {
      await session.setRepertoire(metadata('/a'));
      final line = session.repertoireLines.single;
      session.selectLine(line);
      decoder.failure = StateError('decode failed');
      await session.setRepertoire(metadata('/b'));
      expect(session.currentRepertoire!.filePath, '/a');
      expect(session.selectedPgnLine, same(line));
      expect(session.repertoirePgn, 'a');
      expect(session.loadError, isNotNull);
      expect(resets, 1);
      decoder.failure = null;
      await session.setRepertoire(metadata('/b'));
      expect(session.currentRepertoire!.filePath, '/b');
      expect(session.loadError, isNull);
    },
  );

  test(
    'failed pending edit blocks repeated switches and close until saved',
    () async {
      await session.setRepertoire(metadata('/a'));
      session.selectLine(session.repertoireLines.single);
      final save = session.selectedLineSaver!;
      documents.failure = StateError('disk unavailable');
      unawaited(save('edited').catchError((_) => false));
      await session.setRepertoire(metadata('/b'));
      expect(session.currentRepertoire!.filePath, '/a');
      expect(resets, 1);
      documents.failure = null;
      await session.setRepertoire(metadata('/b'));
      expect(session.currentRepertoire!.filePath, '/a');
      await expectLater(session.flushDocumentForClose(), throwsStateError);
      expect(await save('edited'), isTrue);
      await session.setRepertoire(metadata('/b'));
      expect(session.currentRepertoire!.filePath, '/b');
      expect(documents.files['/a'], 'edited');
    },
  );

  test(
    'dispose prevents late adoption while the captured load settles',
    () async {
      await session.setRepertoire(metadata('/a'));
      final gate = documents.readGate = Completer<void>();
      final entered = documents.readStarted = Completer<void>();
      final loading = session.setRepertoire(metadata('/b'));
      await entered.future;
      session.dispose();
      final before = changes;
      gate.complete();
      await loading;
      expect(changes, before);
      expect(resets, 1);
      expect(session.currentRepertoire!.filePath, '/a');
      expect(session.isLoading, isFalse);
    },
  );

  test(
    'retained save callback cannot create new work after disposal',
    () async {
      await session.setRepertoire(metadata('/a'));
      session.selectLine(session.repertoireLines.single);
      final save = session.selectedLineSaver!;
      session.dispose();
      await expectLater(save('late'), throwsStateError);
      expect(documents.files['/a'], 'a');
    },
  );
}
