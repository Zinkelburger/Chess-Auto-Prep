import 'dart:convert';
import 'dart:math' as math;

import '../chess/pgn/games_written.dart';
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

/// The save writes the games [written] says the edit wrote and adds the ones
/// it counted. Every other game of the version on disk must come through
/// unchanged.
///
/// The value comes from the edit itself ([GamesWritten]) rather than from
/// reading the new text: a scope worked out from the text would agree with
/// whatever the text says, including with a game it should never have
/// touched.
final class GamesEdited extends EditScope {
  const GamesEdited(this.written);

  final GamesWritten written;
}

/// The save keeps the games of the version on disk and only changes which
/// order they are in: the file will hold the games at [from], in that order,
/// each byte for byte as it is now.
///
/// This is what moving a study's chapters up and down is, and what deleting
/// one is — a delete leaves its index out. Nothing else in a save may take a
/// game out or move one, which is why [GamesEdited] cannot say it and why
/// this says nothing about content: a save that also changed a game's moves
/// is refused here.
final class GamesReordered extends EditScope {
  const GamesReordered(this.from);

  /// For each game the save will write, where it is in the version on disk,
  /// counting from zero.
  final List<int> from;
}

/// The save replaces the whole file, which is what an import or a paste
/// does, and what a caller that cannot say says. There is nothing to compare
/// it against, so the store writes what it was given and says in the log
/// that it did.
final class WholeDocument extends EditScope {
  const WholeDocument();
}

/// The save puts back a version this store recorded, which is what an undo
/// is. There is no earlier version to compare it against — it *is* an
/// earlier version — so the store compares it against the archive instead:
/// bytes that hash to no version kept for the document are refused, and the
/// one that is put back is named in the log.
final class RestoredVersion extends EditScope {
  const RestoredVersion();
}

/// One scope covering both, for two edits whose saves collapsed into one.
///
/// The indexes still name games of the version on disk, **because an edit
/// adds games at the end and never removes or reorders one**: a game the
/// earlier edit added sits past the end of the version on disk, where the
/// added count covers it. An edit that inserts a game in the middle, or
/// removes one, would shift the later indexes and has to revisit this.
///
/// Anything else — a whole document, a restored version — covers everything
/// the other could have named, so the pair is a whole document, which the
/// store logs.
EditScope scopeOfBoth(EditScope first, EditScope second) {
  if (first is! GamesEdited || second is! GamesEdited) {
    return const WholeDocument();
  }
  return GamesEdited(
    GamesWritten(
      rewritten: {...first.written.rewritten, ...second.written.rewritten},
      appended: first.written.appended + second.written.appended,
    ),
  );
}

/// Why [next] may not replace [previous] under [scope], as a sentence, or
/// null when every game the scope does not name comes through byte for byte.
///
/// Bytes, not text: a file this app reads with a stray byte in it decodes
/// with that byte as U+FFFD, and comparing the decodings would let the save
/// write the replacement character over it. Both sides here are what is and
/// what would be on the disk.
///
/// Games are compared by their own bytes and not by the blank lines between
/// them: appending a game gives the game before it a blank line, and a
/// separator is not where anybody's moves are.
/// A restored version is not checked here: the store looks it up in the
/// archive, which is the only thing that can say whether those bytes were
/// ever this document.
String? changeOutsideScope({
  required List<int> previous,
  required List<int> next,
  required EditScope scope,
}) => switch (scope) {
  WholeDocument() || RestoredVersion() => null,
  GamesEdited() => _changeOutside(previous, next, scope.written),
  GamesReordered() => _notTheSameGames(previous, next, scope.from),
};

