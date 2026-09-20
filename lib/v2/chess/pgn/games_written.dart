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
