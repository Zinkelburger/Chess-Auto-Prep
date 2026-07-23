import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart';
import '../../theme/app_colors.dart';

part 'training_lines_controls.dart';
part 'training_lines_row.dart';

/// How the Lines tab orders lines within each section.
enum LineSortMode {
  /// Default heuristic: due lines by failure rate, learned lines by due date.
  smart,

  /// Highest cumulative path probability (line importance) first.
  probability,

  /// Hardest to play (lowest playability) first.
  ease,
}

extension LineSortModeLabel on LineSortMode {
  String get label => switch (this) {
    LineSortMode.smart => 'Needs work first',
    LineSortMode.probability => 'Most common first',
    LineSortMode.ease => 'Hardest first',
  };

  /// Shown as a tooltip so "Needs work first" is never a mystery.
  String get description => switch (this) {
    LineSortMode.smart =>
      'Due lines with the highest fail rate first; learned lines by '
          'soonest due date; new lines in file order.',
    LineSortMode.probability =>
      'Lines you are most likely to face first, by cumulative opponent '
          'move probability.',
    LineSortMode.ease =>
      'Lines whose moves are least natural to find first (playability '
          'score from the generated tree).',
  };
}

/// "1.e4 e6 2.d4 d5" movetext for [line] from ply [start] (inclusive) to
/// [end] (exclusive; defaults to the whole line).
String formatLineMovesText(RepertoireLine line, {int start = 0, int? end}) {
  final stop = (end ?? line.moves.length).clamp(0, line.moves.length);
  final startFullmoves = line.startPosition.fullmoves;
  final startIsWhite = line.startPosition.turn == Side.white;
  final parts = <String>[];
  for (int i = start; i < stop; i++) {
    final isWhite = startIsWhite ? i.isEven : i.isOdd;
    final number = startIsWhite
        ? startFullmoves + i ~/ 2
        : startFullmoves + (i + 1) ~/ 2;
    if (isWhite) {
      parts.add('$number.${line.moves[i]}');
    } else if (parts.isEmpty) {
      parts.add('$number...${line.moves[i]}');
    } else {
      parts.add(line.moves[i]);
    }
  }
  return parts.join(' ');
}

/// Training-aware lines browser with Learn/Review action buttons and
/// lines grouped into Due / New / Learned sections.
class TrainingLinesPanel extends StatefulWidget {
  final List<RepertoireLine> lines;
  final Map<String, RepertoireReviewEntry> reviewMap;
  final Map<String, RepertoireMoveProgress> moveProgressMap;
  final Map<String, double> playabilityMap;
  final Map<String, ({int ply, double quality, bool isOurMove})> bottleneckMap;
  final bool needsScoring;

  /// Whether the uncommented intro auto-plays (dims those moves in the
  /// preview and excludes them from mastery).
  final bool introEnabled;
  final void Function(RepertoireLine line) onLineSelected;
  final VoidCallback onStartNextNew;
  final VoidCallback onStartNextDue;
  final VoidCallback? onScoreInBuilder;

  /// Opens the read-only preview (board + annotated movetext) for a line.
  final void Function(RepertoireLine line)? onPreviewLine;

  /// Applies the "Select learned lines" checkbox pass over the visible
  /// lines (scope): checked lines become learned, unchecked ones return to
  /// new. Lines outside the scope are untouched.
  final Future<void> Function(Set<String> checkedLineIds, Set<String> scope)?
  onApplyLearnedSelection;

  /// Distinct chapters of the loaded source, file order. Empty = no chapter
  /// UI at all (files without chapters keep the plain list).
  final List<String> chapters;

  /// Currently selected chapter filter (null = all chapters).
  final String? activeChapter;
  final void Function(String? chapter)? onChapterSelected;

  /// Resolves a line's chapter under the current grouping setting; used for
  /// filtering and for the chapter label on rows in the all-chapters view.
  final String? Function(RepertoireLine line)? chapterOf;

  const TrainingLinesPanel({
    super.key,
    required this.lines,
    required this.reviewMap,
    required this.moveProgressMap,
    this.playabilityMap = const {},
    this.bottleneckMap = const {},
    this.needsScoring = false,
    this.introEnabled = false,
    required this.onLineSelected,
    required this.onStartNextNew,
    required this.onStartNextDue,
    this.onScoreInBuilder,
    this.onPreviewLine,
    this.onApplyLearnedSelection,
    this.chapters = const [],
    this.activeChapter,
    this.onChapterSelected,
    this.chapterOf,
  });

