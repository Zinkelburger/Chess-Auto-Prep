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
import '../features/players/saved_games.dart';
import '../features/study/studies.dart';
import '../features/trainer/trainer.dart';
import '../storage/chapter_files.dart';
import '../storage/my_games_files.dart';
import '../storage/my_accounts.dart';
import '../storage/pgn_file_import.dart';
import '../workspace/study_drafts.dart';
import '../workspace/study_choice.dart';
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
    this.trainer,
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
      archiveCopies: p.join(env.folders.gamesLibrary, 'player_archives'),
    );
    hunt = PlayerHunt(
      analysis,
      () => env.startEngine(),
      model: env.maia,
      reports: env.playerReports,
    );
    book = PlayerBook(analysis, workspace.shelf, workspace.books);
    saved = SavedGames(
      directory,
      cache,
      env.store,
      env.playerReports,
      env.accounts,
    );
  }
  final AppEnvironment env;
  final Workspace workspace;
  final WorkspaceRequests requests;
  final Studies studies;
  final Trainer trainer;
  late final Players directory;
  late final PlayerAnalysis analysis;
  late final PlayerHunt hunt;
  late final PlayerBook book;
  late final SavedGames saved;
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

  /// [player]'s prep study: the linked one when it is there, otherwise made
  /// under its usual name (or adopted when that file is already there) and
  /// linked. Null after saying why not.
  Future<ChapterRef?> _study(Player player) async {
    player =
        directory.players.where((p) => p.id == player.id).firstOrNull ?? player;
    final linked = player.text('prep_file');
    final usable = await _linked(linked, '${player.name}’s prep study');
    if (_disposed || usable == null) return null;
    if (usable) return ChapterRef.at(linked);
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
    // A file already under this name was made by an earlier click whose
    // link was not saved; it is adopted unless someone else links it.
    if (made is! Created && (made is! Collision || _linkedElsewhere(ref))) {
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
        directory.needsRetry
            ? 'The prep study is saved, but the link to ${player.name} was not. Retry the player save.'
            : 'The prep study is saved, but the link to ${player.name} was not. Open prep study again to link it.',
      );
      return null;
    }
    return ref;
  }

  /// Whether the study linked at [path] opens: false when there is no link
  /// or its file is gone, so a new one may be made; null after saying that
  /// the file is there but cannot be read, which is never replaced.
  Future<bool?> _linked(String path, String what) async {
    if (path.isEmpty) return false;
    switch (await env.store.open(ChapterRef.at(path))) {
      case Opened():
        return true;
      case Absent():
        return false;
      case Unreadable():
        if (!_disposed)
          requests.say(
            '$what ${p.basename(path)} could not be read. Unlink it to start a new one.',
          );
        return null;
    }
  }

  /// Whether a player or group already links [ref], so that a file found
  /// under a derived name is theirs and not one to adopt. Case is ignored:
  /// names differing only by case share one file on Windows and macOS.
  bool _linkedElsewhere(ChapterRef ref) {
    bool same(Object? path) =>
        path is String &&
        path.isNotEmpty &&
        p.equals(path.toLowerCase(), ref.path.toLowerCase());
    return directory.players.any((person) => same(person.text('prep_file'))) ||
        directory.groups.any((g) => same(g.fields['study']));
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
    final made = await _groupStudy(group);
    if (_disposed || made == null) return;
    await openLinkedStudy(made.ref.path, null);
    _sayLeftOut(made.leftOut);
  }

  /// The group study in Study’s Train pane, every chapter as a line
  /// trained from its own side, created first when the group has none.
  Future<void> trainGroupStudy(
    PlayerGroup group, {
    VoidCallback? onOpened,
  }) async {
    final made = await _groupStudy(group);
    if (_disposed || made == null) return;
    final opened = await requests.openStudy(made.ref);
    if (_disposed || opened is! RequestDone) return;
    trainer.setScope(TrainScope.chapter);
    onOpened?.call();
    _sayLeftOut(made.leftOut);
  }

  /// Said after the study opens, since opening clears the status bar.
  void _sayLeftOut(List<String> names) {
    if (names.isEmpty || _disposed) return;
    requests.say(
      'Left out ${names.join(', ')}: their prep study is missing or unreadable.',
    );
  }

  /// The group's study, created once from its members' non-empty prep
  /// chapters and linked from the group, with the members whose prep study
  /// could not be read and was left out; null after saying why not.
  Future<({ChapterRef ref, List<String> leftOut})?> _groupStudy(
    PlayerGroup group,
  ) async {
    final linked = group.fields['study'] as String? ?? '';
    final usable = await _linked(linked, 'The group study');
    if (_disposed || usable == null) return null;
    if (usable) return (ref: ChapterRef.at(linked), leftOut: const <String>[]);
    final name = 'Prep – ${group.name}';
    final chapters = <String>[];
    final skipped = <String>[];
    try {
      for (final person in directory.players.where(
        (p) => group.contains(p.id),
      )) {
        if (person.text('prep_file').isEmpty) continue;
        final read = await env.store.open(
          ChapterRef.at(person.text('prep_file')),
        );
        // A missing or unreadable member study is left out, not fatal.
        if (read is! Opened) {
          skipped.add(person.name);
          continue;
        }
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
      if (_disposed) return null;
      if (chapters.isEmpty)
        chapters.add(newStudyText(study: name, chapter: 'Preparation'));
      final ref = ChapterRef.at(
        p.join(
          env.folders.studies,
          '${safeFileName(name, fallback: 'Group-${group.id}')}.pgn',
        ),
      );
      final made = await env.store.create(ref, '${chapters.join('\n\n')}\n');
      // As for a player's study: one left by a link that was not saved.
      if (made is! Created && (made is! Collision || _linkedElsewhere(ref)))
        throw StateError(
          'A study with this name already exists. Rename the group or link its existing study.',
        );
      if (_disposed) return null;
      if (!await directory.saveGroup(
        group.edited({'study': ref.path}),
        expected: group,
      ))
        return null;
      await studies.refresh();
      // An adopted study was seeded earlier, not from what was read now.
      return (ref: ref, leftOut: made is Created ? skipped : const <String>[]);
    } on Object catch (e) {
      if (!_disposed) requests.say('$e');
      return null;
    }
  }

  /// Deletes [person]'s downloaded games and reports as [confirmed] said,
  /// then shows the rest of their games when they are the player being
  /// analysed. True when they were deleted.
  Future<bool> deleteGames(Player person, GamesSummary confirmed) async {
    final result = await saved.delete(person, confirmed: confirmed);
    if (_disposed) return result is GamesDiscarded;
    switch (result) {
      case GamesDiscarded():
        requests.say(
          '${person.name}’s downloaded games are in the recovery folder.',
          problem: false,
        );
        final current = directory.players
            .where((p) => p.id == person.id)
            .firstOrNull;
        if (current != null && analysis.player?.id == person.id) {
          hunt.stop();
          await analysis.select(current);
        }
      case GamesNotDiscarded(:final detail):
        requests.say('Could not delete ${person.name}’s games: $detail');
    }
    return result is GamesDiscarded;
  }

  Future<void> exportGroup(PlayerGroup group, {bool copy = false}) async {
    try {
      final text = await prepSheet(group, directory.players, env.store);
      if (_disposed) return;
      if (copy) {
        await Clipboard.setData(ClipboardData(text: text));
        if (!_disposed)
          requests.say(
            'Prep sheet copied, including saved lines.',
            problem: false,
          );
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
      if (!_disposed && path != null) {
        requests.say('Saved $path', problem: false);
      }
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
    // Taken now: the user may open another document while the study is made.
    final board = gameDraft(workspace.session);
    if (board == null) return;
    final ref = await _study(player);
    if (_disposed || ref == null) return;
    final added = await studies.addChapters(IntoStudy(ref), [
      board.named('${player.name} · As ${side.name}'),
    ]);
    if (_disposed) return;
    switch (added) {
      case StudyDone(:final chapter):
        await requests.openStudy(ref, chapter: chapter ?? 0);
      case StudyProblem(:final sentence):
        requests.say(sentence);
    }
  }

  void stop() {
    directory.stopLookup();
    analysis.cancel();
    hunt.stop();
  }

  void dispose() {
    _disposed = true;
    book.dispose();
    saved.dispose();
    hunt.dispose();
    analysis.dispose();
    directory.dispose();
  }
}
