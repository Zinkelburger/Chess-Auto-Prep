import 'package:flutter/services.dart';
import '../features/players/prep_sheet.dart';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:dartchess/dartchess.dart' show Side;
import '../chess/pgn/chapter.dart';
import '../chess/pgn/study.dart';
import '../storage/pgn_document_store.dart';
import '../ui/file_names.dart';

import '../chess/players/player.dart';
import '../chess/players/download_range.dart';
import '../features/players/player_analysis.dart';
import '../features/players/player_hunt.dart';
import '../features/players/player_book.dart';
import '../features/players/players.dart';
import '../features/study/studies.dart';
import '../storage/chapter_files.dart';
import '../storage/my_games_files.dart';
import '../storage/my_accounts.dart';
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
    hunt = PlayerHunt(
      analysis,
      () => env.startEngine(),
      model: env.maia,
      reports: env.playerReports,
    );
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
      final saved = [...await env.savedPlayerList()];
      final accounts = await env.accounts.snapshot();
      if (accounts is AccountsSnapshot) {
        saved.addAll([
          for (final a in accounts.accounts.entries)
            Player.create(
              a.value.username,
            ).edited({a.key.name: a.value.username}),
        ]);
      }
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
  Future<void> download(PlayerDownloadRange range) async {
    final chosen = analysis.player;
    if (chosen == null || analysis.busy) return;
    final current =
        directory.players.where((p) => p.id == chosen.id).firstOrNull ?? chosen;
    final next = current.edited({'download': range.json});
    if (await directory.save(next, expected: current) &&
        !_disposed &&
        analysis.player?.id == chosen.id)
      await analysis.select(next, download: true);
  }

  Future<void> importPgn() async {
    final player = analysis.player;
    if (player == null) return;
    final path = await env.viewerPicker.pickPgn();
    if (path == null || _disposed) return;
    final imported = await env.fileImport.insideDocuments(path);
    if (_disposed) return;
    switch (imported) {
      case FileToOpen(:final path):
        final current = directory.players
            .where((p) => p.id == player.id)
            .firstOrNull;
        if (current == null) return;
        final next = current.edited({
          'pgn_files': {...current.files, path}.toList(),
        });
        if (await directory.save(next, expected: current) &&
            !_disposed &&
            analysis.player?.id == player.id)
          await analysis.select(next);
      case ImportFailed(:final detail):
        requests.say(detail);
    }
  }

  Future<ChapterRef?> _study(Player player) async {
    player =
        directory.players.where((p) => p.id == player.id).firstOrNull ?? player;
    if (player.text('prep_file').isNotEmpty)
      return ChapterRef.at(player.text('prep_file'));
    final name = 'Prep – ${player.name}';
    final ref = ChapterRef.at(
      p.join(
        env.folders.studies,
        '${safeFileName(name, fallback: 'Prep-${player.id}')}.pgn',
      ),
    );
    final text = [
      for (final side in Side.values)
        newStudyChapterText(
          study: name,
          chapter: side == Side.white ? 'As White' : 'As Black',
          orientation: side,
        ),
    ].join('\n\n');
    final made = await env.store.create(ref, '$text\n');
    if (_disposed) return null;
    if (made is! Created) {
      requests.say(
        'Could not create the prep study. A file with that name may already exist; use Link study to open it.',
      );
      return null;
    }
    unawaited(studies.refresh());
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

  Future<void> linkStudy(Player player) async {
    final path = await env.viewerPicker.pickPgn(startIn: env.folders.studies);
    if (_disposed || path == null) return;
    final imported = await env.fileImport.insideDocuments(path);
    if (_disposed) return;
    if (imported is ImportFailed) {
      requests.say(imported.detail);
      return;
    }
    final inside = (imported as FileToOpen).path;
    final current = directory.players
        .where((p) => p.id == player.id)
        .firstOrNull;
    if (current == null) return;
    player = current;
    final links = player.fields['studies'] as List? ?? const [];
    if (links.any((e) => e is Map && e['path'] == inside)) return;
    await directory.save(
      player.edited({
        'studies': [
          ...links,
          {'path': inside},
        ],
      }),
      expected: player,
    );
  }

  Future<void> openLinkedStudy(String path, String? chapter) async {
    final ref = ChapterRef.at(path);
    var index = 0;
    if (chapter != null) {
      final read = await env.store.open(ref);
      if (read is! Opened || _disposed) {
        requests.say('This linked study could not be read.');
        return;
      }
      final parsed = await readChapter(name: ref.name, text: read.text);
      final match = studyChapters(
        parsed.lines,
      ).where((c) => c.name == chapter).firstOrNull;
      if (match == null) {
        requests.say(
          'The linked chapter "$chapter" is no longer in this study.',
        );
        return;
      }
      index = match.index;
    }
    if (_disposed) return;
    requests.switchTo(Mode.study);
    await requests.open(ref, game: index);
  }

  Future<void> openGroupStudy(PlayerGroup group) async {
    if (group.fields['study'] case final String path when path.isNotEmpty) {
      await openLinkedStudy(path, null);
      return;
    }
    final name = 'Prep – ${group.name}';
    final chapters = <String>[];
    try {
      for (final person in directory.players.where(
        (p) => group.contains(p.id),
      )) {
        if (person.text('prep_file').isEmpty) continue;
        final read = await env.store.open(
          ChapterRef.at(person.text('prep_file')),
        );
        if (read is! Opened)
          throw StateError('Could not read ${person.name}’s prep study.');
        final study = await readChapter(name: person.name, text: read.text);
        for (final chapter in studyChapters(study.lines)) {
          final tree = study.lines[chapter.index].tree;
          if (tree == null || tree.isEmpty) continue;
          chapters.add(
            newStudyChapterText(
              study: name,
              chapter: '${person.name} · ${chapter.name}',
              orientation: chapter.orientation,
              root: tree.rootFen,
              moves: tree,
            ),
          );
        }
      }
      if (_disposed) return;
      if (chapters.isEmpty)
        chapters.add(newStudyText(study: name, chapter: 'Preparation'));
      final ref = ChapterRef.at(
        p.join(
          env.folders.studies,
          '${safeFileName(name, fallback: 'Group-${group.id}')}.pgn',
        ),
      );
      final made = await env.store.create(ref, '${chapters.join('\n\n')}\n');
      if (made is! Created)
        throw StateError(
          'A study with this name already exists. Rename the group or link its existing study.',
        );
      if (_disposed) return;
      if (!await directory.saveGroup(
        group.edited({'study': ref.path}),
        expected: group,
      ))
        return;
      await studies.refresh();
      await openLinkedStudy(ref.path, null);
    } on Object catch (e) {
      if (!_disposed) requests.say('$e');
    }
  }

  Future<void> exportGroup(PlayerGroup group, {bool copy = false}) async {
    try {
      final text = await prepSheet(group, directory.players, env.store);
      if (_disposed) return;
      if (copy) {
        await Clipboard.setData(ClipboardData(text: text));
        if (!_disposed)
          requests.say('Prep sheet copied, including saved lines.');
        return;
      }
      final exporter = env.exportText;
      if (exporter == null) {
        requests.say('File export is unavailable. Use Copy prep sheet.');
        return;
      }
      final path = await exporter(
        '${safeFileName(group.name, fallback: 'Prep-sheet')}.md',
        text,
      );
      if (!_disposed && path != null) requests.say('Saved $path');
    } on Object catch (e) {
      if (!_disposed) requests.say('Could not export the prep sheet: $e');
    }
  }

  Future<void> saveLine() async {
    final player = analysis.player;
    if (player == null) return;
    final side = analysis.side.opposite;
    // Capture the line on the shared analysis board before opening the study.
    if (await requests.newAnalysisBoard() is! RequestDone || _disposed) return;
    final ref = await _study(player);
    if (_disposed || ref == null) return;
    await requests.saveBoardToStudy(ref, '${player.name} · As ${side.name}');
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