  @override
  State<TrainingLinesPanel> createState() => _TrainingLinesPanelState();
}

class _TrainingLinesPanelState extends State<TrainingLinesPanel> {
  LineSortMode _sortMode = LineSortMode.smart;

  /// True while the deliberate "Select learned lines" pass is active. The
  /// checkboxes exist only in this mode — there is no always-on toggle to
  /// flip a line's learned state by accident.
  bool _selecting = false;
  bool _savingSelection = false;
  final Set<String> _checked = {};

  /// Lines under the active chapter filter — what every section, count and
  /// selection pass operates on.
  List<RepertoireLine> get _visibleLines {
    final chapter = widget.activeChapter;
    final resolve = widget.chapterOf;
    if (chapter == null || resolve == null) return widget.lines;
    return [
      for (final line in widget.lines)
        if (resolve(line) == chapter) line,
    ];
  }

  void _enterSelection() {
    setState(() {
      _selecting = true;
      _savingSelection = false;
      _checked
        ..clear()
        ..addAll([
          for (final line in _visibleLines)
            if (widget.reviewMap[line.id] != null &&
                !widget.reviewMap[line.id]!.isNew)
              line.id,
        ]);
    });
  }

  void _toggleChecked(String lineId) {
    setState(() {
      if (!_checked.remove(lineId)) _checked.add(lineId);
    });
  }

  Future<void> _saveSelection() async {
    final apply = widget.onApplyLearnedSelection;
    if (apply == null) return;
    setState(() => _savingSelection = true);
    await apply(Set.of(_checked), {for (final line in _visibleLines) line.id});
    if (mounted) {
      setState(() {
        _selecting = false;
        _savingSelection = false;
      });
    }
  }

  /// Highest cumulative probability first; lines without a value sort last.
  int _byProbability(RepertoireLine a, RepertoireLine b) {
    final ai = a.importance;
    final bi = b.importance;
    if (ai == null && bi == null) return 0;
    if (ai == null) return 1;
    if (bi == null) return -1;
    return bi.compareTo(ai);
  }

  /// Hardest to play first (lowest playability); unscored lines sort last.
  int _byEase(RepertoireLine a, RepertoireLine b) {
    final pa = widget.playabilityMap[a.id];
    final pb = widget.playabilityMap[b.id];
    if (pa == null && pb == null) return 0;
    if (pa == null) return 1;
    if (pb == null) return -1;
    return pa.compareTo(pb);
  }

