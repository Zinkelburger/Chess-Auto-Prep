/// Editing a repertoire chapter file on disk, game by game.
///
/// A chapter file is a `//` preamble followed by games. Every edit here
/// reads the file once, cuts it into those games exactly as
/// [pgn.splitPgnIntoGames] indexes them, changes the smallest span of text
/// that has to change (see `repertoire_pgn_text.dart`) and writes the whole
/// document back atomically, guarded against the file having changed
/// underneath. Games are addressed by position ([RepertoireLine.gameIndex])
/// or by line id, resolved with the same rule the trainer assigns ids by.
library;

import '../features/training/repositories/training_review_repository.dart';

import 'dart:io' as io;
import '../chess_core/pgn/repertoire_document_mutation.dart';

import 'package:path/path.dart' as p;

import '../models/repertoire_line.dart';
import '../models/repertoire_review_entry.dart' show RepertoireReviewEntry;
import '../utils/atomic_file.dart';
import '../utils/file_text_reader.dart';
import '../chess_core/pgn/pgn_text.dart' as pgn;
import '../chess_core/pgn/repertoire_pgn_text.dart';

/// A chapter file cut into its `//` preamble and its games as raw text,
/// indexed the way [RepertoireLine.gameIndex] is, with the content it was
/// read from (for the write-back guard).
typedef RepertoirePgnDocument = ({
  String preamble,
  List<String> games,
  String originalContent,
});

/// The ids of one file's games, valid while the file's stat is unchanged.
class _CachedLineIds {
  const _CachedLineIds({
    required this.size,
    required this.modified,
    required this.gameCount,
    required this.ids,
  });

  final int size;
  final DateTime modified;
  final int gameCount;
  final List<String?> ids;
}

/// Reads and rewrites the games of repertoire chapter files. Stateless
/// apart from the process-wide line-id memo; construct freely.
class RepertoireFileEditor implements TrainingHeaderRepository {
  const RepertoireFileEditor();

  /// One entry per edited file; bounded by the handful of chapters a
  /// session touches, and never larger than the on-disk repertoire.
  static final Map<String, _CachedLineIds> _lineIdCache = {};

