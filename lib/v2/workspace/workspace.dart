import '../storage/settings_store.dart';
import 'books.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'explorer.dart';
import 'fill_gaps.dart';
import 'finds.dart';
import 'game_fetcher.dart';
import 'gap_hunt.dart';
import 'local_games.dart';
import 'replies.dart';
import 'repertoire_shelf.dart';
import 'repertoire_tree.dart';

/// The owners of the one workspace every mode shares: the document and its
/// saver, and what is worked out from where the cursor is.
///
/// Handed as one value to what lays the workspace out — the window, the
/// workspace view, the Actions menu — so a new owner is one field here, not
/// one more parameter on each of them. A panel inside still takes only the
/// one or two owners it reads. This holds them and does not own them:
/// whoever built them disposes them.
final class Workspace {
  const Workspace({
    required this.session,
    required this.saver,
    required this.settings,
    required this.analysis,
    required this.explorer,
    required this.games,
    required this.replies,
    required this.gaps,
    required this.shelf,
    required this.books,
    required this.tree,
    required this.fill,
    required this.finds,
    required this.myGamesTree,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final SettingsStore settings;
  final EngineAnalysis analysis;
  final Explorer explorer;

  /// Keeps a game the explorer lists as a file, to open it.
  final GameFetcher games;
  final Replies replies;
  final GapHunt gaps;

  /// Every repertoire file, indexed by position: the explorer's Book and My games
  /// read the same one.
  final RepertoireShelf shelf;

  /// The user's books: what the explorer's Book, My games and the trainer
  /// read the repertoires through.
  final Books books;

  /// The user's own repertoires, looked up by position: the explorer's Book.
  final RepertoireTree tree;
  final FillGaps fill;

  /// What the searches have pointed out: the Positions list.
  final Finds finds;

  /// The user's saved games as one opening tree: the explorer's
  /// `My games`, read again when their games change.
  final LocalGames myGamesTree;
}
