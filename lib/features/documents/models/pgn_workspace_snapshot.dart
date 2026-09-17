import 'document_save_state.dart';
import 'pgn_document.dart';

/// An immutable recovery checkpoint. Per-game originals preserve the scoped
/// merge contract after restart; the full source revision remains separate.
class PgnWorkspaceSnapshot {
  PgnWorkspaceSnapshot({
    required this.path,
    required this.content,
    required this.dirty,
    required List<String> persistedGames,
    this.baseline,
    this.wholeReplacement = false,
    this.uncertain = false,
    this.uncertainPath,
    List<RetainedDocumentDraft> retainedDrafts = const [],
    this.gameIndex = 0,
    this.ply = 0,
    this.flipped = false,
  }) : persistedGames = List.unmodifiable(persistedGames),
       retainedDrafts = List.unmodifiable(retainedDrafts);
  final String path;
  final String content;
  final bool dirty;
  final List<String> persistedGames;
  final PgnSnapshot? baseline;
  final bool wholeReplacement;
  final bool uncertain;
  final String? uncertainPath;
  final List<RetainedDocumentDraft> retainedDrafts;
  final int gameIndex;
  final int ply;
  final bool flipped;
  bool get needsRecovery => dirty || uncertain || retainedDrafts.isNotEmpty;
}
