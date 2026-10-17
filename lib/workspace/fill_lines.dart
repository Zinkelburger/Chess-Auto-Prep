import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../chess/openings.dart';
import '../chess/generation/draft_chapter.dart';
import '../chess/generation/draft_lines.dart';
import '../chess/generation/traps.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_heading.dart';
import '../chess/pgn/tree_edit.dart' show positionOf;
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/pending_writes.dart';
import '../storage/pgn_document_store.dart' as store;
import 'engine_jobs.dart';
import 'fill_states.dart';
import 'generated_draft.dart';
import 'opening_names.dart';
import 'search_opponents.dart';

/// Turns a finished search into lines: a draft chapter written through the
/// store as a new file beside the chapter the search was started on, which
/// is never touched itself.
///
/// A drafted line that stops mid-fight is continued with the engine's best
/// line from where it stops, scored now when the search did not keep one.
/// The draft is an accepted write: one that fails keeps its destination and
/// text until a retry lands it or the user gives it up ([discard]).
final class FillLines {
  FillLines({
    required this._owner,
    required this._jobs,
    required this._store,
    required this._tools,
    required this._pending,
    required this._engineDepths,
    required this._bestLines,
    required this._clock,
    required this._closed,
    this.openings,
  });

  /// The search the lines are made for: it holds the machine while line
  /// ends are scored, as it does while it searches.
  final Object _owner;
  final EngineJobs _jobs;
  final store.PgnDocumentStore _store;
  final FillToolsFactory _tools;
  final PendingWrites _pending;

  /// The search's engine depths and best lines by four-field position,
  /// which scoring a line end adds to.
  final Map<String, int> _engineDepths;
  final Map<String, List<String>> _bestLines;
  final DateTime Function() _clock;

  /// Whether the search has gone, which stops scoring line ends.
  final bool Function() _closed;

  /// Names a draft's lines after their openings; unnamed without it.
  final OpeningNames? openings;

  GeneratedDraft? _draft;
  int _draftLines = 0;
  PendingObligation<DraftPublication>? _draftSave;

  /// Whether an accepted draft has still to be saved.
  bool get saving => _draftSave != null;

  /// Gives up the draft whose save failed; false when there is none, or it
  /// cannot be given up now.
  bool discard() {
    if (_draftSave?.discard() != true) return false;
    _draftSave = null;
    return true;
  }

  /// A new search starts: the next lines are a new draft.
  void forget() => _draft = null;

  /// Writes [found]'s best lines, and the traps on them, into a draft
  /// chapter beside [source]: [chapter] as it was when the run started, so
  /// what it already plays is left out. A draft whose save failed is saved
  /// again as it was, not worked out again. Answers how many lines it holds.
  Future<(DraftPublication, int)> write(
    FillFound found,
    Chapter chapter,
    ChapterRef source,
  ) async {
    if (_draftSave case final saved?) {
      final result = await saved.run();
      if (saved.committed) _draftSave = null;
      return (result, _draftLines);
    }
    final heading = readHeading(chapter.preamble);
    final prefix = chapter.tree.lineTo(found.target.cursor);
    final rootFen = chapter.tree.rootFen;
    final rootMoves = heading.rootFen == rootFen
        ? heading.rootMoves
        : const <String>[];
    final created = _clock();
    final (plan, traps) = await foundIn(
      found.tree,
      known: chapterDecisions(chapter),
    );
    if (plan.lines == 0) {
      return (
        const DraftNotWritten(
          'The search found no line the chapter does not already have.',
        ),
        0,
      );
    }
    final lines = withTraps(plan, traps);
    await _scoreLineEnds(found.request, lineEnds(lines));
    final continued = withContinuations(lines, _bestLines);
    final names = await openings?.load() ?? Openings.none;
    // Checked last, so a chapter moved while line ends were scored is refused;
    // the instant before create is accepted rather than change every store.
    if (_draft == null) {
      final gone = switch (await _store.open(source)) {
        store.Opened() => null,
        store.Absent() =>
          'The chapter was moved, renamed or deleted since '
              'the search. Search again to make lines.',
        store.Unreadable(:final detail) =>
          'The chapter cannot be read: $detail',
      };
      if (gone != null) return (DraftNotWritten(gone), 0);
    }
    final draft = _draft ??= GeneratedDraft(
      documents: _store,
      folder: p.dirname(source.path),
      chapter: source.name,
      textFor: (name) => draftChapterText(
        name: name,
        side: chapter.side,
        rootFen: rootFen,
        rootMoves: rootMoves,
        prefix: prefix,
        plan: continued,
        created: created,
        openings: names,
      ),
    );
    _draftLines = plan.lines;
    final entry = _draftSave = _pending.accept<DraftPublication>(
      resource: draft,
      label: 'Generated draft',
      work: draft.write,
      problem: (result) => result is DraftNotWritten ? result.reason : null,
    );
    final result = await entry.run();
    if (entry.committed) _draftSave = null;
    return (result, plan.lines);
  }

  /// Asks the engine for its best line at each of [ends] this session has
  /// none for — a score the cache answered, or a search resumed from a
  /// saved tree — so every drafted line can be continued. The board's
  /// engine waits meanwhile, as it does for a search. A line whose end the
  /// engine cannot read is written as it is. A mainline book ends where
  /// ChessDB knows no more, and is written so.
  Future<void> _scoreLineEnds(FillRequest request, Set<Fen> ends) async {
    if (request.method == SearchMethod.mainline) return;
    final missing = [
      for (final end in ends)
        if (!_bestLines.containsKey(end.position)) end,
    ];
    // Another job holding the machine keeps it: the lines are written as
    // they are.
    if (missing.isEmpty ||
        !_jobs.take(
          _owner,
          'Paused while making lines',
          kind: EngineJobKind.makingLines,
        )) {
      return;
    }
    try {
      final tools = await _tools(request);
      if (tools is! FillReady) return;
      try {
        final engine = tools.continuations;
        for (final end in missing) {
          final position = positionOf(end);
          if (engine == null || position == null || _closed()) break;
          await EngineAnswers(
            engine,
            depths: _engineDepths,
            lines: _bestLines,
          ).evaluate(position);
        }
      } finally {
        await tools.release();
      }
    } on Object catch (error) {
      log.w('continue drafted lines', error);
    } finally {
      _jobs.release(_owner);
    }
  }
}
