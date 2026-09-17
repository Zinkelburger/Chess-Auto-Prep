import '../../chess_core/pgn/repertoire_pgn_text.dart';
import '../../chess_core/pgn/repertoire_document_mutation.dart';
import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../features/repertoires/repositories/repertoire_document_repository.dart';
import '../../utils/atomic_file.dart' show AtomicWriteConflict;

/// Adapts the shared PGN store to the Builder's existing decoded-content undo
/// contract. The app chooses the native or legacy store at its composition root.
/// There is no storage singleton or direct file access here.
class DocumentRepertoireRepository implements RepertoireDocumentRepository {
  const DocumentRepertoireRepository(this.documents);
  final PgnDocumentStore documents;

  @override
  Future<({bool exists, String? pgn})> read(String path) async {
    return switch (await documents.open(path)) {
      PgnOpened(:final snapshot) => (exists: true, pgn: snapshot.content),
      PgnMissing() => (exists: false, pgn: null),
      PgnReadFailed(:final error) => throw error,
    };
  }

  Future<PgnSnapshot> _openRequired(String path) async {
    return switch (await documents.open(path)) {
      PgnOpened(:final snapshot) => snapshot,
      PgnMissing() => throw StateError('The selected chapter is unavailable.'),
      PgnReadFailed(:final error) => throw error,
    };
  }

  @override
  Future<void> replace(
    String path,
    String content, {
    required String expectedContent,
    bool reconcileInstalled = false,
  }) async {
    final before = await _openRequired(path);
    if (before.content != expectedContent) throw AtomicWriteConflict(path);
    final result = await documents.save(before, content);
    // Only undo opts into S0's exact decoded-result reconciliation. No new
    // expectation is taken from disk, and logical append is never replayed.
    if (reconcileInstalled && result is PgnWriteUncertain) {
      final observed = await documents.open(path);
      if (observed is PgnOpened && observed.snapshot.content == content) return;
    }
    _requireSaved(path, result);
  }

  @override
  Future<AppendMovesResult> append(
    String path,
    List<String> prefix,
    List<String> moves, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  }) async {
    // Capture intent before awaiting; callers cannot mutate a queued request.
    final pathFromRoot = List<String>.of(prefix);
    final newMoves = List<String>.of(moves);
    final before = await _openRequired(path);
    final result = prepareAppendMoves(
      before.content,
      pathFromRoot,
      newMoves,
      startingFen: startingFen,
      isWhiteRepertoire: isWhiteRepertoire,
    );
    result.validate(requestedPath: [...pathFromRoot, ...newMoves]);
    if (result.steps.isNotEmpty) {
      _requireSaved(path, await documents.save(before, result.updatedContent));
    }
    return result;
  }

  Future<PgnSnapshot?> _optional(String path) async =>
      switch (await documents.open(path)) {
        PgnOpened(:final snapshot) => snapshot,
        PgnMissing() => null,
        PgnReadFailed(:final error) => throw error,
      };

  @override
  Future<bool> deleteLine(
    String path,
    String lineId, {
    required String expectedContent,
  }) async {
    final before = await _optional(path);
    if (before == null) return false;
    final document = splitRepertoireDocument(before.content);
    final games = List<String>.of(document.games);
    final index = lineIdsForGames(games).indexOf(lineId);
    if (index < 0) return false;
    if (games[index].trim() != expectedContent.trim()) {
      throw AtomicWriteConflict(path);
    }
    games.removeAt(index);
    _requireSaved(
      path,
      await documents.save(
        before,
        reassemblePgnDocument(document.preamble, games),
      ),
    );
    return true;
  }

  @override
  Future<String?> updateLineContent(
    String path,
    String lineId,
    String content, {
    required String expectedContent,
  }) async {
    final before = await _optional(path);
    if (before == null) return null;
    final document = splitRepertoireDocument(before.content);
    final games = List<String>.of(document.games);
    var index = lineIdsForGames(games).indexOf(lineId);
    if (index < 0) {
      // A previous structural edit can change a move-derived id. Its exact
      // acknowledged game still identifies the bound line, but duplicates do
      // not authorize choosing an arbitrary occurrence.
      final matches = [
        for (var i = 0; i < games.length; i++)
          if (games[i].trim() == expectedContent.trim()) i,
      ];
      if (matches.isEmpty) return null;
      if (matches.length != 1) throw AtomicWriteConflict(path);
      index = matches.single;
    }
    if (games[index].trim() != expectedContent.trim()) {
      throw AtomicWriteConflict(path);
    }
    final replacement = splitRepertoireDocument(content);
    if (replacement.games.length != 1) {
      throw const FormatException('A line edit must contain exactly one game');
    }
    games[index] = mergeMissingHeaders(games[index], replacement.games.single);
    final updated = reassemblePgnDocument(document.preamble, games);
    // Return the exact game a subsequent read will observe, including headers
    // retained by the merge; future saves advance only from this receipt.
    final savedGame = splitRepertoireDocument(updated).games[index];
    _requireSaved(path, await documents.save(before, updated));
    return savedGame;
  }

  @override
  Future<int> deleteLinesAt(String path, Map<int, String> expectedGames) async {
    final selected = Map<int, String>.of(expectedGames);
    if (selected.isEmpty) return 0;
    final before = await _optional(path);
    if (before == null) return 0;
    final document = splitRepertoireDocument(before.content);
    // An external insert/reorder cannot make an old index authorize deletion
    // of a different game. Validate every selected game before changing any.
    for (final entry in selected.entries) {
      if (entry.key < 0 ||
          entry.key >= document.games.length ||
          document.games[entry.key].trim() != entry.value.trim()) {
        throw AtomicWriteConflict(path);
      }
    }
    final kept = [
      for (var i = 0; i < document.games.length; i++)
        if (!selected.containsKey(i)) document.games[i],
    ];
    _requireSaved(
      path,
      await documents.save(
        before,
        reassemblePgnDocument(document.preamble, kept),
      ),
    );
    return document.games.length - kept.length;
  }

  void _requireSaved(String path, PgnWriteResult result) {
    switch (result) {
      case PgnSaved():
        return;
      case PgnConflict():
      case PgnNameCollision():
        throw AtomicWriteConflict(path);
      case PgnWriteFailed(:final error):
      case PgnWriteUncertain(:final error):
        throw error;
    }
  }
}
