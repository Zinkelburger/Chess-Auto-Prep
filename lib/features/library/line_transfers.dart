import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/chapter_sections.dart';
import '../../chess/pgn/games_written.dart';
import '../../chess/pgn/line_id_pins.dart';
import '../../chess/pgn/line_moves.dart';
import '../../storage/chapter_files.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/operation_id.dart';
import '../../workspace/document_session.dart';
import 'library_state.dart';

/// One retained transaction owns preparation, publication, retries and training
/// identity for a cross-file transfer. Library owns catalog refresh and UI state.
final class LineTransfers {
  LineTransfers(this._store, this._session, this._lineWrites);
  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final PendingWrites _lineWrites;
  _LineMove? _lineMove;
  bool get pending => _lineMove != null;

  /// Abandons a move whose retries keep failing, for example on a read-only
  /// disk. Nothing already written is undone; false while a retry runs. The
  /// source chapter, held still while the answer was unknown, is read again.
  Future<bool> discard() async {
    final move = _lineMove;
    if (move == null || !move.entry.discard()) return false;
    _lineMove = null;
    if (_session.externalEdits.release(move.edit) &&
        _session.source == move.from) {
      await _session.reloadFromDisk();
    }
    return true;
  }

  Future<LibraryResult> retry() async {
    final move = _lineMove;
    if (move == null) return const LibraryDone();
    return _finished(move, await move.entry.run());
  }

  /// A move the store recorded is finished by recovery on the next access,
  /// which a read of the source is: when the move left the editor behind its
  /// file, it is read again and shows what the file holds. If the read fails,
  /// the source stays behind its file and offers Reload. An editor opened
  /// again since then keeps whatever it shows.
  Future<LibraryResult> _finished(
    _LineMove move,
    store.SaveResult result,
  ) async {
    if (move.entry.committed && identical(_lineMove, move)) _lineMove = null;
    if (result is store.Unfinished &&
        _session.source == move.from &&
        _session.externalEdits.behindFile) {
      await _session.reloadFromDisk();
    }
    return _savedResult(result);
  }

  Future<LibraryResult> move(
    Chapter chapter,
    ChapterRef from,
    Set<int> moving,
    ChapterRef to,
    int? asSidelineOf,
  ) async {
    final ids = chapter.lineIds ?? trainedIdsOf(chapter);
    final pinned = <ChapterLine>[];
    final sourceIds = <String?>[];
    for (final game in moving.toList()..sort()) {
      if (game < 0 || game >= chapter.lines.length) continue;
      final line = chapter.lines[game];
      final id = ids[game];
      sourceIds.add(id);
      // A line no header both apps read can carry moves as it is, and its
      // id changes in both, as a move above it would ([withIdsPinned]).
      pinned.add(id == null ? line : withIdHeader(line, id) ?? line);
    }
    final prepared = await _session.externalEdits.prepare(
      (c) => linesTakenOut(c, games: moving),
    );
    if (prepared is ExternalEditRefused) return LibraryFailure(prepared.detail);
    final primary = prepared as PreparedDocumentEdit;
    final target = await _targetLines(to, pinned, sourceIds, asSidelineOf);
    if (target is _TargetRefused) return LibraryFailure(target.reason);
    final planned = target as _TargetPrepared;
    if (_session.source != from || !identical(_session.chapter, chapter)) {
      return const LibraryFailure(
        'The source chapter changed before the move.',
      );
    }
    final operationId = newOperationId();
    final entry = _lineWrites.accept<store.SaveResult>(
      resource: this,
      label: 'Move repertoire lines',
      work: () => _session.access.changing(
        from.path,
        () => _session.access.changing(
          to.path,
          () => _session.externalEdits.commit(
            primary,
            (input) => _store.savePair(
              store.DocumentEdit(
                ref: input.ref,
                text: input.text,
                expected: input.expected,
                scope: input.scope,
                movedLines: planned.ids,
                foldedLines: asSidelineOf == null
                    ? const {}
                    : sourceIds.nonNulls.toSet(),
              ),
              planned.edit,
              operationId: operationId,
            ),
          ),
        ),
      ),
      // Any other answer is final: a retry of an operation that landed is
      // answered Saved, so a refusal means this move never happened and the
      // user plans it again against what is on disk now. One the store
      // recorded is final too: recovery finishes it, after a restart too.
      problem: (result) =>
          result is store.IoFailure && result is! store.Unfinished
          ? 'The line move needs retrying.'
          : null,
    );
    final move = _lineMove = (entry: entry, from: from, edit: primary);
    return _finished(move, await entry.run());
  }

