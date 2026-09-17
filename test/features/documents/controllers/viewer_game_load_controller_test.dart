import 'dart:async';
import 'package:chess_auto_prep/features/documents/models/viewer_game_load_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_game_controller.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_game_load_controller.dart';
import 'package:chess_auto_prep/features/documents/repositories/stored_game_repository.dart';

class _Archive implements StoredGameRepository {
  final reads = <String, Completer<String?>>{};
  @override
  Future<String?> findById(String id) =>
      (reads[id] = Completer<String?>()).future;
}

void main() {
  late _Archive archive;
  late ViewerGameController game;
  late ViewerGameLoadController loader;
  setUp(() {
    archive = _Archive();
    game = ViewerGameController();
    loader = ViewerGameLoadController(game: game, storedGames: archive);
  });

  test('newest request owns the game regardless of completion order', () async {
    final first = loader.load(gameId: 'old', pgnText: '1. a3 *');
    final revision = loader.revision;
    final second = loader.load(gameId: 'new', pgnText: '1. h3 *');
    archive.reads['new']!.complete('1. d4 d5 *');
    expect(await second, isTrue);
    final session = game.session;
    game.goToMainLineMove(2);
    archive.reads['old']!.complete('1. e4 e5 *');
    expect(await first, isFalse);
    expect(loader.isCurrent(revision), isFalse);
    expect(game.session, same(session));
    expect(game.mainLineIndex, 2);
    expect(game.moveHistory.map((m) => m.san), ['d4', 'd5']);
  });

  test('late read failure cannot replace a successful state', () async {
    final old = loader.load(gameId: 'old');
    expect(await loader.load(pgnText: '1. c4 *'), isTrue);
    archive.reads['old']!.completeError(StateError('offline'));
    expect(await old, isFalse);
    expect(loader.failure, isNull);
    expect(loader.isLoading, isFalse);
    expect(game.moveHistory.single.san, 'c4');
  });

  test('missing source uses the request fallback', () async {
    final pending = loader.load(gameId: 'missing', pgnText: '1. Nf3 *');
    archive.reads['missing']!.complete(null);
    expect(await pending, isTrue);
    expect(game.moveHistory.single.san, 'Nf3');
  });

  test('unavailable archive keeps a supplied solution usable', () async {
    final pending = loader.load(gameId: 'offline', pgnText: '1. g3 *');
    archive.reads['offline']!.completeError(StateError('offline'));
    expect(await pending, isTrue);
    expect(loader.failure, isNull);
    expect(game.moveHistory.single.san, 'g3');
  });

  test(
    'missing and failed reads have distinct outcomes and can retry',
    () async {
      var pending = loader.load(gameId: 'game');
      archive.reads['game']!.complete(null);
      expect(await pending, isFalse);
      expect(loader.failure, ViewerGameLoadFailure.notFound);
      pending = loader.load(gameId: 'game');
      archive.reads['game']!.completeError(StateError('offline'));
      expect(await pending, isFalse);
      expect(loader.failure, ViewerGameLoadFailure.archiveUnavailable);
      pending = loader.load(gameId: 'game');
      archive.reads['game']!.complete('1. e4 *');
      expect(await pending, isTrue);
      expect(loader.failure, isNull);
    },
  );

  test('an empty selection revokes an outstanding read', () async {
    final pending = loader.load(gameId: 'old');
    expect(await loader.load(pgnText: '  '), isFalse);
    archive.reads['old']!.complete('1. e4 *');
    expect(await pending, isFalse);
    expect(loader.failure, ViewerGameLoadFailure.noInput);
    expect(game.game, isNull);
  });

  test('dispose revokes pending reads and prohibits new reads', () async {
    final pending = loader.load(gameId: 'old');
    final revision = loader.revision;
    loader.dispose();
    archive.reads['old']!.complete('1. e4 *');
    expect(await pending, isFalse);
    expect(await loader.load(gameId: 'new'), isFalse);
    expect(loader.isCurrent(revision), isFalse);
    expect(archive.reads.keys, ['old']);
    expect(game.game, isNull);
  });

  test('text-only use needs no archive and empty IDs skip it', () async {
    final textLoader = ViewerGameLoadController(game: game);
    expect(await textLoader.load(gameId: '', pgnText: '1. e4 *'), isTrue);
    expect(await textLoader.load(gameId: 'unconfigured'), isFalse);
    expect(textLoader.failure, ViewerGameLoadFailure.archiveUnavailable);
    expect(archive.reads, isEmpty);
  });
}
