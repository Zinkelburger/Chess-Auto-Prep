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

import 'package:flutter/material.dart';

import '../../models/line_status.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart';
import '../../theme/app_colors.dart';
import '../common/list_search_field.dart';

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
  /// Name of the loaded repertoire or study — the title when no chapter is
  /// open.
  final String title;

  /// One muted line under the title (colour, mode). Never a status the user
  /// has to decode.
  final String? subtitle;

  final List<RepertoireLine> lines;
  final Map<String, RepertoireReviewEntry> reviewMap;

  /// Chapter of a line under the current grouping, or null when the line has
  /// none. Null callback = this source has no chapters at all.
  final String? Function(RepertoireLine line)? chapterOf;

  /// Chapter currently open (null = the chapter list). Owned by the
  /// controller so the training queue is scoped to the same chapter.
  final String? activeChapter;
  final void Function(String? chapter)? onChapterSelected;

  /// Sentinel [activeChapter] value for lines the chapter scheme misses.
  final String ungroupedChapter;

  /// Start a Learn / Review run over the current scope. Null = nothing to do
  /// (the button renders muted and unclickable).
  final VoidCallback? onLearn;
  final VoidCallback? onReview;

  /// Train one specific line now.
  final void Function(RepertoireLine line) onTrainLine;

  /// Open the read-only board + comments view of a line.
  final void Function(RepertoireLine line)? onPreviewLine;

  /// Bulk "I already know these" pass over the visible lines.
  final Future<void> Function(Set<String> checkedLineIds, Set<String> scope)?
  onApplyLearnedSelection;

  /// Re-opens the "sort into chapters?" prompt.
  final VoidCallback? onOpenChapterSetup;

  /// Opens the trainer settings.
  final VoidCallback? onOpenSettings;

  /// Whether the uncommented intro auto-plays (dims those moves in the row
  /// preview, since they are shown rather than quizzed).
  final bool introEnabled;

  /// Narrow side-panel rendering: same structure, tighter, no page header.
  final bool dense;

  const TrainerBrowser({
    super.key,
    required this.title,
    this.subtitle,
    required this.lines,
    required this.reviewMap,
    this.chapterOf,
    this.activeChapter,
    this.onChapterSelected,
    required this.ungroupedChapter,
    this.onLearn,
    this.onReview,
    required this.onTrainLine,
    this.onPreviewLine,
    this.onApplyLearnedSelection,
    this.onOpenChapterSetup,
    this.onOpenSettings,
    this.introEnabled = false,
    this.dense = false,
  });

  @override
  State<TrainerBrowser> createState() => _TrainerBrowserState();
}

class _TrainerBrowserState extends State<TrainerBrowser> {
  LineSortMode _sortMode = LineSortMode.training;

