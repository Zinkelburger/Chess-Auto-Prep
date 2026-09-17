import '../../chess_core/pgn/repertoire_pgn_text.dart';
import '../../chess_core/pgn/repertoire_document_mutation.dart';
import '../../features/documents/models/pgn_document.dart';
import '../../features/repertoires/models/repertoire_mutation_receipt.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../features/repertoires/repositories/repertoire_document_repository.dart';
import '../../utils/atomic_file.dart' show AtomicWriteConflict;

/// Adapts the shared PGN store to validated Builder mutation receipts. The app chooses the native or legacy store at its composition root.
/// There is no storage singleton or direct file access here.
class DocumentRepertoireRepository implements RepertoireDocumentRepository {
  const DocumentRepertoireRepository(this.documents);
  final PgnDocumentStore documents;

  @override
  Future<PgnOpenResult> read(String path) => documents.open(path);

  @override
  Future<PgnWriteResult> appendPgn(String path, String capturedPgn) async {
    if (capturedPgn.trim().isEmpty) {
      return const PgnWriteFailed(
        FormatException('An appended draft is empty'),
      );
    }
    final PgnSnapshot before;
    try {
      before = await _openRequired(path);
    } catch (error) {
      return PgnWriteFailed(error);
    }
    // Preserve the original text and the captured annotation/header payload.
    // This is append intent, not a whole-document replacement from a stale UI.
    final updated = '${before.content}\n\n$capturedPgn\n';
    try {
      final result = await documents.save(before, updated);
      if (result is PgnSaved &&
          (result.before?.revision != before.revision ||
              result.before?.content != before.content ||
              result.after.path != before.path ||
              result.after.revision.documentId != before.revision.documentId ||
              result.after.content != updated)) {
        return PgnWriteUncertain(
          error: StateError('Invalid append acknowledgement'),
          before: before,
          observed: result.after,
          recoveryPath: result.recoveryPath,
        );
      }
      // Keep uncertainty and installation evidence intact for the workspace.
      // Decoded-text equality cannot authorize clearing or repeating a draft.
      return result;
    } catch (error) {
      return PgnWriteUncertain(error: error, before: before, observed: null);
    }
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
  }) async {
    final before = await _openRequired(path);
    if (before.content != expectedContent) throw AtomicWriteConflict(path);
    final result = await documents.save(before, content);
    _requireSaved(path, result);
  }

  @override
  Future<RepertoireMutationReceipt> append(
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
    final after = result.steps.isEmpty
        ? before
        : await _confirm(
            before,
            result.updatedContent,
            await documents.save(before, result.updatedContent),
          );
    final receipt = RepertoireMutationReceipt(
      requestedDocumentPath: path,
      before: before,
      after: after,
      mutation: result,
    );
    receipt.validate(path: path, requestedPath: [...pathFromRoot, ...newMoves]);
    return receipt;
  }

  @override
  Future<PgnSnapshot> restore(PgnSnapshot expected, String content) async =>
      _confirm(expected, content, await documents.save(expected, content));

  Future<PgnSnapshot> _confirm(
    PgnSnapshot expected,
    String content,
    PgnWriteResult result,
  ) async {
    if (result is PgnWriteUncertain) {
      // Installation proof must come from the store's staged identity and
      // digest. A later read of equal text cannot manufacture that proof.
      final installed = result.installedRevision;
      if (installed != null &&
          installed.documentId == expected.revision.documentId &&
          result.before?.content == expected.content &&
          result.observed?.path == expected.path &&
          result.before?.revision == expected.revision &&
          result.observed?.revision == installed &&
          result.observed?.content == content) {
        final current = await documents.open(expected.path);
        if (current is PgnOpened &&
            current.snapshot.path == expected.path &&
            current.snapshot.revision == installed &&
            current.snapshot.content == content) {
          return current.snapshot;
        }
      }
    }
    final saved = _requireSaved(expected.path, result, expected: expected);
    if (saved.content != content ||
        saved.path != expected.path ||
        saved.revision.documentId != expected.revision.documentId) {
      throw StateError('Invalid native mutation acknowledgement');
    }
    return saved;
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
  Future<RepertoireLineSaveReceipt?> updateLineContent(
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
    final snapshot = _requireSaved(
      path,
      await documents.save(before, updated),
      expected: before,
    );
    if (snapshot.path != path ||
        snapshot.content != updated ||
        snapshot.revision.documentId != before.revision.documentId) {
      throw StateError('Invalid line save acknowledgement');
    }
    return (
      documentPgn: updated,
      snapshot: snapshot,
      linePgn: savedGame,
      lineIndex: index,
    );
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

  PgnSnapshot _requireSaved(
    String path,
    PgnWriteResult result, {
    PgnSnapshot? expected,
  }) {
    switch (result) {
      case PgnSaved(:final before, :final after):
        if (expected != null &&
            (before?.revision != expected.revision ||
                before?.content != expected.content)) {
          throw StateError('Invalid mutation baseline acknowledgement');
        }
        return after;
      case PgnConflict():
      case PgnNameCollision():
        throw AtomicWriteConflict(path);
      case PgnWriteFailed(:final error):
      case PgnWriteUncertain(:final error):
        throw error;
    }
  }
}
