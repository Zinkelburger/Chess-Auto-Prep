/// Chessable-style browser for a loaded repertoire: two primary actions
/// (Learn / Review) on top, chapters below, lines inside a chapter.
///
/// Design rules this file follows deliberately:
/// - **Two coloured things on the page**: the Learn and Review buttons.
///   Everything else is neutral ink on neutral surfaces, so the eye lands on
///   what to click. A muted Review button means "nothing is due".
/// - **Every clickable thing looks clickable**: bordered card, a verb, and a
///   chevron. No bare text rows.
/// - **One list at a time**: chapters, then that chapter's lines — never a
///   400-row wall of every variation in the course.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/training/controllers/training_session_controller.dart';
import '../../features/training/models/training_settings.dart';

import '../../design_system/components/item_title.dart';

import '../../models/line_status.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart';
import '../../theme/app_colors.dart';
import '../common/choice_field.dart';
import '../../theme/app_text_styles.dart';
import '../../design_system/components/list_search_field.dart';

part 'trainer_browser_cards.dart';

/// How the line list inside a chapter is ordered.
enum LineSortMode {
  /// Due first, then untrained, then learned — the order training uses.
  training,

  /// The order the lines appear in the file (course order).
  file,

  /// Highest cumulative path probability (most likely to be faced) first.
  probability,
}

extension LineSortModeLabel on LineSortMode {
  String get label => switch (this) {
    LineSortMode.training => 'Training order',
    LineSortMode.file => 'Course order',
    LineSortMode.probability => 'Most likely first',
  };

  String get description => switch (this) {
    LineSortMode.training =>
      'Lines that are due first, then untrained lines, then the ones you '
          'already know.',
    LineSortMode.file => 'The order the lines appear in the PGN file.',
    LineSortMode.probability =>
      'Lines you are most likely to face first, by cumulative opponent '
          'move probability.',
  };
}

class TrainerBrowser extends StatefulWidget {
  final TrainingSessionController session;

  /// Navigation stays with the screen; practice commands belong to [session].
  final VoidCallback? onBrowseChapters;
  final void Function(RepertoireLine line)? onPreviewLine;
  final void Function(List<RepertoireLine> lines)? onReadLines;
  final bool dense;

  const TrainerBrowser({
    super.key,
    required this.session,
    this.onBrowseChapters,
    this.onPreviewLine,
    this.onReadLines,
    this.dense = false,
  });

  @override
  State<TrainerBrowser> createState() => _TrainerBrowserState();
}

class _TrainerBrowserState extends State<TrainerBrowser> {
  TrainingSessionController get session => widget.session;

  LineSortMode _sortMode = LineSortMode.training;

  /// True while the deliberate "mark lines I already know" pass is active.
  /// The checkboxes exist only in this mode — there is no always-on toggle
  /// that could flip a line's learned state by accident.
  bool _selecting = false;
  bool _savingSelection = false;
  final Set<String> _checked = {};
  List<RepertoireLine>? _selectionLines;

  /// Type-to-filter over whichever list is showing. Deliberately *not* part
  /// of the selection scope: "mark known" keeps applying to the whole
  /// chapter, so narrowing the view can never silently shrink what a save
  /// writes.
  String _search = '';

  List<RepertoireLine> _searchFiltered(List<RepertoireLine> lines) => [
    for (final line in lines)
      if (matchesSearch(_search, '${line.name} ${line.moves.join(' ')}')) line,
  ];

  /// Chapter titles in file order; empty when the source has no chapters.
  List<String> get _chapters {
    final resolve = session.chapterOf;
    final seen = <String>{};
    final ordered = <String>[];
    for (final line in session.lines) {
      final chapter = resolve(line);
      if (chapter != null && seen.add(chapter)) ordered.add(chapter);
    }
    return ordered;
  }

  /// Lines under the open chapter — what every count, section and selection
  /// pass operates on.
  List<RepertoireLine> get _visibleLines => [
    for (final line in session.lines)
      if (session.lineInChapter(line, session.activeChapter)) line,
  ];

  void _enterSelection() {
    if (!mounted) return;
    setState(() {
      _selectionLines = session.lines;
      _selecting = true;
      _savingSelection = false;
      _checked
        ..clear()
        ..addAll([
          for (final line in _visibleLines)
            if (lineStatusOf(session.reviewMap[line.id]) !=
                LineStatus.untrained)
              line.id,
        ]);
    });
  }