  /// True while the deliberate "mark lines I already know" pass is active.
  /// The checkboxes exist only in this mode — there is no always-on toggle
  /// that could flip a line's learned state by accident.
  bool _selecting = false;
  bool _savingSelection = false;
  final Set<String> _checked = {};

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
    final resolve = widget.chapterOf;
    if (resolve == null) return const [];
    final seen = <String>{};
    final ordered = <String>[];
    for (final line in widget.lines) {
      final chapter = resolve(line);
      if (chapter != null && seen.add(chapter)) ordered.add(chapter);
    }
    return ordered;
  }

  bool _inChapter(RepertoireLine line, String? chapter) {
    if (chapter == null) return true;
    final own = widget.chapterOf?.call(line);
    return chapter == widget.ungroupedChapter ? own == null : own == chapter;
  }

  /// Lines under the open chapter — what every count, section and selection
  /// pass operates on.
  List<RepertoireLine> get _visibleLines => [
    for (final line in widget.lines)
      if (_inChapter(line, widget.activeChapter)) line,
  ];

  void _enterSelection() {
    setState(() {
      _selecting = true;
      _savingSelection = false;
      _checked
        ..clear()
        ..addAll([
          for (final line in _visibleLines)
            if (lineStatusOf(widget.reviewMap[line.id]) != LineStatus.untrained)
              line.id,
        ]);
    });
  }

  Future<void> _saveSelection() async {
    final apply = widget.onApplyLearnedSelection;
    if (apply == null) return;
    setState(() => _savingSelection = true);
    await apply(Set.of(_checked), {for (final line in _visibleLines) line.id});
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _savingSelection = false;
    });
  }

  void _openChapter(String? chapter) {
    if (_selecting) return;
    widget.onChapterSelected?.call(chapter);
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
            switch (lineStatusOf(widget.reviewMap[line.id])) {
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
    final showingChapterList =
        chapters.isNotEmpty && widget.activeChapter == null;
    final visible = _visibleLines;
    final counts = countLines(visible, widget.reviewMap);
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
          title: widget.activeChapter == null
              ? widget.title
              : _chapterTitle(widget.activeChapter!),
          subtitle: widget.activeChapter == null
              ? widget.subtitle
              : '${visible.length} line${visible.length == 1 ? '' : 's'} in '
                    'this chapter',
          counts: counts,
          dense: widget.dense,
          onBack: widget.activeChapter == null || _selecting
              ? null
              : () => _openChapter(null),
          onLearn: _selecting ? null : widget.onLearn,
          onReview: _selecting ? null : widget.onReview,
          onOpenChapterSetup: _selecting ? null : widget.onOpenChapterSetup,
          onOpenSettings: _selecting ? null : widget.onOpenSettings,
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
              : (mode) => setState(() => _sortMode = mode),
          onMarkKnown:
              _selecting ||
                  widget.onApplyLearnedSelection == null ||
                  showingChapterList
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
                : () => setState(() => _selecting = false),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(widget.dense ? 8 : 16, 8, 16, 0),
          child: ListSearchField(
            hintText: showingChapterList ? 'Search chapters' : 'Search lines',
            onChanged: (v) => setState(() => _search = v),
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
      chapter == widget.ungroupedChapter ? 'Other lines' : chapter;

  /// [chapters] is every chapter (lines are grouped against all of them, or
  /// a filtered-out chapter's lines would have nowhere to land); [shown] is
  /// the subset that survived the search box.
  Widget _buildChapterList(List<String> chapters, List<String> shown) {
    final resolve = widget.chapterOf;
    final grouped = <String, List<RepertoireLine>>{
      for (final chapter in chapters) chapter: <RepertoireLine>[],
    };
    final ungrouped = <RepertoireLine>[];
    for (final line in widget.lines) {
      final chapter = resolve?.call(line);
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
            counts: countLines(grouped[chapter]!, widget.reviewMap),
            dense: widget.dense,
            onTap: () => _openChapter(chapter),
          ),
        if (ungrouped.isNotEmpty && matchesSearch(_search, 'Other lines'))
          _ChapterCard(
            title: 'Other lines',
            counts: countLines(ungrouped, widget.reviewMap),
            dense: widget.dense,
            onTap: () => _openChapter(widget.ungroupedChapter),
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
          status: lineStatusOf(widget.reviewMap[line.id]),
          entry: widget.reviewMap[line.id],
          // A puzzle-start marker auto-plays its prelude in every mode; the
          // comment-based intro only applies when the setting is on.
          introLength:
              line.puzzleStartIndex ??
              (widget.introEnabled ? line.uncommentedIntroLength : 0),
          dense: widget.dense,
          selecting: _selecting,
          checked: _checked.contains(line.id),
          onPreview: _selecting || widget.onPreviewLine == null
              ? null
              : () => widget.onPreviewLine!(line),
          onTap: _selecting
              ? () => setState(() {
                  if (!_checked.remove(line.id)) _checked.add(line.id);
                })
              : () => widget.onTrainLine(line),
        );
      },
    );
  }
}
