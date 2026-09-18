import 'package:chess_auto_prep/features/documents/controllers/viewer_collection_controller.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/controllers/pgn_fen_index.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_opening_tree.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_solitaire_session.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_computation.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_position_index_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_opening_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_solitaire_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_viewer_position_index_repository.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';

class Work<T> implements ViewerComputation<T> {
  final completion = Completer<T>();
  bool cancelled = false;
  @override
  Future<T> get result => completion.future;
  @override
  void cancel() => cancelled = true;
}

class IndexRepository implements ViewerPositionIndexRepository {
  final work = Work<Map<String, List<int>>>();
  List<GameRecord>? captured;
  int saves = 0;
  @override
  ViewerComputation<Map<String, List<int>>> build(List<GameRecord> source) {
    captured = source;
    return work;
  }

  @override
  Future<Map<String, List<int>>?> load(
    String path,
    List<GameRecord> source,
  ) async => null;
  @override
  Future<void> save(
    String path,
    List<GameRecord> source,
    Map<String, List<int>> index,
  ) async {
    saves++;
  }
}

class OpeningRepository implements ViewerOpeningRepository {
  final work = Work<ViewerOpeningResult>();
  late void Function(int, int) progress;
  @override
  ViewerComputation<ViewerOpeningResult> buildTree(
    List<GameRecord> source, {
    required bool includeVariations,
    required void Function(int, int) onProgress,
  }) {
    progress = onProgress;
    return work;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class SolitaireRepository implements ViewerSolitaireRepository {
  final pending = Completer<ViewerSolitaireSettings>();
  @override
  Future<ViewerSolitaireSettings> load() => pending.future;
  @override
  Future<void> saveRevealDelay(int seconds) async {}
  @override
  Future<void> saveIncludeVariations(bool value) async {}
}

class Handle implements PgnViewerHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class MemoryStorage implements StorageService {
  final files = <String, String>{};
  @override
  Future<String?> readFile(String path) async => files[path];
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    files[path] = content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const source = [
  (headers: <String, String>{'Event': 'A'}, pgnText: '[Event "A"]\n\n1. e4 *'),
];

void main() {
  test(
    'index reset cancels work and refuses late adoption or cache writes',
    () async {
      final repository = IndexRepository();
      var changes = 0;
      final owner = PgnFenIndex(
        repository: repository,
        isActive: () => true,
        onChanged: () => changes++,
      );
      final pending = owner.build(source, filePath: '/a');
      owner.reset();
      expect(repository.work.cancelled, isTrue);
      repository.work.completion.complete({
        'fen': [0],
      });
      await pending;
      expect(owner.value, isNull);
      expect(changes, 0);
      expect(repository.saves, 0);
    },
  );
  test(
    'index captures source headers and publishes deeply immutable data',
    () async {
      final repository = IndexRepository();
      final owner = PgnFenIndex(
        repository: repository,
        isActive: () => true,
        onChanged: () {},
      );
      final headers = {'Event': 'A'};
      final pending = owner.build([
        (headers: headers, pgnText: '1. e4 *'),
      ], filePath: null);
      headers['Event'] = 'B';
      final indices = [0];
      repository.work.completion.complete({'fen': indices});
      await pending;
      indices.add(4);
      expect(repository.captured!.single.headers['Event'], 'A');
      expect(owner.value!['fen'], [0]);
      expect(() => owner.value!.clear(), throwsUnsupportedError);
      expect(() => owner.value!['fen']!.clear(), throwsUnsupportedError);
    },
  );
  test(
    'cached index is tied to source text rather than current file metadata',
    () async {
      final storage = MemoryStorage();
      final repository = StorageViewerPositionIndexRepository(storage);
      await repository.save('/a', source, {
        'fen': [0],
      });
      expect(await repository.load('/a', source), {
        'fen': [0],
      });
      final changed = [
        (headers: source.single.headers, pgnText: '[Event "A"]\n\n1. d4 *'),
      ];
      expect(await repository.load('/a', changed), isNull);
      // A late old-session cache write cannot label changed games with old hits.
      await repository.save('/a', changed, {
        'other': [0],
      });
      await repository.save('/a', source, {
        'fen': [0],
      });
      expect(await repository.load('/a', changed), isNull);
    },
  );
  test(
    'opening-tree disposal cancels worker and rejects progress and board adoption',
    () async {
      final repository = OpeningRepository();
      var changes = 0;
      var positions = 0;
      final games = [PgnGameEntry(headers: {}, pgnText: '1. e4 *')];
      final owner = ViewerOpeningTree(
        repository: repository,
        isActive: () => true,
        onChanged: () => changes++,
        collection: ViewerCollectionController()..adopt(games),
        fenIndex: () => null,
        currentFen: () => OpeningTree().root.fen,
        applyPosition: (_) => positions++,
      );
      final pending = owner.enter();
      owner.dispose();
      final before = changes;
      repository.progress(1, 1);
      repository.work.completion.complete((
        tree: OpeningTree(),
        mainlineIndex: null,
      ));
      await pending;
      expect(repository.work.cancelled, isTrue);
      expect(changes, before);
      expect(positions, 0);
      expect(owner.openingTree, isNull);
    },
  );
  test(
    'late solitaire settings cannot overwrite a newer committed preference',
    () async {
      final repository = SolitaireRepository();
      final owner = ViewerSolitaireSession(
        repository: repository,
        onError: (_) {},
        handle: Handle(),
        hasGames: () => false,
        userPlaysWhite: () => true,
        stopAutoPlay: () {},
        onChanged: () {},
      );
      final load = owner.loadSettings();
      await owner.setRevealDelay(12);
      repository.pending.complete((
        revealDelaySeconds: 60,
        includeVariations: false,
        trophyCount: 0,
      ));
      await load;
      expect(owner.controller.revealDelaySec, 12);
      owner.dispose();
    },
  );
  test('solitaire disposal prevents delayed settings adoption', () async {
    final repository = SolitaireRepository();
    final owner = ViewerSolitaireSession(
      repository: repository,
      onError: (_) {},
      handle: Handle(),
      hasGames: () => false,
      userPlaysWhite: () => true,
      stopAutoPlay: () {},
      onChanged: () {},
    );
    final load = owner.loadSettings();
    owner.dispose();
    repository.pending.complete((
      revealDelaySeconds: 12,
      includeVariations: true,
      trophyCount: 17,
    ));
    await load;
    expect(owner.totalTrophyCount, 0);
    expect(owner.controller.revealDelaySec, 60);
  });
}
