import 'dart:math' as math;

import '../chess/pgn/game_text.dart';

/// What a save says it is about to change.
///
/// A chapter file holds many games and an edit is nearly always to one of
/// them. Nothing in the bytes says which one, so the caller says it here and
/// the store compares what it is about to write against the version on disk:
/// every game the scope does not name has to come through byte for byte, or
/// the save does not happen. A writer with a bug — one that drops a game, or
/// writes one game's moves into another — then cannot put that on disk.
sealed class EditScope {
  const EditScope();
}

/// The save replaces the whole file, which is what a restore, an import or a
/// paste does, and what a caller that cannot say says. There is nothing to
/// compare it against, so the store writes what it was given and says in the
/// log that it did.
final class WholeDocument extends EditScope {
  const WholeDocument();
}

/// The save writes the games named in [games] again and adds [appended] more
/// at the end. Every other game of the version on disk must come through
/// unchanged.
final class GamesEdited extends EditScope {
  const GamesEdited(this.games, {this.appended = 0});

  /// Indexes into the games of the version on disk, from 0, as the games of
  /// a chapter are numbered in code. A refusal numbers them from 1, the way
  /// the person reading it counts.
  final Set<int> games;

  /// How many games the save adds at the end of the file.
  ///
  /// Never negative: nothing in the app removes a game from a chapter, so a
  /// save that would leave fewer games than the file has is the mistake this
  /// check is here for, and it is refused rather than described.
  final int appended;
}

/// One scope covering both, for two edits whose saves collapsed into one.
///
/// The indexes still name games of the version on disk, because an edit adds
/// games at the end and never removes or reorders one: a game the earlier
/// edit added sits past the end of the version on disk, where the added
/// count covers it.
EditScope scopeOfBoth(EditScope first, EditScope second) =>
    switch ((first, second)) {
      (final GamesEdited a, final GamesEdited b) => GamesEdited({
        ...a.games,
        ...b.games,
      }, appended: a.appended + b.appended),
      (WholeDocument(), _) || (_, WholeDocument()) => const WholeDocument(),
    };

/// Why [next] may not replace [previous] under [scope], as a sentence, or
/// null when every game the scope does not name comes through byte for byte.
///
/// Games are compared by their own text and not by the blank lines between
/// them: appending a game gives the game before it a blank line, and a
/// separator is not where anybody's moves are.
String? changeOutsideScope({
  required String previous,
  required String next,
  required EditScope scope,
}) => switch (scope) {
  WholeDocument() => null,
  GamesEdited() => _changeOutside(previous, next, scope),
};

String? _changeOutside(String previous, String next, GamesEdited edit) {
  final before = _cut(previous);
  final after = _cut(next);
  if (!_headingKept(before, after)) {
    return 'the chapter heading would change but ${_declared(edit)}';
  }
  final shared = math.min(before.games.length, after.games.length);
  for (var index = 0; index < shared; index++) {
    if (edit.games.contains(index)) continue;
    if (!_same(before, before.games[index], after, after.games[index])) {
      return 'game ${index + 1} would change but ${_declared(edit)}';
    }
  }
  final expected = before.games.length + edit.appended;
  if (after.games.length != expected) {
    return 'the file holds ${_count(before.games.length)} and the save would '
        'leave ${_count(after.games.length)}, but ${_declared(edit)}';
  }
  return null;
}

/// Whether the `//` heading above the first game came through.
///
/// It has to come through byte for byte, with one exception: a chapter with
/// no games in it is all heading, and the first game appended to it must
/// start on a line of its own, so the heading may gain whitespace. Nothing
/// already in it is allowed to go either way.
bool _headingKept(_Cut before, _Cut after) {
  if (after.heading < before.heading) return false;
  if (after.heading > before.heading) {
    if (before.games.isNotEmpty) return false;
    if (!_blank(after.text, before.heading, after.heading)) return false;
  }
  return _same(before, (0, before.heading), after, (0, before.heading));
}

/// A version of a chapter as ranges into its own text rather than as copies
/// of it: comparing two five-megabyte versions must not make two more
/// megabytes of split-out games to do it.
typedef _Cut = ({String text, int heading, List<(int, int)> games});

/// Where each game of [text] is in it, using the same splitter the chapter
/// code uses, so the store and the reader agree on what a game is.
_Cut _cut(String text) {
  final document = splitChapterText(text);
  final games = <(int, int)>[];
  // The preamble and the games, each with the whitespace after it, are the
  // whole text in order, so one running offset places them all.
  var at = document.preamble.length;
  for (final game in document.games) {
    games.add((at, at + game.text.length));
    at += game.text.length + game.trailer.length;
  }
  return (text: text, heading: document.preamble.length, games: games);
}

bool _same(_Cut a, (int, int) inA, _Cut b, (int, int) inB) {
  final length = inA.$2 - inA.$1;
  if (inB.$2 - inB.$1 != length) return false;
  for (var i = 0; i < length; i++) {
    if (a.text.codeUnitAt(inA.$1 + i) != b.text.codeUnitAt(inB.$1 + i)) {
      return false;
    }
  }
  return true;
}

bool _blank(String text, int from, int to) {
  for (var i = from; i < to; i++) {
    if (text[i].trim().isNotEmpty) return false;
  }
  return true;
}

/// What the save said it was doing, for the sentence that refuses it.
String _declared(GamesEdited edit) {
  final named = (edit.games.toList()..sort())
      .map((index) => '${index + 1}')
      .join(', ');
  return switch ((edit.games.isEmpty, edit.appended)) {
    (true, 0) => 'the edit changed no game',
    (true, final added) => 'the edit only added ${_count(added)} at the end',
    (false, 0) => 'the edit was to game $named',
    (false, final added) =>
      'the edit was to game $named and added ${_count(added)} at the end',
  };
}

String _count(int games) => games == 1 ? '1 game' : '$games games';