  Future<void> _saveSelection() async {
    if (!mounted || _savingSelection) return;
    if (!identical(_selectionLines, session.lines)) {
      setState(() => _selecting = false);
      return;
    }
    setState(() => _savingSelection = true);
    try {
      await session.applyLearnedSelection(
        Set.of(_checked),
        within: {for (final line in _visibleLines) line.id},
      );
      if (mounted) setState(() => _selecting = false);
    } catch (_) {
      // The session retains the failure and offers a durable reload, not a
      // second save of a possibly partly committed selection.
    } finally {
      if (mounted) setState(() => _savingSelection = false);
    }
  }

  void _openChapter(String? chapter) {
    if (!mounted || _selecting) return;
    session.setActiveChapter(chapter);
  }

  List<RepertoireLine> _sorted(List<RepertoireLine> lines) {
    final sorted = List.of(lines);
    switch (_sortMode) {
      case LineSortMode.file:
        break;
      case LineSortMode.training:
        // Stable within a status band: dartchess-free, plain index tiebreak
        // (Dart's sort is not stable on its own).
        final index = {for (int i = 0; i < sorted.length; i++) sorted[i].id: i};
        int rank(RepertoireLine line) =>
            switch (lineStatusOf(session.reviewMap[line.id])) {
              LineStatus.due => 0,
              LineStatus.untrained => 1,
              LineStatus.learned => 2,
            };
        sorted.sort((a, b) {
          final cmp = rank(a).compareTo(rank(b));
          if (cmp != 0) return cmp;
          return index[a.id]!.compareTo(index[b.id]!);
        });
      case LineSortMode.probability:
        sorted.sort((a, b) {
          final ai = a.importance;
          final bi = b.importance;
          if (ai == null && bi == null) return 0;
          if (ai == null) return 1;
          if (bi == null) return -1;
          return bi.compareTo(ai);
        });
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _chapters;
    final multipleChapters =
        chapters.length > 1 ||
        (chapters.isNotEmpty &&
            session.lines.any((line) => session.chapterOf(line) == null));
    final showingChapterList =
        multipleChapters && session.activeChapter == null;
    final visible = _visibleLines;
    final counts = countLines(visible, session.reviewMap);
    final matchedChapters = [
      for (final chapter in chapters)
        if (matchesSearch(_search, chapter)) chapter,
    ];
    final matchedLines = _searchFiltered(visible);
    final searching = _search.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BrowserHeader(
          title: session.activeChapter == null
              ? session.repertoire!.name
              : _chapterTitle(session.activeChapter!),
          subtitle: session.sourceIsStudy
              ? null
              : '${session.sourceIsBlack ? 'Black' : 'White'} repertoire',
          counts: counts,
          dense: widget.dense,
          onBack: _selecting
              ? null
              : session.activeChapter == null || !multipleChapters
              ? widget.onBrowseChapters == null
                    ? null
                    : () {
                        if (mounted) widget.onBrowseChapters!();
                      }
              : () => _openChapter(null),
          onLearn: _selecting
              ? null
              : () {
                  if (mounted) session.startLearnSession();
                },
          onReview: _selecting
              ? null
              : () {
                  if (mounted) session.startReviewSession();
                },
          // Read the selected chapter, or the whole source.
          onRead: _selecting || visible.isEmpty || widget.onReadLines == null
              ? null
              : () {
                  if (mounted) widget.onReadLines!(visible);
                },
          learnBatchSize: session.repetitionMode == RepetitionMode.linear
              ? 0
              : session.settings.newLinesPerSession,
          reviewBatchSize: session.repetitionMode == RepetitionMode.linear
              ? 0
              : session.settings.reviewsPerSession,
        ),
        const Divider(height: 1),
        _ListToolbar(
          // While filtering the count reads "n of m" so a short list is
          // obviously the filter's doing, not lines having gone missing.
          label: showingChapterList
              ? (searching
                    ? '${matchedChapters.length} of ${chapters.length} chapters'
                    : '${chapters.length} chapter'
                          '${chapters.length == 1 ? '' : 's'}')
              : (searching
                    ? '${matchedLines.length} of ${visible.length} lines'
                    : '${visible.length} line'
                          '${visible.length == 1 ? '' : 's'}'),
          sortMode: _sortMode,
          onSortChanged: showingChapterList || widget.dense
              ? null
              : (mode) {
                  if (mounted) setState(() => _sortMode = mode);
                },
          onMarkKnown: _selecting || showingChapterList
              ? null
              : _enterSelection,
        ),
        if (_selecting)
          _SelectionBar(
            checkedCount: _checked.length,
            saving: _savingSelection,
            onSave: _saveSelection,
            onCancel: _savingSelection
                ? null
                : () {
                    if (mounted) setState(() => _selecting = false);
                  },
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(widget.dense ? 8 : 16, 8, 16, 0),
          child: ListSearchField(
            hintText: showingChapterList ? 'Search chapters' : 'Search lines',
            onChanged: (v) {
              if (mounted) setState(() => _search = v);
            },
          ),
        ),
        Expanded(
          child: showingChapterList
              ? _buildChapterList(chapters, matchedChapters)
              : _buildLineList(_sorted(matchedLines), searching),
        ),
      ],
    );
  }

  String _chapterTitle(String chapter) =>
      chapter == TrainingSessionController.ungroupedChapter
      ? 'Other lines'
      : chapter;

  /// [chapters] is every chapter (lines are grouped against all of them, or
  /// a filtered-out chapter's lines would have nowhere to land); [shown] is
  /// the subset that survived the search box.
  Widget _buildChapterList(List<String> chapters, List<String> shown) {
    final resolve = session.chapterOf;
    final grouped = <String, List<RepertoireLine>>{
      for (final chapter in chapters) chapter: <RepertoireLine>[],
    };
    final ungrouped = <RepertoireLine>[];
    for (final line in session.lines) {
      final chapter = resolve(line);
      if (chapter == null) {
        ungrouped.add(line);
      } else {
        grouped[chapter]!.add(line);
      }
    }

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: widget.dense ? 8 : 16,
        vertical: 10,
      ),
      children: [
        for (final chapter in shown)
          _ChapterCard(
            title: chapter,
            counts: countLines(grouped[chapter]!, session.reviewMap),
            lineCount: grouped[chapter]!.length,
            dense: widget.dense,
            onTap: () => _openChapter(chapter),
          ),
        if (ungrouped.isNotEmpty && matchesSearch(_search, 'Other lines'))
          _ChapterCard(
            title: 'Other lines',
            counts: countLines(ungrouped, session.reviewMap),
            lineCount: ungrouped.length,
            dense: widget.dense,
            onTap: () =>
                _openChapter(TrainingSessionController.ungroupedChapter),
          ),
      ],
    );
  }

  Widget _buildLineList(List<RepertoireLine> lines, bool searching) {
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            searching ? 'No lines match "$_search".' : 'No lines here yet.',
            style: const TextStyle(color: AppColors.onSurfaceMuted),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: widget.dense ? 8 : 16,
        vertical: 10,
      ),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        return _LineCard(
          line: line,
          status: lineStatusOf(session.reviewMap[line.id]),
          entry: session.reviewMap[line.id],
          onExclude: () {
            if (!mounted) return;
            unawaited(
              session.setLineExcluded(
                line,
                !(session.reviewMap[line.id]?.excluded ?? false),
              ),
            );
          },
          // A puzzle-start marker auto-plays its prelude in every mode; the
          // comment-based intro only applies when the setting is on.
          introLength:
              line.puzzleStartIndex ??
              (session.settings.skipToFirstComment
                  ? line.uncommentedIntroLength
                  : 0),
          dense: widget.dense,
          selecting: _selecting,
          checked: _checked.contains(line.id),
          onPreview: _selecting || widget.onPreviewLine == null
              ? null
              : () {
                  if (mounted) widget.onPreviewLine!(line);
                },
          // A model game is not yours to reproduce; the row opens the book
          // view instead of starting a drill the queue would refuse anyway.
          onTap: () {
            if (!mounted) return;
            if (_selecting) {
              setState(() {
                if (!_checked.remove(line.id)) _checked.add(line.id);
              });
            } else if (line.readOnlyLabel != null ||
                (session.reviewMap[line.id]?.excluded ?? false)) {
              widget.onPreviewLine?.call(line);
            } else {
              session.startLine(line);
            }
          },
        );
      },
    );
  }
}
