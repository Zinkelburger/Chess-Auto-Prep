import 'dart:async';

import '../chess/players/player.dart';
import '../features/players/player_analysis.dart';
import '../features/players/player_hunt.dart';
import '../features/players/player_book.dart';
import '../features/players/players.dart';
import '../features/study/studies.dart';
import '../storage/chapter_files.dart';
import '../storage/my_games_files.dart';
import '../storage/pgn_file_import.dart';
import '../workspace/workspace.dart';
import 'environment.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// Composition and cross-mode doors for the shared player directory and corpus.
final class PlayerModes {
  PlayerModes(
    this.env,
    this.workspace,
    this.requests,
    this.studies,
    GamesCache cache,
  ) {
    directory = Players(
      env.players,
      env.pendingWrites,
      lookupRating: env.playerRating,
    );
    analysis = PlayerAnalysis(
      documents: env.store,
      archive: env.gameStore,
      cache: cache,
      sites: env.gameSites,
      pending: env.pendingWrites,
      collections: env.folders.collections,
    );
    hunt = PlayerHunt(analysis, () => env.startEngine());
    book = PlayerBook(analysis, workspace.shelf, workspace.books);
  }
  final AppEnvironment env;
  final Workspace workspace;
  final WorkspaceRequests requests;
  final Studies studies;
  late final Players directory;
  late final PlayerAnalysis analysis;
  late final PlayerHunt hunt;
  late final PlayerBook book;
  bool _disposed = false;

  void choose(Player player) {
    hunt.stop();
    requests.switchTo(Mode.playerAnalysis);
    unawaited(analysis.select(player));
  }

  Future<void> addSavedPlayers() async {
    try {
      final saved = await env.savedPlayerList();
      if (_disposed) return;
      if (saved.isEmpty) {
        requests.say('No older player game sets were found.');
        return;
      }
      await directory.import(saved);
    } on Object catch (e) {
      if (!_disposed) requests.say('Could not read saved players: $e');
    }
  }

  void showDirectory() => requests.switchTo(Mode.players);
  Future<void> importPgn() async {
    final player = analysis.player;
    if (player == null) return;
    final path = await env.viewerPicker.pickPgn();
    if (path == null || _disposed) return;
    final imported = await env.fileImport.insideDocuments(path);
    if (_disposed) return;
    switch (imported) {
      case FileToOpen(:final path):
        final next = player.edited({
          'pgn_files': {...player.files, path}.toList(),
        });
        if (await directory.save(next, expected: player) && !_disposed)
          await analysis.select(next);
      case ImportFailed(:final detail):
        requests.say(detail);
    }
  }

  Future<ChapterRef?> _study(Player player) async {
    if (player.text('prep_file').isNotEmpty)
      return ChapterRef.at(player.text('prep_file'));
    final made = await studies.create('Prep – ${player.name}');
    if (_disposed) return null;
    if (made is StudyProblem) {
      requests.say(made.sentence);
      return null;
    }
    final ref = (made as StudyDone).opened;
    if (ref == null) return null;
    final saved = await directory.save(
      player.edited({'prep_file': ref.path}),
      expected: player,
    );
    if (!saved) {
      requests.say(
        'The study was created, but its player link was not saved. Retry the player save.',
      );
      return null;
    }
    return ref;
  }

  Future<void> openStudy(Player player) async {
    final ref = await _study(player);
    if (_disposed || ref == null) return;
    requests.switchTo(Mode.study);
    await requests.open(ref, game: 0);
  }

  Future<void> saveLine() async {
    final player = analysis.player;
    if (player == null) return;
    // Capture the line on the shared analysis board before opening the study.
    if (await requests.newAnalysisBoard() is! RequestDone || _disposed) return;
    final ref = await _study(player);
    if (_disposed || ref == null) return;
    await requests.saveBoardToStudy(
      ref,
      '${player.name} · As ${analysis.side.opposite.name}',
    );
  }

  void stop() {
    directory.stopLookup();
    analysis.cancel();
    hunt.stop();
  }

  void dispose() {
    _disposed = true;
    book.dispose();
    hunt.dispose();
    analysis.dispose();
    directory.dispose();
  }
}
