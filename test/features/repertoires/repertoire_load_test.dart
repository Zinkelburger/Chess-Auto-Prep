/// Characterisation tests for the repertoire *load* path.
///
/// These pin the behaviour of `loadRepertoire` / `setRepertoire` before the
/// persistence mixin is broken out into a real collaborator: what a missing
/// file leaves behind, what a read failure reports, which state a *superseded*
/// load is allowed to touch, and when each captured load command completes.
library;

import '../../support/repertoire_dependencies.dart';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';

/// In-memory storage whose reads can be held open, so two loads can be
/// interleaved deterministically.
class _GatedStorage implements StorageService {
  final Map<String, String> files = {};

  /// Reads of these paths block until the completer is completed.
  final Map<String, Completer<void>> readGates = {};

  /// Paths whose read throws instead of returning content.
  final Set<String> failingReads = {};

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async {
    final gate = readGates[path];
    if (gate != null) await gate.future;
    if (failingReads.contains(path)) {
      throw StateError('simulated read failure for $path');
    }
    return files[path];
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (createOnly && files.containsKey(path)) {
      throw StateError('file exists');
    }
    files[path] = content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

RepertoireMetadata _meta(String path) => RepertoireMetadata(
  filePath: path,
  name: path,
  lastModified: DateTime(2026),
);

const _whitePgn = '''
// Color: White

[Event "A"]
[Result "*"]

1. e4 e5 *
''';

const _blackPgn = '''
// Color: Black
// Root: 1. d4 Nf6

[Event "B"]
[Result "*"]

1. d4 Nf6 2. c4 e6 *
''';

const _restoredPgn = '''
// Color: White

[Event "Undone"]
[Result "*"]

1. c4 e5 *
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _GatedStorage storage;

  setUp(() {
    storage = _GatedStorage();
    StorageFactory.instanceForTest = storage;
  });

  tearDown(() => StorageFactory.instanceForTest = null);

  group('loadRepertoire outcomes', () {
    test('a missing file clears the PGN, tree and lines', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/a.pgn'));
      expect(controller.document.repertoireLines, isNotEmpty);

      await controller.document.setRepertoire(_meta('/gone.pgn'));

      expect(controller.document.repertoirePgn, isNull);
      expect(controller.document.openingGraph, isNull);
      expect(controller.document.repertoireLines, isEmpty);
      expect(controller.board.moveHistory, isEmpty);
      expect(controller.document.loadError, isNull);
    });

    test('a missing file leaves the colour headers of the last load', () async {
      storage.files['/b.pgn'] = _blackPgn;
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/b.pgn'));
      expect(controller.document.isRepertoireWhite, isFalse);
      expect(controller.document.rootMoves, '1. d4 Nf6');

      await controller.document.setRepertoire(_meta('/gone.pgn'));

      // The missing-file branch never re-derives the headers, so they survive.
      expect(controller.document.isRepertoireWhite, isFalse);
      expect(controller.document.rootMoves, '1. d4 Nf6');
    });

    test('a read failure is reported through loadError', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.failingReads.add('/a.pgn');
      final controller = testBuilderWorkspace();

      await controller.document.setRepertoire(_meta('/a.pgn'));

      expect(
        controller.document.loadError,
        startsWith('Failed to load repertoire:'),
      );
      expect(controller.document.repertoirePgn, isNull);
      expect(controller.document.openingGraph, isNull);
      expect(controller.document.repertoireLines, isEmpty);
      expect(controller.document.isLoading, isFalse);
    });

    test('a later successful load clears a previous loadError', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.failingReads.add('/a.pgn');
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/a.pgn'));
      expect(controller.document.loadError, isNotNull);

      storage.failingReads.clear();
      await controller.document.loadRepertoire();

      expect(controller.document.loadError, isNull);
      expect(controller.document.repertoireLines, hasLength(1));
    });

    test('an empty file yields an empty opening tree and no lines', () async {
      storage.files['/empty.pgn'] = '';
      final controller = testBuilderWorkspace();

      await controller.document.setRepertoire(_meta('/empty.pgn'));

      expect(controller.document.repertoirePgn, '');
      expect(controller.document.openingGraph, isNotNull);
      expect(controller.document.openingGraph!.totalGames, 0);
      expect(controller.document.repertoireLines, isEmpty);
    });

    test('a PGN with no // Color: comment asks for colour selection', () async {
      storage.files['/n.pgn'] = '[Event "A"]\n[Result "*"]\n\n1. e4 e5 *\n';
      final controller = testBuilderWorkspace();

      await controller.document.setRepertoire(_meta('/n.pgn'));

      expect(controller.document.needsColorSelection, isTrue);
      // Absent a header the repertoire is treated as White.
      expect(controller.document.isRepertoireWhite, isTrue);
    });

    test(
      'a // Color: Black header flips the side and clears the prompt',
      () async {
        storage.files['/b.pgn'] = _blackPgn;
        final controller = testBuilderWorkspace();

        await controller.document.setRepertoire(_meta('/b.pgn'));

        expect(controller.document.needsColorSelection, isFalse);
        expect(controller.document.isRepertoireWhite, isFalse);
        expect(controller.document.repertoireLines.single.color, 'black');
      },
    );

    test('a load navigates to the saved // Root: position', () async {
      storage.files['/b.pgn'] = _blackPgn;
      final controller = testBuilderWorkspace();

      await controller.document.setRepertoire(_meta('/b.pgn'));

      expect(controller.board.moveHistory, ['d4', 'Nf6']);
      expect(
        controller.board.isAtRootPosition(controller.document.rootMoves),
        isTrue,
      );
    });

    test('a load drops the undo stack', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = testBuilderWorkspace();
      controller.writer.recordDraftUndo(isCurrent: () => true, restore: () {});
      expect(controller.writer.canUndo, isTrue);

      await controller.document.setRepertoire(_meta('/a.pgn'));

      expect(controller.writer.canUndo, isFalse);
    });

    test('a headerless PGN body still builds a tree', () async {
      // No [Event] tags at all: the game-splitter still yields movetext.
      storage.files['/m.pgn'] = '// Color: White\n\n1. e4 e5 2. Nf3 Nc6 *\n';
      final controller = testBuilderWorkspace();

      await controller.document.setRepertoire(_meta('/m.pgn'));

      expect(controller.document.openingGraph, isNotNull);
      expect(controller.document.needsColorSelection, isFalse);
    });
  });

  group('load command completion', () {
    test('is held open for the duration of a load', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final gate = Completer<void>();
      storage.readGates['/a.pgn'] = gate;
      final controller = testBuilderWorkspace();

      final load = controller.document.setRepertoire(_meta('/a.pgn'));
      await pumpEventQueue();
      expect(controller.document.isLoading, isTrue);

      var released = false;
      unawaited(load.then((_) => released = true));
      await pumpEventQueue();
      expect(released, isFalse, reason: 'the load has not finished yet');

      gate.complete();
      await load;
      await pumpEventQueue();

      expect(released, isTrue);
      expect(controller.document.isLoading, isFalse);
      expect(controller.document.repertoireLines, hasLength(1));
    });

    test(
      'a superseded load does not complete the newer load command',
      () async {
        storage.files['/a.pgn'] = _whitePgn;
        storage.files['/b.pgn'] = _blackPgn;
        final gateA = Completer<void>();
        final gateB = Completer<void>();
        storage.readGates['/a.pgn'] = gateA;
        storage.readGates['/b.pgn'] = gateB;
        final controller = testBuilderWorkspace();

        final loadA = controller.document.setRepertoire(_meta('/a.pgn'));
        await pumpEventQueue();
        final loadB = controller.document.setRepertoire(_meta('/b.pgn'));
        await pumpEventQueue();

        var released = false;
        unawaited(loadB.then((_) => released = true));

        // A loses the race and must not clear `isLoading` out from under B.
        gateA.complete();
        await loadA;
        await pumpEventQueue();
        expect(released, isFalse);
        expect(controller.document.isLoading, isTrue);

        gateB.complete();
        await loadB;
        await pumpEventQueue();

        expect(released, isTrue);
        expect(controller.document.isLoading, isFalse);
        expect(controller.document.repertoirePgn, contains('1. d4'));
      },
    );
  });

  group('metadata comment upsert', () {
    test('setRootPosition inserts // Root: above the first [Event]', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/a.pgn'));
      controller.board.loadMoveHistory(['e4', 'e5']);

      await controller.document.setRootPosition();

      final written = storage.files['/a.pgn']!;
      final lines = written.split('\n');
      final rootIdx = lines.indexWhere((l) => l.startsWith('// Root:'));
      final eventIdx = lines.indexWhere((l) => l.startsWith('[Event '));
      expect(rootIdx, greaterThanOrEqualTo(0));
      expect(rootIdx, lessThan(eventIdx));
      expect(lines[rootIdx], '// Root: 1. e4 e5');
      expect(controller.document.rootMoves, '1. e4 e5');
    });

    test('an existing // Root: line is replaced, not duplicated', () async {
      storage.files['/b.pgn'] = _blackPgn;
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/b.pgn'));
      controller.board.loadMoveHistory(['d4', 'Nf6', 'c4']);

      await controller.document.setRootPosition();

      final lines = storage.files['/b.pgn']!.split('\n');
      expect(lines.where((l) => l.startsWith('// Root:')), hasLength(1));
      expect(
        lines.firstWhere((l) => l.startsWith('// Root:')),
        '// Root: 1. d4 Nf6 2. c4',
      );
    });

    test('a comment is prepended when the file has no [Event] tag', () async {
      storage.files['/m.pgn'] = '1. e4 e5 *\n';
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/m.pgn'));
      controller.board.loadMoveHistory(['e4']);

      await controller.document.setRootPosition();

      expect(storage.files['/m.pgn'], startsWith('// Root: 1. e4\n'));
    });

    test('setRepertoireColor writes the header and reloads', () async {
      storage.files['/n.pgn'] = '[Event "A"]\n[Result "*"]\n\n1. e4 e5 *\n';
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/n.pgn'));
      expect(controller.document.needsColorSelection, isTrue);

      await controller.document.setRepertoireColor(false);

      expect(storage.files['/n.pgn'], contains('// Color: Black'));
      expect(controller.document.isRepertoireWhite, isFalse);
      expect(controller.document.needsColorSelection, isFalse);
      expect(controller.document.repertoireLines.single.color, 'black');
    });

    test(
      'setRepertoireColor reports a missing file without changing state',
      () async {
        final controller = testBuilderWorkspace();
        await controller.document.setRepertoire(_meta('/gone.pgn'));

        await expectLater(
          controller.document.setRepertoireColor(false),
          throwsStateError,
        );

        expect(controller.document.isRepertoireWhite, isTrue);
        expect(storage.files, isEmpty);
      },
    );
  });

  group('importPgnContent', () {
    test('appends to the file, reloads, and returns the game count', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/a.pgn'));
      expect(controller.document.repertoireLines, hasLength(1));

      final added = await controller.document.importPgnContent(
        '[Event "C"]\n[Result "*"]\n\n1. d4 d5 *\n',
      );

      expect(added, 1);
      expect(storage.files['/a.pgn'], contains('1. d4 d5'));
      expect(controller.document.repertoireLines, hasLength(2));
    });

    test('a pasted study\'s variations are appended as lines', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/a.pgn'));

      final added = await controller.document.importPgnContent(
        '[Event "C"]\n[Result "*"]\n\n1. d4 d5 (1... Nf6 2. c4) 2. c4 *\n',
      );

      expect(added, 2);
      expect(storage.files['/a.pgn'], isNot(contains('(')));
      expect(controller.document.repertoireLines, hasLength(3));
      expect(
        controller.document.repertoireLines.map((l) => l.moves.join(' ')),
        containsAll(['d4 d5 c4', 'd4 Nf6 c4']),
      );
    });

    test('separates the appended games with a blank line', () async {
      storage.files['/a.pgn'] = '[Event "A"]\n[Result "*"]\n\n1. e4 *';
      final controller = testBuilderWorkspace();
      await controller.document.setRepertoire(_meta('/a.pgn'));

      await controller.document.importPgnContent(
        '[Event "C"]\n[Result "*"]\n\n1. d4 *',
      );

      // No trailing newline on the original: two are inserted.
      expect(storage.files['/a.pgn'], contains('1. e4 *\n\n[Event "C"]'));
    });

    test(
      'reports failure and writes nothing when the file is missing',
      () async {
        final controller = testBuilderWorkspace();
        await controller.document.setRepertoire(_meta('/gone.pgn'));

        await expectLater(
          controller.document.importPgnContent('1. e4 *'),
          throwsStateError,
        );
        expect(storage.files, isEmpty);
      },
    );
  });

  group('a superseded load applies nothing', () {
    test('the winner keeps its lines, tree and headers', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.files['/b.pgn'] = _blackPgn;
      final decoder = GatedRepertoireDecoder();
      final controller = testBuilderWorkspace(decoder: decoder);

      final reached = Completer<void>();
      final gate = Completer<void>();
      decoder.afterBuild = () async {
        if (!reached.isCompleted) reached.complete();
        await gate.future;
      };

      final loadA = controller.document.setRepertoire(_meta('/a.pgn'));
      await reached.future.timeout(const Duration(seconds: 5));
      decoder.afterBuild = null;

      await controller.document.setRepertoire(_meta('/b.pgn'));
      final winnerLines = controller.document.repertoireLines;
      final winnerTree = controller.document.openingGraph;

      gate.complete();
      await loadA;

      // A had a full LoadedRepertoire in hand and had to drop all of it —
      // not just the parts an epoch check happened to sit in front of.
      expect(
        identical(controller.document.repertoireLines, winnerLines),
        isTrue,
      );
      expect(identical(controller.document.openingGraph, winnerTree), isTrue);
      expect(controller.document.repertoireLines.single.moves, [
        'd4',
        'Nf6',
        'c4',
        'e6',
      ]);
      expect(controller.document.repertoirePgn, contains('1. d4'));
      expect(controller.document.isRepertoireWhite, isFalse);
      expect(controller.document.rootMoves, '1. d4 Nf6');
      expect(controller.board.moveHistory, ['d4', 'Nf6']);
    });

    test('a superseded failing load leaves no error behind', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.files['/b.pgn'] = _blackPgn;
      storage.failingReads.add('/a.pgn');
      final controller = testBuilderWorkspace();

      final gateA = Completer<void>();
      storage.readGates['/a.pgn'] = gateA;

      final loadA = controller.document.setRepertoire(_meta('/a.pgn'));
      await pumpEventQueue();
      await controller.document.setRepertoire(_meta('/b.pgn'));

      gateA.complete();
      await loadA;

      expect(controller.document.loadError, isNull);
      expect(controller.document.repertoirePgn, contains('1. d4'));
    });
  });

  group('restoreRepertoireFromPgn against an in-flight load', () {
    test('the restore wins and the load is discarded', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final gateA = Completer<void>();
      storage.readGates['/a.pgn'] = gateA;
      final controller = testBuilderWorkspace();

      final loadA = controller.document.setRepertoire(_meta('/a.pgn'));
      await pumpEventQueue();
      expect(controller.document.isLoading, isTrue);

      await controller.document.restoreRepertoireFromPgn(_restoredPgn);

      gateA.complete();
      await loadA;

      expect(controller.document.repertoirePgn, contains('1. c4'));
      expect(controller.document.repertoireLines.single.moves, ['c4', 'e5']);
    });

    test(
      'restore clears loading while the discarded command settles independently',
      () async {
        storage.files['/a.pgn'] = _whitePgn;
        final gateA = Completer<void>();
        storage.readGates['/a.pgn'] = gateA;
        final controller = testBuilderWorkspace();

        final loadA = controller.document.setRepertoire(_meta('/a.pgn'));
        await pumpEventQueue();
        var released = false;
        unawaited(loadA.then((_) => released = true));

        await controller.document.restoreRepertoireFromPgn(_restoredPgn);
        await pumpEventQueue();

        // The restored document is ready even while the superseded I/O remains
        // pending; completing that I/O must not replace it.
        expect(released, isFalse);
        expect(controller.document.isLoading, isFalse);

        gateA.complete();
        await loadA;
        expect(released, isTrue);
        expect(controller.document.isLoading, isFalse);
      },
    );

    test('a restore with no load in flight does not touch isLoading', () async {
      final controller = testBuilderWorkspace();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.document.restoreRepertoireFromPgn(_restoredPgn);

      expect(controller.document.isLoading, isFalse);
      expect(notifications, 1, reason: 'one notify for the restore itself');
    });
  });
}
