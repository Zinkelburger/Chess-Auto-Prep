/// What an edit did to a chapter's games, for whoever writes the file.
library;

/// Which games an edit wrote again, and how many it added at the end.
///
/// An edit knows this; the text it produced does not say it. A caller that
/// worked it out by comparing the chapter before with the chapter after
/// would agree with whatever the edit did, including with a game it should
/// never have touched, so the edit says it here and whoever writes the file
/// carries it through to the store.
final class GamesWritten {
  GamesWritten({Set<int> rewritten = const {}, this.appended = 0})
    : rewritten = Set.unmodifiable(rewritten),
      assert(appended >= 0, 'no edit takes a game out of a chapter');

  /// An edit that changed nothing of the file.
  static final nothing = GamesWritten();

  /// Indexes into the chapter's games as they were before the edit, from 0.
  /// Its own copy, so what an edit declared cannot change afterwards.
  final Set<int> rewritten;

  /// How many games the edit added at the end of the chapter. Never
  /// negative: nothing here takes a game out.
  final int appended;
}

/// Where each game of the edited chapter came from, for an edit that removed
/// or reordered games — which [GamesWritten] cannot say, because it assumes
/// every game stayed where it was.
///
/// `order[i]` is the game of the chapter before the edit that is now game
/// `i`, or null for a game the edit made. A game of the old chapter that no
/// position names has been taken out. [rewritten] names games of the old
/// chapter whose text the edit wrote again; every other game has to come
/// through byte for byte, wherever it now sits. [heading] says the `//` block
/// above the first game was written again, which only the playing-side line
/// does.
final class GamesArranged {
  GamesArranged({
    required List<int?> order,
    Set<int> rewritten = const {},
    required this.before,
    this.heading = false,
  }) : order = List.unmodifiable(order),
       rewritten = Set.unmodifiable(rewritten);

  /// The arrangement of an edit that left every game where it was: what
  /// [GamesWritten] says, spelled out. [before] is how many games the chapter
  /// held before the edit.
  factory GamesArranged.of(GamesWritten written, {required int before}) =>
      GamesArranged(
        order: [
          for (var index = 0; index < before; index++) index,
          ...List<int?>.filled(written.appended, null),
        ],
        rewritten: written.rewritten,
        before: before,
      );

  final List<int?> order;
  final Set<int> rewritten;

  /// How many games the chapter held before the edit.
  final int before;

  final bool heading;
}

/// One arrangement covering two edits, the second of them worked out on the
/// chapter the first produced, or null when [second] names a game [first]
/// never produced and the pair therefore says nothing trustworthy.
///
/// `second.order` names places in the first edit's output, and `first.order`
/// says which game of the file each of those places holds, so following one
/// through the other gives the file again. A place the first edit created
/// belongs to no game on disk, and a game of it the second edit wrote is
/// therefore not a game on disk either.
GamesArranged? composedArrangement(GamesArranged first, GamesArranged second) {
  final places = first.order.length;
  final order = <int?>[];
  for (final place in second.order) {
    if (place == null) {
      order.add(null);
      continue;
    }
    if (place < 0 || place >= places) return null;
    order.add(first.order[place]);
  }
  final rewritten = {...first.rewritten};
  for (final place in second.rewritten) {
    if (place < 0 || place >= places) return null;
    final game = first.order[place];
    if (game != null) rewritten.add(game);
  }
  return GamesArranged(
    order: order,
    rewritten: rewritten,
    before: first.before,
    heading: first.heading || second.heading,
  );
}
