import 'dart:async';
import 'package:chess_auto_prep/features/documents/controllers/viewer_session_controller.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_session.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_preferences_repository.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';

const first = ViewerSession(
  gameIndex: 0,
  gameKey: 'game',
  ply: 3,
  sortMode: GameSortMode.fileOrder,
);
const second = ViewerSession(
  gameIndex: 0,
  gameKey: 'game',
  ply: 7,
  sortMode: GameSortMode.fileOrder,
);

class MemoryPreferences implements ViewerPreferencesRepository {
  final sessions = <String, ViewerSession>{};
  final writes = <String>[];
  String? last;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<void> saveSession(String path, ViewerSession session) async {
    writes.add('$path:${session.ply}');
    await gate?.future;
    if (fail) {
      fail = false;
      throw StateError('disk unavailable');
    }
    sessions[path] = session;
    last = path;
  }

  @override
  Future<void> closeSession() async {
    writes.add('close');
    last = null;
  }

  @override
  Future<String?> lastFile() async => last;
  @override
  Future<ViewerSession?> loadSession(String path) async => sessions[path];
  @override
  Future<bool> autoDetectOpenings() async => false;
  @override
  Future<List<String>> loadRecentFiles() async => [];
  @override
  Future<void> saveRecentFiles(List<String> paths) async {}
  @override
  Future<SliceConfig?> loadSlice(String path) async => null;
  @override
  Future<void> saveSlice(String path, SliceConfig config) async {}
}

void main() {
  test(
    'failed checkpoints stay retryable and do not poison later saves',
    () async {
      final repo = MemoryPreferences()..fail = true;
      final owner = ViewerSessionController(repo);
      expect(await owner.save('first.pgn', first), isFalse);
      expect(owner.error, isA<StateError>());
      expect(await owner.flush(), isFalse);
      expect(await owner.save('first.pgn', first), isTrue);
      expect(owner.error, isNull);
      expect(repo.sessions['first.pgn'], same(first));
      expect(await owner.save('first.pgn', first), isTrue);
      expect(repo.writes, ['first.pgn:3', 'first.pgn:3']);
    },
  );

  test(
    'queued writes capture their path and cursor; close cannot reopen a file',
    () async {
      final repo = MemoryPreferences()..gate = Completer<void>();
      final owner = ViewerSessionController(repo);
      final a = owner.save('a.pgn', first);
      final b = owner.save('b.pgn', second);
      final closing = owner.close();
      final last = owner.lastFile();
      await Future<void>.delayed(Duration.zero);
      expect(repo.writes, ['a.pgn:3']);
      repo.gate!.complete();
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(await closing, isTrue);
      expect(await last, isNull);
      expect(repo.writes, ['a.pgn:3', 'b.pgn:7', 'close']);
      expect(repo.sessions['a.pgn']!.ply, 3);
      expect(repo.sessions['b.pgn']!.ply, 7);
      // An explicit reopen after close must publish the last-file pointer again.
      expect(await owner.save('b.pgn', second), isTrue);
      expect(await owner.lastFile(), 'b.pgn');
    },
  );

  test('immediate reads await the captured write queue', () async {
    final repo = MemoryPreferences()..gate = Completer<void>();
    final owner = ViewerSessionController(repo);
    final save = owner.save('a.pgn', second);
    final reading = owner.load('a.pgn');
    var readFinished = false;
    unawaited(reading.then((_) => readFinished = true));
    await Future<void>.delayed(Duration.zero);
    expect(readFinished, isFalse);
    repo.gate!.complete();
    expect(await save, isTrue);
    expect((await reading)!.ply, 7);
  });

  test(
    'a failed write cannot suppress a later already-queued checkpoint',
    () async {
      final repo = MemoryPreferences()..fail = true;
      final owner = ViewerSessionController(repo);
      final failed = owner.save('a.pgn', first);
      final next = owner.save('a.pgn', second);
      expect(await failed, isFalse);
      expect(await next, isTrue);
      expect((await owner.load('a.pgn'))!.ply, 7);
    },
  );
}