  /// [lineIdsForGames] for the document at [filePath], memoised on the
  /// file's size and mtime.  An edit session issues a burst of lookups
  /// against a file that only changes when this editor writes it, so a
  /// hit is the common case and a miss costs one lexing pass.
  List<String?> _lineIdsForFile(
    String filePath,
    io.FileStat stat,
    List<String> games,
  ) {
    final cached = _lineIdCache[filePath];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified &&
        cached.gameCount == games.length) {
      return cached.ids;
    }
    final ids = lineIdsForGames(games);
    _lineIdCache[filePath] = _CachedLineIds(
      size: stat.size,
      modified: stat.modified,
      gameCount: games.length,
      ids: ids,
    );
    return ids;
  }

  // ── Whole documents ─────────────────────────────────────────────────────

  /// The whole document at [filePath]: its `//` preamble and every game as
  /// raw text, indexed the way [RepertoireLine.gameIndex] is. Null when the
  /// file does not exist.
  ///
  /// Exists so a caller that needs *every* game (splitting a chapter, say)
  /// reads and cuts the file once instead of once per game.
  Future<RepertoirePgnDocument?> readPgnDocument(String filePath) async {
    final file = io.File(filePath);
    if (!await file.exists()) return null;
    final content = await readTextFile(file);
    final document = splitRepertoireDocument(content);
    return (
      preamble: document.preamble,
      games: document.games,
      originalContent: content,
    );
  }

  /// Writes [games] under [preamble] as a complete PGN document, replacing
  /// whatever is at [filePath]. Same layout as every other write here, so a
  /// file this produces is indistinguishable from one the editors touched.
  Future<void> writePgnDocument(
    String filePath, {
    required String preamble,
    required List<String> games,
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await writeTextFileAtomically(
      io.File(filePath),
      reassemblePgnDocument(preamble.trimRight(), games),
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }

  /// Reads [filePath] (an absent file reads as empty), lets [mutate] edit
  /// its game list, and writes the result back. Creates the file when it
  /// did not exist.
  Future<void> _rewriteGames(
    String filePath,
    void Function(List<String> games) mutate,
  ) async {
    final file = io.File(filePath);
    final existed = await file.exists();
    final content = existed ? await readTextFile(file) : '';
    final document = splitRepertoireDocument(content);
    final games = List<String>.from(document.games);
    mutate(games);
    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      createOnly: !existed,
      expectedContent: existed ? content : null,
    );
  }

  // ── Edits by line id ────────────────────────────────────────────────────

  /// Loads the PGN document at [filePath], locates the game for [lineId],
  /// lets [mutate] modify the mutable games list (given the match index),
  /// then writes the result back atomically. Returns false if the file or
  /// line is missing.
  ///
  /// [gameIndex] is the caller's [RepertoireLine.gameIndex] when it has one:
  /// the game there is used directly when it still resolves to [lineId],
  /// which it does unless the file changed under us.  Ids are otherwise
  /// looked up through the per-file cache ([_lineIdsForFile]), so neither
  /// path parses a move tree.
  Future<bool> _editLineInFile(
    String filePath,
    String lineId,
    void Function(List<String> games, int matchIndex) mutate, {
    int? gameIndex,
  }) async {
    final file = io.File(filePath);
    if (!await file.exists()) return false;

    final stat = await file.stat();
    final content = await readTextFile(file);
    final document = splitRepertoireDocument(content);
    final games = List<String>.from(document.games);

    final ids = _lineIdsForFile(filePath, stat, games);
    final matchIndex =
        gameIndex != null &&
            gameIndex >= 0 &&
            gameIndex < ids.length &&
            ids[gameIndex] == lineId
        ? gameIndex
        : ids.indexOf(lineId);
    if (matchIndex < 0) return false;

    mutate(games, matchIndex);

    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      expectedContent: content,
    );
    return true;
  }

  Future<bool> updateLineTitle(
    String filePath,
    String lineId,
    String newTitle, {
    int? gameIndex,
  }) => _editLineInFile(filePath, lineId, gameIndex: gameIndex, (
    games,
    matchIndex,
  ) {
    games[matchIndex] = withEventTitle(games[matchIndex], newTitle);
  });

  /// Replaces the full PGN content of an existing line identified by [lineId].
  ///
  /// This is the in-place edit counterpart of [updateLineTitle].  The caller
  /// provides the complete new PGN text (headers + move text) which replaces
  /// the old game entry on disk.
  Future<bool> updateLineContent(
    String filePath,
    String lineId,
    String newGamePgn, {
    int? gameIndex,
  }) => _editLineInFile(filePath, lineId, gameIndex: gameIndex, (
    games,
    matchIndex,
  ) {
    games[matchIndex] = mergeMissingHeaders(
      games[matchIndex],
      newGamePgn.trimRight(),
    );
  });

  /// Removes a game identified by [lineId] from the PGN file on disk.
  Future<bool> deleteLine(String filePath, String lineId, {int? gameIndex}) =>
      _editLineInFile(filePath, lineId, gameIndex: gameIndex, (
        games,
        matchIndex,
      ) {
        games.removeAt(matchIndex);
      });

  /// Writes spaced-repetition metadata into PGN headers for a specific line.
  /// Headers used: [LastReview], [Difficulty], [Interval], [DueDate],
  /// [PassCount], [FailCount]. Unknown headers are ignored by standard PGN
  /// parsers, making this forward/backward compatible.
  Future<bool> updateLineReviewHeaders(
    String filePath,
    String lineId, {
    required DateTime? lastReview,
    required double difficulty,
    required double intervalDays,
    required DateTime? dueDate,
    required int passCount,
    required int failCount,
  }) => _editLineInFile(filePath, lineId, (games, matchIndex) {
    games[matchIndex] = gameWithReviewHeaders(
      games[matchIndex],
      lastReview: lastReview,
      difficulty: difficulty,
      intervalDays: intervalDays,
      dueDate: dueDate,
      passCount: passCount,
      failCount: failCount,
    );
  });

  /// Bulk counterpart of [updateLineReviewHeaders]: rewrites the review
  /// headers of every line in [entriesByLineId] with a single read and one
  /// atomic write. A per-line loop over [updateLineReviewHeaders] would
  /// reread and rewrite the whole file once per line.
  @override
  Future<bool> updateManyLineReviewHeaders(
    String filePath,
    Map<String, RepertoireReviewEntry> entriesByLineId,
  ) async {
    if (entriesByLineId.isEmpty) return true;
    final file = io.File(filePath);
    if (!await file.exists()) return false;

    final stat = await file.stat();
    final content = await readTextFile(file);
    final document = splitRepertoireDocument(content);
    final games = List<String>.from(document.games);

    // Resolve every id in one pass; looking each entry up separately would
    // make the bulk write quadratic in exactly the case it exists to make
    // cheap.
    final idsByIndex = _lineIdsForFile(filePath, stat, games);
    final indexById = <String, int>{};
    for (var i = 0; i < idsByIndex.length; i++) {
      final id = idsByIndex[i];
      if (id != null) indexById.putIfAbsent(id, () => i);
    }

    var anyMatched = false;
    for (final entry in entriesByLineId.entries) {
      final matchIndex = indexById[entry.key];
      if (matchIndex == null) continue;
      final e = entry.value;
      games[matchIndex] = gameWithReviewHeaders(
        games[matchIndex],
        lastReview: e.lastReviewedUtc,
        difficulty: e.difficulty,
        intervalDays: e.intervalDays,
        dueDate: e.dueDateUtc,
        passCount: e.passCount,
        failCount: e.failCount,
      );
      anyMatched = true;
    }
    if (!anyMatched) return false;

    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      expectedContent: content,
    );
    return true;
  }

  // ── Edits by game index ─────────────────────────────────────────────────

  /// The full PGN text of the [gameIndex]-th game in the file, or null when
  /// the file or the game is missing.
  ///
  /// Index-addressed rather than id-addressed on purpose: the move-based line
  /// id truncates and collides for lines sharing a long prefix, so an id
  /// lookup can return the wrong game. [RepertoireLine.gameIndex] is exact.
  Future<String?> readGameTextAt(String filePath, int gameIndex) async {
    final document = await readPgnDocument(filePath);
    if (document == null) return null;
    if (gameIndex < 0 || gameIndex >= document.games.length) return null;
    return document.games[gameIndex];
  }

  /// The games at [gameIndexes] of [filePath] as `(index, text)`, in file
  /// order, skipping indexes the file does not have. Null when the file is
  /// missing.
  Future<List<({int index, String text})>?> readGameTextsAt(
    String filePath,
    Set<int> gameIndexes,
  ) async {
    final document = await readPgnDocument(filePath);
    if (document == null) return null;
    return [
      for (var i = 0; i < document.games.length; i++)
        if (gameIndexes.contains(i)) (index: i, text: document.games[i]),
    ];
  }

  /// Edits the [gameIndex]-th game in place. Returns false when out of range.
  Future<bool> _editGameAt(
    String filePath,
    int gameIndex,
    void Function(List<String> games) mutate,
  ) async {
    final file = io.File(filePath);
    if (!await file.exists()) return false;
    final content = await readTextFile(file);
    final document = splitRepertoireDocument(content);
    if (gameIndex < 0 || gameIndex >= document.games.length) return false;
    final games = List<String>.from(document.games);
    mutate(games);
    await writeTextFileAtomically(
      file,
      reassemblePgnDocument(document.preamble, games),
      expectedContent: content,
    );
    return true;
  }

  Future<bool> deleteGameAt(String filePath, int gameIndex) =>
      _editGameAt(filePath, gameIndex, (games) => games.removeAt(gameIndex));

  Future<bool> updateGameTitleAt(
    String filePath,
    int gameIndex,
    String newTitle,
  ) => _editGameAt(filePath, gameIndex, (games) {
    games[gameIndex] = withEventTitle(games[gameIndex], newTitle);
  });

  /// Removes every game whose position in the file is in [gameIndexes], in
  /// one read and one write. Returns how many games went.
  ///
  /// Index-addressed for the reason [readGameTextAt] gives: the move-based
  /// line id truncates and collides for lines sharing a long prefix, so
  /// deleting several by id can take out the wrong games. It also matters
  /// that this is one write — trimming a generated course drops hundreds of
  /// lines at once, and doing that a game at a time rewrites (and reloads)
  /// the file hundreds of times.
  Future<int> deleteLinesAt(String filePath, Set<int> gameIndexes) async {
    if (gameIndexes.isEmpty) return 0;
    final document = await readPgnDocument(filePath);
    if (document == null) return 0;
    final kept = <String>[];
    for (var i = 0; i < document.games.length; i++) {
      if (!gameIndexes.contains(i)) kept.add(document.games[i]);
    }
    final removed = document.games.length - kept.length;
    if (removed == 0) return 0;
    await writePgnDocument(
      filePath,
      preamble: document.preamble,
      games: kept,
      expectedContent: document.originalContent,
    );
    return removed;
  }

  /// Appends [gameTexts] to the chapter at [filePath], creating the file when
  /// it does not exist. Each text is one complete PGN game.
  Future<void> appendGameTexts(String filePath, List<String> gameTexts) async {
    if (gameTexts.isEmpty) return;
    await _rewriteGames(filePath, (games) {
      games.addAll([
        for (final t in gameTexts)
          if (t.trim().isNotEmpty) t.trim(),
      ]);
    });
  }

  /// Inserts each of [games] so that it ends up at its `index` — the indexes
  /// are the *final* positions, applied in ascending order, and clamped to the
  /// end of the file. Inserting `(2, a), (5, b)` into a six-game file puts
  /// `a` third and `b` sixth.
  ///
  /// That contract is what makes a deletion undoable exactly: removing the
  /// games at a set of indexes and inserting them back at the same indexes
  /// restores the file, however scattered the set was. Creates the file when
  /// it does not exist.
  Future<void> insertGameTextsAt(
    String filePath,
    List<({int index, String text})> games,
  ) async {
    if (games.isEmpty) return;
    final sorted = [...games]..sort((a, b) => a.index.compareTo(b.index));
    await _rewriteGames(filePath, (result) {
      for (final g in sorted) {
        result.insert(g.index.clamp(0, result.length), g.text.trim());
      }
    });
  }

  /// Moves the [gameIndex]-th game of [fromPath] to the end of [toPath]:
  /// appended to the destination first, then removed from the source, so a
  /// failure between the two can leave a duplicate but never a lost line.
  /// Returns false when the game was not found.
  Future<bool> moveGame({
    required String fromPath,
    required int gameIndex,
    required String toPath,
  }) async {
    if (p.equals(fromPath, toPath)) return true;
    final text = await readGameTextAt(fromPath, gameIndex);
    if (text == null) return false;
    await appendGameTexts(toPath, [text]);
    return deleteGameAt(fromPath, gameIndex);
  }

  /// Moves the games at [gameIndexes] of [fromPath] into [toPath], keeping
  /// their relative order, and returns the indexes they now occupy there
  /// (ascending; empty when none of them existed).
  ///
  /// Where they land: as one block starting at [toIndex] — "before the game
  /// that is at [toIndex] now" — or at the end when it is null; or, with
  /// [toIndexes], at exactly those final positions (see [insertGameTextsAt]),
  /// which is how a move is undone.
  ///
  /// Within one file this is a reorder and a single write. Across files the
  /// destination is written before the source, so a failure between the two
  /// can leave a duplicate but never a lost line. [transform] rewrites each
  /// moved game's text on the way (the caller pins the line id with it).
  Future<List<int>> moveGamesTo({
    required String fromPath,
    required Set<int> gameIndexes,
    required String toPath,
    int? toIndex,
    List<int>? toIndexes,
    String Function(int index, String text)? transform,
  }) async {
    assert(toIndex == null || toIndexes == null);
    final source = await readPgnDocument(fromPath);
    if (source == null) return const [];
    final moving = <int>[];
    final texts = <String>[];
    final remaining = <String>[];
    for (var i = 0; i < source.games.length; i++) {
      if (gameIndexes.contains(i)) {
        moving.add(i);
        texts.add(transform?.call(i, source.games[i]) ?? source.games[i]);
      } else {
        remaining.add(source.games[i]);
      }
    }
    if (moving.isEmpty) return const [];
    assert(toIndexes == null || toIndexes.length == moving.length);

    if (p.equals(fromPath, toPath)) {
      // "Before the game at toIndex" is measured in the old numbering; the
      // games taken out above it shift the slot down.
      final finals = toIndexes != null
          ? ([...toIndexes]..sort())
          : _block(
              toIndex == null
                  ? remaining.length
                  : toIndex - moving.where((i) => i < toIndex).length,
              moving.length,
              remaining.length,
            );
      for (var k = 0; k < finals.length; k++) {
        remaining.insert(finals[k].clamp(0, remaining.length), texts[k]);
      }
      await writePgnDocument(
        fromPath,
        preamble: source.preamble,
        games: remaining,
        expectedContent: source.originalContent,
      );
      return finals;
    }

    final destination = await readPgnDocument(toPath);
    final destinationLength = destination?.games.length ?? 0;
    final finals = toIndexes != null
        ? ([...toIndexes]..sort())
        : _block(
            toIndex ?? destinationLength,
            moving.length,
            destinationLength,
          );
    await insertGameTextsAt(toPath, [
      for (var k = 0; k < finals.length; k++)
        (index: finals[k], text: texts[k]),
    ]);
    await writePgnDocument(
      fromPath,
      preamble: source.preamble,
      games: remaining,
      expectedContent: source.originalContent,
    );
    return finals;
  }

  /// [count] consecutive indexes from [start], clamped so the block fits
  /// after [length] existing games.
  static List<int> _block(int start, int count, int length) {
    final from = start.clamp(0, length);
    return [for (var k = 0; k < count; k++) from + k];
  }
}
