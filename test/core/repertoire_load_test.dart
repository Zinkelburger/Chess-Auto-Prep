/// Characterisation tests for the repertoire *load* path.
///
/// These pin the behaviour of `loadRepertoire` / `awaitLoaded` before the
/// persistence mixin is broken out into a real collaborator: what a missing
/// file leaves behind, what a read failure reports, which state a *superseded*
/// load is allowed to touch, and when `awaitLoaded()` is released.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/core/repertoire_writer.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
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
  Future<void> writeFile(String path, String content) async {
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
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/a.pgn'));
      expect(controller.repertoireLines, isNotEmpty);

      await controller.setRepertoire(_meta('/gone.pgn'));

      expect(controller.repertoirePgn, isNull);
      expect(controller.openingTree, isNull);
      expect(controller.repertoireLines, isEmpty);
      expect(controller.moveHistory, isEmpty);
      expect(controller.loadError, isNull);
    });

    test('a missing file leaves the colour headers of the last load', () async {
      storage.files['/b.pgn'] = _blackPgn;
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/b.pgn'));
      expect(controller.isRepertoireWhite, isFalse);
      expect(controller.rootMoves, '1. d4 Nf6');

      await controller.setRepertoire(_meta('/gone.pgn'));

      // The missing-file branch never re-derives the headers, so they survive.
      expect(controller.isRepertoireWhite, isFalse);
      expect(controller.rootMoves, '1. d4 Nf6');
    });

    test('a read failure is reported through loadError', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.failingReads.add('/a.pgn');
      final controller = RepertoireController();

      await controller.setRepertoire(_meta('/a.pgn'));

      expect(controller.loadError, startsWith('Failed to load repertoire:'));
      expect(controller.repertoirePgn, isNull);
      expect(controller.openingTree, isNull);
      expect(controller.repertoireLines, isEmpty);
      expect(controller.isLoading, isFalse);
    });

    test('a later successful load clears a previous loadError', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.failingReads.add('/a.pgn');
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/a.pgn'));
      expect(controller.loadError, isNotNull);

      storage.failingReads.clear();
      await controller.loadRepertoire();

      expect(controller.loadError, isNull);
      expect(controller.repertoireLines, hasLength(1));
    });

    test('an empty file yields an empty opening tree and no lines', () async {
      storage.files['/empty.pgn'] = '';
      final controller = RepertoireController();

      await controller.setRepertoire(_meta('/empty.pgn'));

      expect(controller.repertoirePgn, '');
      expect(controller.openingTree, isNotNull);
      expect(controller.openingTree!.totalGames, 0);
      expect(controller.repertoireLines, isEmpty);
    });

    test('a PGN with no // Color: comment asks for colour selection', () async {
      storage.files['/n.pgn'] = '[Event "A"]\n[Result "*"]\n\n1. e4 e5 *\n';
      final controller = RepertoireController();

      await controller.setRepertoire(_meta('/n.pgn'));

      expect(controller.needsColorSelection, isTrue);
      // Absent a header the repertoire is treated as White.
      expect(controller.isRepertoireWhite, isTrue);
    });

    test(
      'a // Color: Black header flips the side and clears the prompt',
      () async {
        storage.files['/b.pgn'] = _blackPgn;
        final controller = RepertoireController();

        await controller.setRepertoire(_meta('/b.pgn'));

        expect(controller.needsColorSelection, isFalse);
        expect(controller.isRepertoireWhite, isFalse);
        expect(controller.repertoireLines.single.color, 'black');
      },
    );

    test('a load navigates to the saved // Root: position', () async {
      storage.files['/b.pgn'] = _blackPgn;
      final controller = RepertoireController();

      await controller.setRepertoire(_meta('/b.pgn'));

      expect(controller.moveHistory, ['d4', 'Nf6']);
      expect(controller.isAtRootPosition, isTrue);
    });

    test('a load drops the undo stack', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = RepertoireController();
      controller.writer.pushUndo(
        const UndoOperation(
          previousPgn: 'x',
          treePathBeforeAdd: [],
          moveAdded: 'e4',
        ),
      );
      expect(controller.writer.canUndo, isTrue);

      await controller.setRepertoire(_meta('/a.pgn'));

      expect(controller.writer.canUndo, isFalse);
    });

    test('a headerless PGN body still builds a tree', () async {
      // No [Event] tags at all: the game-splitter still yields movetext.
      storage.files['/m.pgn'] = '// Color: White\n\n1. e4 e5 2. Nf3 Nc6 *\n';
      final controller = RepertoireController();

      await controller.setRepertoire(_meta('/m.pgn'));

      expect(controller.openingTree, isNotNull);
      expect(controller.needsColorSelection, isFalse);
    });
  });

  group('awaitLoaded', () {
    test('resolves immediately when no load is in flight', () async {
      final controller = RepertoireController();
      await controller.awaitLoaded().timeout(const Duration(seconds: 1));
    });

    test('is held open for the duration of a load', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final gate = Completer<void>();
      storage.readGates['/a.pgn'] = gate;
      final controller = RepertoireController();

      final load = controller.setRepertoire(_meta('/a.pgn'));
      await pumpEventQueue();
      expect(controller.isLoading, isTrue);

      var released = false;
      unawaited(controller.awaitLoaded().then((_) => released = true));
      await pumpEventQueue();
      expect(released, isFalse, reason: 'the load has not finished yet');

      gate.complete();
      await load;
      await pumpEventQueue();

      expect(released, isTrue);
      expect(controller.isLoading, isFalse);
      expect(controller.repertoireLines, hasLength(1));
    });

    test('a superseded load does not release the waiters early', () async {
      storage.files['/a.pgn'] = _whitePgn;
      storage.files['/b.pgn'] = _blackPgn;
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      storage.readGates['/a.pgn'] = gateA;
      storage.readGates['/b.pgn'] = gateB;
      final controller = RepertoireController();

      final loadA = controller.setRepertoire(_meta('/a.pgn'));
      await pumpEventQueue();
      final loadB = controller.setRepertoire(_meta('/b.pgn'));
      await pumpEventQueue();

      var released = false;
      unawaited(controller.awaitLoaded().then((_) => released = true));

      // A loses the race and must not clear `isLoading` out from under B.
      gateA.complete();
      await loadA;
      await pumpEventQueue();
      expect(released, isFalse);
      expect(controller.isLoading, isTrue);

      gateB.complete();
      await loadB;
      await pumpEventQueue();

      expect(released, isTrue);
      expect(controller.isLoading, isFalse);
      expect(controller.repertoirePgn, contains('1. d4'));
    });
  });

  group('metadata comment upsert', () {
    test('setRootPosition inserts // Root: above the first [Event]', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/a.pgn'));
      controller.loadMoveHistory(['e4', 'e5']);

      await controller.setRootPosition();

      final written = storage.files['/a.pgn']!;
      final lines = written.split('\n');
      final rootIdx = lines.indexWhere((l) => l.startsWith('// Root:'));
      final eventIdx = lines.indexWhere((l) => l.startsWith('[Event '));
      expect(rootIdx, greaterThanOrEqualTo(0));
      expect(rootIdx, lessThan(eventIdx));
      expect(lines[rootIdx], '// Root: 1. e4 e5');
      expect(controller.rootMoves, '1. e4 e5');
    });

    test('an existing // Root: line is replaced, not duplicated', () async {
      storage.files['/b.pgn'] = _blackPgn;
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/b.pgn'));
      controller.loadMoveHistory(['d4', 'Nf6', 'c4']);

      await controller.setRootPosition();

      final lines = storage.files['/b.pgn']!.split('\n');
      expect(lines.where((l) => l.startsWith('// Root:')), hasLength(1));
      expect(
        lines.firstWhere((l) => l.startsWith('// Root:')),
        '// Root: 1. d4 Nf6 2. c4',
      );
    });

    test('a comment is prepended when the file has no [Event] tag', () async {
      storage.files['/m.pgn'] = '1. e4 e5 *\n';
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/m.pgn'));
      controller.loadMoveHistory(['e4']);

      await controller.setRootPosition();

      expect(storage.files['/m.pgn'], startsWith('// Root: 1. e4\n'));
    });

    test('setRepertoireColor writes the header and reloads', () async {
      storage.files['/n.pgn'] = '[Event "A"]\n[Result "*"]\n\n1. e4 e5 *\n';
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/n.pgn'));
      expect(controller.needsColorSelection, isTrue);

      await controller.setRepertoireColor(false);

      expect(storage.files['/n.pgn'], contains('// Color: Black'));
      expect(controller.isRepertoireWhite, isFalse);
      expect(controller.needsColorSelection, isFalse);
      expect(controller.repertoireLines.single.color, 'black');
    });

    test('setRepertoireColor on a missing file is a no-op', () async {
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/gone.pgn'));

      await controller.setRepertoireColor(false);

      expect(controller.isRepertoireWhite, isTrue);
      expect(storage.files, isEmpty);
    });
  });

  group('importPgnContent', () {
    test('appends to the file, reloads, and returns the game count', () async {
      storage.files['/a.pgn'] = _whitePgn;
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/a.pgn'));
      expect(controller.repertoireLines, hasLength(1));

      final added = await controller.importPgnContent(
        '[Event "C"]\n[Result "*"]\n\n1. d4 d5 *\n',
      );

      expect(added, 1);
      expect(storage.files['/a.pgn'], contains('1. d4 d5'));
      expect(controller.repertoireLines, hasLength(2));
    });

    test('separates the appended games with a blank line', () async {
      storage.files['/a.pgn'] = '[Event "A"]\n[Result "*"]\n\n1. e4 *';
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/a.pgn'));

      await controller.importPgnContent('[Event "C"]\n[Result "*"]\n\n1. d4 *');

      // No trailing newline on the original: two are inserted.
      expect(storage.files['/a.pgn'], contains('1. e4 *\n\n[Event "C"]'));
    });

    test('returns 0 and writes nothing when the file is missing', () async {
      final controller = RepertoireController();
      await controller.setRepertoire(_meta('/gone.pgn'));

      final added = await controller.importPgnContent('1. e4 *');

      expect(added, 0);
      expect(storage.files, isEmpty);
    });
  });
}
