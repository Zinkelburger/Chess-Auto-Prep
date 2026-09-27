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
import '../../storage/reference_change.dart';
import '../../workspace/document_session.dart';
import 'library_state.dart';

/// One retained transaction owns preparation, publication, retries and training
/// identity for a cross-file transfer. Library owns catalog refresh and UI state.
final class LineTransfers {
  LineTransfers(this._store, this._session, this._lineWrites);
  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final PendingWrites _lineWrites;
  PendingObligation<store.SaveResult>? _lineMove;
  bool get pending => _lineMove != null;

  Future<LibraryResult> retry() async {
    final entry = _lineMove;
    if (entry == null) return const LibraryDone();
    final result = await entry.run();
    if (entry.committed) _lineMove = null;
    return _savedResult(result);
  }

  Future<LibraryResult> move(
    Chapter chapter,
    ChapterRef from,
    Set<int> moving,
    ChapterRef to,
    int? asSidelineOf,
  ) async {
    final ids = chapter.lineIds ?? trainedIds(chapter.lines);
    final pinned = <ChapterLine>[];
    for (final game in moving.toList()..sort()) {
      if (game < 0 || game >= chapter.lines.length) continue;
      final id = ids[game];
      final line = id == null
          ? chapter.lines[game]
          : withIdHeader(chapter.lines[game], id);
      if (line == null) {
        return const LibraryFailure(
          'The line identity could not be preserved.',
        );
      }
      pinned.add(line);
    }
    final prepared = await _session.externalEdits.prepare(
      (c) => linesTakenOut(c, games: moving),
    );
    if (prepared is ExternalEditRefused) return LibraryFailure(prepared.detail);
    final primary = prepared as PreparedDocumentEdit;
    final target = await _targetLines(to, pinned, asSidelineOf);
    if (target is _TargetRefused) return LibraryFailure(target.reason);
    final planned = target as _TargetPrepared;
    if (_session.source != from || !identical(_session.chapter, chapter)) {
      return const LibraryFailure(
        'The source chapter changed before the move.',
      );
    }
    final operationId = newCompoundId();
    var uncertain = false;
    final entry = _lineMove = _lineWrites.accept<store.SaveResult>(
      resource: this,
      label: 'Move repertoire lines',
      work: () => _session.access.changing(
        from.path,
        () => _session.access.changing(
          to.path,
          () => _session.externalEdits.commit(primary, (input) async {
            final result = await _store.savePair(
              store.DocumentEdit(
                ref: input.ref,
                text: input.text,
                expected: input.expected,
                scope: input.scope,
                movedLines: planned.ids,
                foldedLines: asSidelineOf == null
                    ? const {}
                    : pinned.map((line) => line.lineId).nonNulls.toSet(),
              ),
              planned.edit,
              operationId: operationId,
            );
            if (result is store.IoFailure) uncertain = true;
            return result;
          }),
        ),
      ),
      problem: (result) {
        if (result is store.IoFailure) uncertain = true;
        return uncertain && result is! store.Saved
            ? 'The line move needs retrying.'
            : null;
      },
    );
    final result = await entry.run();
    if (entry.committed) _lineMove = null;
    return _savedResult(result);
  }

  /// Prepares the destination without writing either participant.
  Future<_TargetLines> _targetLines(
    ChapterRef to,
    List<ChapterLine> lines,
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
    final mapping = <String, String>{};
    for (final line in arriving) {
      final next = withFreeId(line, file.lines.length + unique.length, taken);
      if (next == null) {
        return const _TargetRefused(
          'The line identity could not be preserved.',
        );
      }
      if (line.lineId != null && next.lineId != null) {
        mapping[line.lineId!] = next.lineId!;
      }
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
    return _TargetPrepared(
      store.DocumentEdit(
        ref: to,
        text: writeChapter(pinned.chapter),
        expected: read.revision,
        scope: GamesRearranged(pinned.games),
      ),
      host == null ? mapping : const {},
    );
  }

  LibraryResult _savedResult(store.SaveResult result) => switch (result) {
    store.Saved() => const LibraryDone(),
    store.Conflict() => const LibraryStale(),
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
