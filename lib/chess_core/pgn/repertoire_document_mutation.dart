import 'repertoire_line_ids.dart';
import 'package:collection/collection.dart';
import 'pgn_text.dart' as pgn;
import 'mainline_lexer.dart' as pgn;
import 'repertoire_pgn_text.dart';

/// Storage-derived logical step. Intermediate steps are not disk commits.
class AppendMoveStep {
  AppendMoveStep({
    required List<String> pathBefore,
    required this.san,
    required this.content,
  }) : pathBefore = List.unmodifiable(pathBefore);

  final List<String> pathBefore;
  final String san;
  final String content;
}

/// Pure logical preparation, not evidence that any file was committed.
/// An empty step list is a no-op. Native receipts bind this plan to storage.
class RepertoireAppendPlan {
  RepertoireAppendPlan({
    required this.previousContent,
    required this.updatedContent,
    required List<AppendMoveStep> steps,
  }) : steps = List.unmodifiable(steps);

  final String previousContent;
  final String updatedContent;
  final List<AppendMoveStep> steps;

  /// Validate before writing and again at the session boundary. A broken
  /// adapter must not install partial history or invent memory-based receipts.
  void validate({required List<String> requestedPath}) {
    var previous = previousContent;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (!const ListEquality<String>().equals([
            ...step.pathBefore,
            step.san,
          ], requestedPath.take(step.pathBefore.length + 1).toList()) ||
          step.content == previous ||
          step.san.isEmpty ||
          (i > 0 &&
              !const ListEquality<String>().equals(step.pathBefore, [
                ...steps[i - 1].pathBefore,
                steps[i - 1].san,
              ]))) {
        throw StateError('Invalid ordered PGN mutation receipt');
      }
      previous = step.content;
    }
    if (previous != updatedContent ||
        (steps.isNotEmpty &&
            !const ListEquality<String>().equals([
              ...steps.last.pathBefore,
              steps.last.san,
            ], requestedPath))) {
      throw StateError(
        'Incomplete PGN mutation receipt; keep the saved document for recovery',
      );
    }
  }
}

/// Splits a PGN document into its `//` preamble and its games, exactly as
/// [pgn.splitPgnIntoGames] indexes them.
///
/// The trailing space in `'[Event '` is load-bearing and the reason this
/// agrees with the parser at all: a bare `[Event` prefix also matches
/// `[EventDate "…"]`, which every Chessable export carries, and cutting
/// there split each game in two. Every index-addressed edit then landed on
/// the wrong half of the wrong game.
({String preamble, List<String> games}) splitRepertoireDocument(
  String content,
) {
  content = pgn.stripBom(content);
  final preambleLines = <String>[];
  final games = <String>[];
  var gameStart = -1;

  // One pass over line starts; a game is a substring between two `[Event `
  // lines, right-trimmed as the line-joining version produced it.
  var lineStart = 0;
  while (lineStart <= content.length) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = content.length;

    if (_startsWithEventTag(content, lineStart, lineEnd)) {
      if (gameStart >= 0) {
        final text = content.substring(gameStart, lineStart).trimRight();
        if (text.isNotEmpty) games.add(text);
      }
      gameStart = lineStart;
    } else if (gameStart < 0) {
      final line = content.substring(lineStart, lineEnd);
      if (line.trim().isNotEmpty) preambleLines.add(line);
    }
    lineStart = lineEnd + 1;
  }
  if (gameStart >= 0) {
    final text = content.substring(gameStart).trimRight();
    if (text.isNotEmpty) games.add(text);
  }

  return (preamble: preambleLines.join('\n').trimRight(), games: games);
}

/// Whether the line `[start, end)` is `[Event ` after optional blanks.
bool _startsWithEventTag(String content, int start, int end) {
  var i = start;
  while (i < end) {
    final c = content.codeUnitAt(i);
    if (c != 0x20 && c != 0x09 && c != 0x0D) break;
    i++;
  }
  return content.startsWith('[Event ', i);
}

/// Pure preparation shared with sessions which have no backing file. Disk
/// callers must validate [RepertoireAppendPlan.previousContent] at commit.
RepertoireAppendPlan prepareAppendMoves(
  String content,
  List<String> pathFromRoot,
  List<String> newSans, {
  String? startingFen,
  bool isWhiteRepertoire = true,
}) {
  final document = splitRepertoireDocument(content);
  final games = List<String>.from(document.games);
  final mainlines = games.map(pgn.mainlineSansOf).toList();
  final steps = <AppendMoveStep>[];
  var prefix = List<String>.of(pathFromRoot);
  for (final san in newSans) {
    final next = [...prefix, san];
    // The disk baseline may already include a move absent from controller
    // memory. Do not create a duplicate game or phantom undo in that case.
    if (mainlines.any(
      (line) =>
          line.length >= next.length &&
          const ListEquality<String>().equals(
            line.take(next.length).toList(),
            next,
          ),
    )) {
      prefix = next;
      continue;
    }
    final match = mainlines.indexWhere(
      (line) => const ListEquality<String>().equals(line, prefix),
    );
    if (match >= 0) {
      games[match] = appendSanToGamePgn(games[match], prefix, san);
      mainlines[match] = next;
    } else {
      games.add(
        buildMinimalGamePgn(
          next,
          startingFen: startingFen,
          isWhiteRepertoire: isWhiteRepertoire,
        ),
      );
      mainlines.add(next);
    }
    steps.add(
      AppendMoveStep(
        pathBefore: prefix,
        san: san,
        content: reassemblePgnDocument(document.preamble, games),
      ),
    );
    prefix = next;
  }
  return RepertoireAppendPlan(
    previousContent: content,
    updatedContent: steps.isEmpty ? content : steps.last.content,
    steps: steps,
  );
}

/// The id each game in [games] resolves to — null for games that do not
/// parse or have no moves — using exactly the rule of
/// `RepertoireService.parseRepertoirePgn`, including collision resolution.
/// This is what file edits must use to find a line by id.
///
/// Reads the header block and lexes the mainline ([pgn.mainlineSansOf])
/// instead of building each game's move tree with dartchess: an id needs
/// the header id or the mainline SAN list, nothing more, and this runs over
/// every game in the file on every rename, autosave and review rating.
List<String?> lineIdsForGames(List<String> games) {
  final ids = List<String?>.filled(games.length, null);
  final seen = <String>{};
  for (var i = 0; i < games.length; i++) {
    final moves = pgn.mainlineSansOf(games[i]);
    if (moves.isEmpty) continue;
    final id = repertoireLineIds.fromHeaders(
      pgn.extractHeaderBlock(games[i]),
      moves,
      i,
    );
    ids[i] = seen.add(id)
        ? id
        : repertoireLineIds.resolveCollision(moves, i, seen);
  }
  return ids;
}