/// Why [next] is not [previous]'s games in the order [from] asks for, or
/// null when it is exactly that.
///
/// Every game has to arrive byte for byte from the place the order names, so
/// a reorder that also rewrote a game — or invented one, or kept one twice —
/// is refused before anything is written.
String? _notTheSameGames(List<int> previous, List<int> next, List<int> from) {
  final before = _cut(previous);
  final after = _cut(next);
  if (!_same(previous, (0, before.heading), next, (0, after.heading))) {
    return 'the chapter heading would change, but the save only reordered '
        'the games';
  }
  if (after.games.length != from.length) {
    return 'the save would leave ${_count(after.games.length)} but said it '
        'was leaving ${_count(from.length)}';
  }
  final taken = <int>{};
  for (var index = 0; index < from.length; index++) {
    final source = from[index];
    if (source < 0 || source >= before.games.length || !taken.add(source)) {
      return 'the save asked for game ${source + 1} of '
          '${_count(before.games.length)}, which it cannot take';
    }
    if (!_same(previous, before.games[source], next, after.games[index])) {
      return 'game ${source + 1} would change, but the save only reordered '
          'the games';
    }
  }
  return null;
}

String? _changeOutside(List<int> previous, List<int> next, GamesWritten edit) {
  // An edit that added a negative number of games is an edit that removed
  // some, which nothing in the app does and no save may claim.
  if (edit.appended < 0) {
    return 'the save said it was taking ${_count(-edit.appended)} out, which '
        'no edit does';
  }
  final before = _cut(previous);
  final after = _cut(next);
  if (!_headingKept(before, after, previous, next)) {
    return 'the chapter heading would change but ${_declared(edit)}';
  }
  final shared = math.min(before.games.length, after.games.length);
  for (var index = 0; index < shared; index++) {
    if (edit.rewritten.contains(index)) continue;
    if (!_same(previous, before.games[index], next, after.games[index])) {
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
bool _headingKept(_Cut before, _Cut after, List<int> previous, List<int> next) {
  if (after.heading < before.heading) return false;
  if (after.heading > before.heading) {
    if (before.games.isNotEmpty) return false;
    if (!_blank(next, before.heading, after.heading)) return false;
  }
  return _same(previous, (0, before.heading), next, (0, before.heading));
}

/// Where the games of one version are, as ranges into its bytes.
///
/// The splitter takes a string and gives back the games as substrings, so
/// one version at a time is split; its pieces are reduced to offsets here
/// and are collectable before the other version is split. Two five-megabyte
/// versions are therefore never both split at once, and the comparison
/// itself reads the byte lists and copies nothing.
typedef _Cut = ({int heading, List<(int, int)> games});

/// Where each game of [bytes] is in it, cut by the same splitter the chapter
/// reader uses, so the store and the reader agree on what a game is.
///
/// Latin-1 gives each byte one code unit, so an offset in the decoded string
/// is the same offset in the bytes. The splitter only ever looks for ASCII —
/// `[Event`, braces, line ends — and no byte of a UTF-8 sequence is ASCII,
/// so it finds the same games whichever way the bytes were meant to be read.
_Cut _cut(List<int> bytes) {
  final document = splitChapterText(latin1.decode(bytes));
  final games = <(int, int)>[];
  // The preamble and the games, each with the whitespace after it, are the
  // whole text in order, so one running offset places them all.
  var at = document.preamble.length;
  for (final game in document.games) {
    games.add((at, at + game.text.length));
    at += game.text.length + game.trailer.length;
  }
  return (heading: document.preamble.length, games: games);
}

bool _same(List<int> a, (int, int) inA, List<int> b, (int, int) inB) {
  final length = inA.$2 - inA.$1;
  if (inB.$2 - inB.$1 != length) return false;
  for (var i = 0; i < length; i++) {
    if (a[inA.$1 + i] != b[inB.$1 + i]) return false;
  }
  return true;
}

bool _blank(List<int> bytes, int from, int to) {
  for (var i = from; i < to; i++) {
    final byte = bytes[i];
    if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
      return false;
    }
  }
  return true;
}

/// What the save said it was doing, for the sentence that refuses it.
String _declared(GamesWritten edit) {
  final named = (edit.rewritten.toList()..sort())
      .map((index) => '${index + 1}')
      .join(', ');
  return switch ((edit.rewritten.isEmpty, edit.appended)) {
    (true, 0) => 'the edit changed no game',
    (true, final added) => 'the edit only added ${_count(added)} at the end',
    (false, 0) => 'the edit was to game $named',
    (false, final added) =>
      'the edit was to game $named and added ${_count(added)} at the end',
  };
}

String _count(int games) => games == 1 ? '1 game' : '$games games';
