import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/training/training_line.dart';
import '../../storage/chapter_files.dart';
import '../../ui/choice_field.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'trainer.dart';
import 'training_scope.dart';

/// One repertoire's outline. The general library stays in the builder.
class TrainingOutline extends StatefulWidget {
  const TrainingOutline({
    super.key,
    required this.trainer,
    required this.onRead,
    required this.onImport,
    required this.trailing,
  });
  final Trainer trainer;
  final ValueChanged<LineToRead> onRead;
  final VoidCallback onImport;
  final Widget trailing;

  @override
  State<TrainingOutline> createState() => _TrainingOutlineState();
}

class _TrainingOutlineState extends State<TrainingOutline> {
  final _search = TextEditingController();
  final Set<ChapterRef> _expanded = {};
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.trainer,
    builder: (context, _) {
      final trainer = widget.trainer;
      final selection = trainer.selection;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Training repertoire')),
                    widget.trailing,
                  ],
                ),
                const SizedBox(height: Space.s),
                ChoiceField(
                  text: selection.repertoire?.name ?? '',
                  options: [for (final r in selection.repertoires) r.name],
                  hint: 'Choose a repertoire',
                  onSubmitted: (name) {
                    final next = selection.repertoires
                        .where((r) => r.name == name)
                        .firstOrNull;
                    if (next != null) {
                      _expanded.clear();
                      selection.choose(next);
                    }
                  },
                ),
                const SizedBox(height: Space.m),
                SearchField(
                  controller: _search,
                  hint: 'Find a chapter or line',
                  onChanged: (value) =>
                      setState(() => _query = value.toLowerCase()),
                ),
              ],
            ),
          ),
          Expanded(child: _contents()),
          const Divider(height: 1),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onImport,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import course PGN…'),
            ),
          ),
        ],
      );
    },
  );

  Widget _contents() {
    final trainer = widget.trainer;
    final state = trainer.state;
    if (state is! TrainerReady) {
      return Padding(
        padding: const EdgeInsets.all(Space.m),
        child: Text(
          trainer.selection.root.isEmpty
              ? 'Choose a repertoire above, or import a course.'
              : state is TrainerLoading
              ? 'Loading chapters…'
              : 'No trainable chapters available.',
        ),
      );
    }
    return ListenableBuilder(
      listenable: state.progress,
      builder: (context, _) {
        final chapters = state.chapters
            .where((c) => _matchesChapter(c))
            .toList();
        return ListView(
          children: [
            ListTile(
              dense: true,
              selected: trainer.selection.chapter == null,
              title: const Text('Whole repertoire'),
              subtitle: Text(
                '${state.chapters.length} chapters · ${state.lines.where((l) => !l.modelGame && l.yourMoves > 0).length} lines',
              ),
              onTap: () => trainer.selection.select(),
            ),
            if (chapters.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Space.m),
                child: Text('No chapters or lines match.'),
              ),
            for (final chapter in chapters) _chapter(state, chapter),
          ],
        );
      },
    );
  }

  bool _matchesChapter(ChapterLines c) =>
      _query.isEmpty ||
      c.ref.name.toLowerCase().contains(_query) ||
      c.lines.any(_matchesLine);
  bool _matchesLine(TrainingLine line) =>
      '${line.name} ${line.moves.map((m) => m.san).join(' ')}'
          .toLowerCase()
          .contains(_query);

  Widget _chapter(TrainerReady state, ChapterLines chapter) {
    final selection = widget.trainer.selection;
    final open = _expanded.contains(chapter.ref) || _query.isNotEmpty;
    final paused = selection.chapterPaused(chapter.ref);
    final lines = chapter.lines
        .where((l) => !l.modelGame && l.yourMoves > 0)
        .toList();
    final learned = lines
        .where((l) => !state.progress.reviewOf(l).untrained)
        .length;
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(right: Space.xs),
          selected: selection.chapter == chapter.ref && selection.line == null,
          leading: IconButton(
            tooltip: open ? 'Collapse chapter' : 'Expand chapter',
            icon: Icon(open ? Icons.expand_more : Icons.chevron_right),
            onPressed: () => setState(
              () => open
                  ? _expanded.remove(chapter.ref)
                  : _expanded.add(chapter.ref),
            ),
          ),
          title: Text(
            chapter.ref.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            paused
                ? 'Paused · $learned/${lines.length} learned'
                : '$learned/${lines.length} learned',
          ),
          onTap: () {
            selection.select(chapter: chapter.ref);
            setState(() => _expanded.add(chapter.ref));
          },
          trailing: RowActions(
            tooltip: 'Chapter training actions',
            children: [
              rowAction('Learn this chapter', () {
                selection.select(chapter: chapter.ref);
                widget.trainer.learn();
              }, busy: paused),
              rowAction('Review this chapter', () {
                selection.select(chapter: chapter.ref);
                widget.trainer.review();
              }, busy: paused),
              rowAction(
                paused ? 'Resume chapter training' : 'Pause chapter training',
                () => selection.pauseScope(!paused, chapter: chapter.ref),
                busy: selection.repertoirePaused,
              ),
            ],
          ),
        ),
        if (open)
          for (final line in chapter.lines)
            if (_query.isEmpty ||
                chapter.ref.name.toLowerCase().contains(_query) ||
                _matchesLine(line))
              _line(state, chapter.ref, line),
      ],
    );
  }

  Widget _line(TrainerReady state, ChapterRef chapter, TrainingLine line) {
    final trainer = widget.trainer;
    final selection = trainer.selection;
    final review = state.progress.reviewOf(line);
    final paused = selection.chapterPaused(chapter) || review.excluded;
    final trainable = !line.modelGame && line.yourMoves > 0;
    final checked = selection.choosing
        ? selection.picked.contains(line.key)
        : !review.untrained;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: Space.l, right: Space.xs),
      selected: selection.line == line.key,
      title: Text(line.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        !trainable
            ? 'Read only'
            : paused
            ? 'Paused'
            : review.untrained
            ? 'New'
            : review.dueAt(state.progress.now)
            ? 'Due for review'
            : 'Learned',
      ),
      leading: trainable
          ? Tooltip(
              message: selection.choosing
                  ? 'Select for training'
                  : 'Mark as learned',
              child: Checkbox(
                value: checked,
                onChanged: state.progress.stale
                    ? null
                    : (on) {
                        if (selection.choosing) {
                          selection.pick(line.key, on ?? false);
                        } else {
                          unawaited(
                            trainer.changeProgress(
                              state.progress.mark([line], known: on ?? false),
                            ),
                          );
                        }
                      },
              ),
            )
          : null,
      onTap: () {
        if (selection.choosing) {
          selection.pick(line.key, !selection.picked.contains(line.key));
          return;
        }
        selection.select(chapter: chapter, line: line.key);
        widget.onRead(state.toRead(line, ReadIn.board));
      },
      trailing: _lineActions(state, chapter, line, trainable, paused),
    );
  }

  Widget _lineActions(
    TrainerReady state,
    ChapterRef chapter,
    TrainingLine line,
    bool trainable,
    bool paused,
  ) {
    final trainer = widget.trainer;
    final selection = trainer.selection;
    final review = state.progress.reviewOf(line);
    return RowActions(
      tooltip: 'Line training actions',
      children: [
        if (trainable)
          rowAction(
            review.untrained ? 'Learn this line' : 'Review this line',
            () {
              selection.select(chapter: chapter, line: line.key);
              review.untrained ? trainer.learn() : trainer.review();
            },
            busy: paused || state.progress.stale,
          ),
        rowAction(
          'Read moves and notes',
          () => widget.onRead(state.toRead(line, ReadIn.moves)),
          busy: false,
        ),
        if (trainable)
          rowAction(
            review.excluded ? 'Resume line training' : 'Pause line training',
            () => unawaited(
              trainer.changeProgress(
                state.progress.setExcluded(line, excluded: !review.excluded),
              ),
            ),
            busy: state.progress.stale,
          ),
      ],
    );
  }
}