  @override
  Widget build(BuildContext context) {
    final reviewMap = widget.reviewMap;
    final newLines = <RepertoireLine>[];
    final dueLines = <RepertoireLine>[];
    final learnedLines = <RepertoireLine>[];

    for (final line in _visibleLines) {
      final entry = reviewMap[line.id];
      if (entry == null || entry.isNew) {
        newLines.add(line);
      } else if (entry.isDue) {
        dueLines.add(line);
      } else {
        learnedLines.add(line);
      }
    }

    switch (_sortMode) {
      case LineSortMode.smart:
        dueLines.sort((a, b) {
          final ea = reviewMap[a.id]!;
          final eb = reviewMap[b.id]!;
          final ratioA = ea.passCount + ea.failCount > 0
              ? ea.failCount / (ea.passCount + ea.failCount)
              : 0.0;
          final ratioB = eb.passCount + eb.failCount > 0
              ? eb.failCount / (eb.passCount + eb.failCount)
              : 0.0;
          final cmp = ratioB.compareTo(ratioA);
          if (cmp != 0) return cmp;
          final aDate = ea.lastReviewedUtc ?? DateTime(2000);
          final bDate = eb.lastReviewedUtc ?? DateTime(2000);
          return aDate.compareTo(bDate);
        });
        learnedLines.sort((a, b) {
          final ea = reviewMap[a.id]!;
          final eb = reviewMap[b.id]!;
          final aDate = ea.dueDateUtc ?? DateTime(2100);
          final bDate = eb.dueDateUtc ?? DateTime(2100);
          return aDate.compareTo(bDate);
        });
      case LineSortMode.probability:
        newLines.sort(_byProbability);
        dueLines.sort(_byProbability);
        learnedLines.sort(_byProbability);
      case LineSortMode.ease:
        newLines.sort(_byEase);
        dueLines.sort(_byEase);
        learnedLines.sort(_byEase);
    }

    return Column(
      children: [
        if (widget.chapters.isNotEmpty)
          _ChapterControl(
            chapters: widget.chapters,
            value: widget.activeChapter,
            // Locked during a learned-lines pass: switching chapters would
            // re-scope the list after the checkboxes were initialized, and
            // saving could unlearn lines that were never on screen.
            onChanged: _selecting ? null : widget.onChapterSelected,
          ),
        if (_selecting)
          _SelectionBar(
            checkedCount: _checked.length,
            saving: _savingSelection,
            onSave: _saveSelection,
            onCancel: _savingSelection
                ? null
                : () => setState(() => _selecting = false),
          )
        else
          _ActionBar(
            newCount: newLines.length,
            dueCount: dueLines.length,
            onLearn: newLines.isNotEmpty ? widget.onStartNextNew : null,
            onReview: dueLines.isNotEmpty ? widget.onStartNextDue : null,
          ),
        Row(
          children: [
            Expanded(
              child: _SortControl(
                value: _sortMode,
                onChanged: (mode) => setState(() => _sortMode = mode),
              ),
            ),
            if (!_selecting && widget.onApplyLearnedSelection != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Tooltip(
                  message:
                      'Check off lines you already know (e.g. learned in '
                      'another tool) so they start on the review schedule '
                      'instead of as new.',
                  waitDuration: const Duration(milliseconds: 400),
                  child: TextButton.icon(
                    onPressed: _enterSelection,
                    icon: const Icon(Icons.checklist, size: 16),
                    label: const Text('Select learned lines'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (widget.needsScoring)
          _NeedsScoringBanner(onScoreInBuilder: widget.onScoreInBuilder),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              if (dueLines.isNotEmpty) ...[
                _SectionHeader(
                  title: 'Due for Review',
                  count: dueLines.length,
                  color: AppColors.srsDue,
                ),
                for (final line in dueLines)
                  _LineRow(
                    line: line,
                    entry: reviewMap[line.id],
                    moveProgressMap: widget.moveProgressMap,
                    playability: widget.playabilityMap[line.id],
                    bottleneck: widget.bottleneckMap[line.id],
                    introEnabled: widget.introEnabled,
                    chapterLabel: widget.activeChapter == null
                        ? widget.chapterOf?.call(line)
                        : null,
                    selecting: _selecting,
                    checked: _checked.contains(line.id),
                    onPreview: !_selecting && widget.onPreviewLine != null
                        ? () => widget.onPreviewLine!(line)
                        : null,
                    onTap: _selecting
                        ? () => _toggleChecked(line.id)
                        : () => widget.onLineSelected(line),
                  ),
                const SizedBox(height: 8),
              ],
              if (newLines.isNotEmpty) ...[
                _SectionHeader(
                  title: 'New',
                  count: newLines.length,
                  color: AppColors.srsNew,
                ),
                for (final line in newLines)
                  _LineRow(
                    line: line,
                    entry: reviewMap[line.id],
                    moveProgressMap: widget.moveProgressMap,
                    playability: widget.playabilityMap[line.id],
                    bottleneck: widget.bottleneckMap[line.id],
                    introEnabled: widget.introEnabled,
                    chapterLabel: widget.activeChapter == null
                        ? widget.chapterOf?.call(line)
                        : null,
                    selecting: _selecting,
                    checked: _checked.contains(line.id),
                    onPreview: !_selecting && widget.onPreviewLine != null
                        ? () => widget.onPreviewLine!(line)
                        : null,
                    onTap: _selecting
                        ? () => _toggleChecked(line.id)
                        : () => widget.onLineSelected(line),
                  ),
                const SizedBox(height: 8),
              ],
              if (learnedLines.isNotEmpty) ...[
                _CollapsibleSection(
                  title: 'Learned',
                  count: learnedLines.length,
                  color: AppColors.srsLearned,
                  children: [
                    for (final line in learnedLines)
                      _LineRow(
                        line: line,
                        entry: reviewMap[line.id],
                        moveProgressMap: widget.moveProgressMap,
                        playability: widget.playabilityMap[line.id],
                        bottleneck: widget.bottleneckMap[line.id],
                        introEnabled: widget.introEnabled,
                        chapterLabel: widget.activeChapter == null
                            ? widget.chapterOf?.call(line)
                            : null,
                        selecting: _selecting,
                        checked: _checked.contains(line.id),
                        onPreview: !_selecting && widget.onPreviewLine != null
                            ? () => widget.onPreviewLine!(line)
                            : null,
                        onTap: _selecting
                            ? () => _toggleChecked(line.id)
                            : () => widget.onLineSelected(line),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