  /// Prepares the destination without writing either participant.
  Future<_TargetLines> _targetLines(
    ChapterRef to,
    List<ChapterLine> lines,
    List<String?> sourceIds,
    int? host,
  ) async {
    final read = await _store.open(to);
    if (read is! store.Opened || read.readOnly != null) {
      return _TargetRefused('${to.name} could not be opened for editing');
    }
    final file = await readChapter(name: to.fileName, text: read.text);
    final view = sectionView(file, to.section);
    final arriving = _namedAs(view.stamp, lines);
    if (arriving == null) {
      return const _TargetRefused(
        'The line chapter names could not be changed.',
      );
    }
    // Reserve ids across the whole course, including sections not on screen.
    final taken = idsInUse(file);
    final unique = <ChapterLine>[];
    for (final line in arriving) {
      final next = withFreeId(line, file.lines.length + unique.length, taken);
      unique.add(next);
    }
    Chapter target = view.chapter;
    var arrangement = GamesArranged.of(
      GamesWritten(),
      before: target.lines.length,
    );
    final edits = host == null
        ? <ChapterEdit Function(Chapter)>[(c) => linesAddedTo(c, lines: unique)]
        : <ChapterEdit Function(Chapter)>[
            for (final line in unique)
              (c) => lineGraftedInto(c, host: host, line: line),
          ];
    for (final change in edits) {
      final edit = change(target);
      if (edit is ChapterEditRefused) return _TargetRefused(edit.reason);
      if (edit is ChapterEdited) {
        target = edit.chapter;
        arrangement =
            composedArrangement(arrangement, edit.games) ?? edit.games;
      }
    }
    final back = spliced(view, target, arrangement);
    if (back == null) {
      return const _TargetRefused('The destination could not be updated.');
    }
    final pinned = withIdsPinned(file, back.file, back.games);
    // Headers may not name the ids either app trains. Follow the arriving
    // games through the complete file arrangement, after collision handling
    // and pinning, rather than mapping their raw LineID tags.
    final mapping = <String, String>{};
    if (host == null) {
      final targetIds = trainedIdsOf(pinned.chapter);
      var arriving = 0;
      for (final (place, from) in pinned.games.order.indexed) {
        if (from != null) continue;
        final source = sourceIds[arriving++];
        final target = targetIds[place];
        if (source != null && target != null) mapping[source] = target;
      }
    }
    return _TargetPrepared(
      store.DocumentEdit(
        ref: to,
        text: writeChapter(pinned.chapter),
        expected: read.revision,
        scope: GamesRearranged(pinned.games),
      ),
      mapping,
    );
  }

  LibraryResult _savedResult(store.SaveResult result) => switch (result) {
    store.Saved() => const LibraryDone(),
    store.Conflict() => const LibraryStale(),
    store.Unfinished(:final detail) => LibraryUnfinished(detail),
    store.SaveDidNotLand(:final detail) => LibraryFailure(detail),
  };
}

/// [lines] each naming [section] as its chapter, or no chapter when it is
/// null; null when one of them cannot be given the name.
List<ChapterLine>? _namedAs(String? section, List<ChapterLine> lines) {
  final named = <ChapterLine>[];
  for (final line in lines) {
    final renamed = sectionOf(line) == section
        ? line
        : withSection(line, section);
    if (renamed == null) return null;
    named.add(renamed);
  }
  return named;
}

/// A retained move and what discarding it must let go of.
typedef _LineMove = ({
  PendingObligation<store.SaveResult> entry,
  ChapterRef from,
  PreparedDocumentEdit edit,
});

sealed class _TargetLines {
  const _TargetLines();
}

final class _TargetRefused extends _TargetLines {
  const _TargetRefused(this.reason);
  final String reason;
}

final class _TargetPrepared extends _TargetLines {
  const _TargetPrepared(this.edit, this.ids);
  final store.DocumentEdit edit;
  final Map<String, String> ids;
}
