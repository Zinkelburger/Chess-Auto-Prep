import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../chess/pgn/comment_text.dart';
import '../../chess/pgn/move_label.dart';
import '../../chess/training/drill.dart';
import '../../chess/training/schedule.dart';
import '../../ui/app_action.dart';
import '../../ui/app_keys.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import '../../workspace/move_field.dart';
import 'lesson.dart';
import 'trainer.dart';
import 'trainer_words.dart';
import '../../ui/move_notation.dart';

/// The Train tab while a sitting runs: the line and how far the sitting has
/// to go, what the lesson wants now, the moves played so far with the note
/// on the last, the one control the moment needs, and the way out.
///
/// Keys: Space goes on, 1–4 rate, ↓ skips the line, Escape leaves — and
/// a move typed while one is asked for goes into the move field under the
/// board by itself, which plays it on the lesson's board.
class LessonView extends StatefulWidget {
  const LessonView({
    super.key,
    required this.lesson,
    required this.trainer,
    required this.moves,
    required this.onRead,
  });

  final Lesson lesson;
  final Trainer trainer;
  final ValueChanged<LineToRead> onRead;

  /// The move field under the board.
  final MoveEntry moves;

  @override
  State<LessonView> createState() => _LessonViewState();
}

class _LessonViewState extends State<LessonView> {
  final _focus = FocusNode(debugLabel: 'lesson');

  /// The line whose moves and notes are being read instead of the moves so
  /// far. Another line coming up ends the peek, so it never spoils the next.
  LineKey? _peeking;

  void _peek(bool on) {
    if (!mounted) return;
    setState(() => _peeking = on ? widget.lesson.line.key : null);
  }

  @override
  void initState() {
    super.initState();
    widget.lesson.addListener(_lessonChanged);
    // The keys are the lesson's from the start. Autofocus would leave them
    // with the workspace, which holds the focus already.
    _focus.requestFocus();
  }

  @override
  void didUpdateWidget(LessonView old) {
    super.didUpdateWidget(old);
    if (old.lesson == widget.lesson) return;
    old.lesson.removeListener(_lessonChanged);
    widget.lesson.addListener(_lessonChanged);
    // A new sitting over this one, from the recap's buttons, takes the keys
    // too, wherever the focus went meanwhile.
    _focus.requestFocus();
  }

  @override
  void dispose() {
    widget.lesson.removeListener(_lessonChanged);
    _focus.dispose();
    super.dispose();
  }

  /// Once the lesson stops asking, the keys go back to it: Space, the
  /// ratings and ↓ are the lesson's, not letters of a move.
  void _lessonChanged() {
    if (!mounted || askingFor(widget.lesson)) return;
    if (widget.moves.focus.hasFocus) _focus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final lesson = widget.lesson;
    if (askingFor(lesson) && _typeInField(event)) {
      return KeyEventResult.handled;
    }
    final rating = AppKey.rate.keys.indexWhere(
      (key) => key.accepts(event, HardwareKeyboard.instance),
    );
    if (rating >= 0) {
      lesson.rate(Rating.values[rating]);
    } else if (AppKey.nextStep.accepts(event)) {
      lesson.proceed();
    } else if (AppKey.skipLine.accepts(event)) {
      lesson.skip();
    } else if (AppKey.leaveLesson.accepts(event)) {
      widget.trainer.leave();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// A letter a move is written with goes to the move field, typed, so a
  /// move can be typed without going there first.
  bool _typeInField(KeyEvent event) {
    final character = event.character;
    final keys = HardwareKeyboard.instance;
    if (character == null ||
        !_moveLetter.hasMatch(character) ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isMetaPressed) {
      return false;
    }
    widget.moves.type(character);
    return true;
  }

  static final _moveLetter = RegExp(r'^[a-hA-HKkQqRrNnOo0-8x=-]$');

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _focus.requestFocus,
        child: ListenableBuilder(
          listenable: widget.lesson,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(
              readingCardInset,
              Space.m,
              readingCardInset,
              Space.s,
            ),
            child: widget.lesson.state is SittingOver
                ? _Over(lesson: widget.lesson, trainer: widget.trainer)
                : _OnLine(
                    lesson: widget.lesson,
                    trainer: widget.trainer,
                    onRead: widget.onRead,
                    peeking: _peeking == widget.lesson.line.key,
                    onPeek: _peek,
                  ),
          ),
        ),
      ),
    );
  }
}

class _OnLine extends StatelessWidget {
  const _OnLine({
    required this.lesson,
    required this.trainer,
    required this.onRead,
    required this.peeking,
    required this.onPeek,
  });

  final Lesson lesson;
  final Trainer trainer;
  final ValueChanged<LineToRead> onRead;

  /// Whether the whole line and its notes show instead of the moves so far.
  final bool peeking;
  final ValueChanged<bool> onPeek;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final drill = lesson.drill;
    final wrong = drill.stage is Missed || drill.stage is Corrected;
    final openInBuilder = Tooltip(
      message: 'End this sitting and inspect the shown position',
      child: TextButton(
        onPressed: trainer.lessonToRead == null ? null : _read,
        child: const Text('Open in Builder'),
      ),
    );
    final moves = peeking
        ? _LinePeek(drill: drill, onClose: () => onPeek(false))
        : _MovesSoFar(drill: drill);
    // One layout at every size: the heading, the prompt, the control and
    // the way out keep their places and the moves take the height left.
    // A short pane, such as the half of the card a second pane leaves,
    // tightens the gaps; one too short for even a line of moves scrolls
    // whole rather than spilling past its edge.
    return LayoutBuilder(
      builder: (context, room) {
        final short = room.maxHeight < _roomyHeight;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: room.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: _Heading(lesson: lesson)),
                      openInBuilder,
                    ],
                  ),
                  SizedBox(height: short ? Space.s : Space.l),
                  Text(
                    displaySan(context, prompt(lesson)),
                    style: text.titleLarge?.copyWith(
                      color: wrong ? Theme.of(context).colorScheme.error : null,
                    ),
                  ),
                  SizedBox(height: short ? Space.xs : Space.m),
                  Expanded(child: _Squeezable(child: moves)),
                  for (final (failure, doing) in [
                    (lesson.unlogged, 'save that answer'),
                    (lesson.notExcluded, 'exclude that line'),
                  ])
                    if (failure != null)
                      Text(
                        progressProblem(failure, doing: doing),
                        style: text.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  const SizedBox(height: Space.s),
                  _Control(lesson: lesson, short: short),
                  Divider(height: short ? Space.s : Space.l),
                  _Footer(
                    lesson: lesson,
                    trainer: trainer,
                    onPeek: peeking ? null : () => onPeek(true),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The height under which the gaps tighten and the ratings lose their
  /// question: about half the card at the default window.
  static const _roomyHeight = 360.0;

  void _read() {
    if (trainer.lesson != lesson) return;
    final target = trainer.lessonToRead;
    if (target == null) return;
    trainer.leave();
    onRead(target);
  }
}

/// [child] counted as one line high when the lesson works out how tall it
/// must be: the moves take what the rest leaves and scroll in it, so they
/// never push the control or the way out off the pane.
class _Squeezable extends SingleChildRenderObjectWidget {
  const _Squeezable({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSqueezable();
}

class _RenderSqueezable extends RenderProxyBox {
  static const _line = Space.xl;

  @override
  double computeMinIntrinsicHeight(double width) => _line;

  @override
  double computeMaxIntrinsicHeight(double width) => _line;

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;
}

/// The line, its chapter, and how far the sitting has to go.
class _Heading extends StatelessWidget {
  const _Heading({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = lesson.line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line.name,
          style: text.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          '${line.chapter} · ${lesson.learning ? 'Learning' : 'Reviewing'}'
          '${lesson.left > 0 ? ' · ${lesson.left} more after this' : ''}',
          style: text.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// The moves on the board, and the note on the last of them: nothing from
/// further down the line, which is what is being asked.
class _MovesSoFar extends StatelessWidget {
  const _MovesSoFar({required this.drill});

  final Drill drill;

  @override
  Widget build(BuildContext context) {
    final moves = drill.line.moves;
    final note = drill.shown == 0
        ? null
        : displayComment(moves[drill.shown - 1].comment ?? '');
    // Anchored at the end: in a short pane the move just played and its
    // note are what stays in view, the first moves scroll off the top.
    return LayoutBuilder(
      builder: (context, room) => SingleChildScrollView(
        reverse: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: room.maxHeight),
          child: Align(
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displaySan(context, numberedMoves(moves.take(drill.shown))),
                  style: monoText,
                ),
                if (note != null && note.isNotEmpty) ...[
                  const SizedBox(height: Space.s),
                  Text(note, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The whole line with its notes, read-only: the old app's PGN peek. It
/// gives the answers away, so it is only there when asked for, and the
/// move on the board is marked so the reader can find the place again.
class _LinePeek extends StatelessWidget {
  const _LinePeek({required this.drill, required this.onClose});

  final Drill drill;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final moves = drill.line.moves;
    final spans = <InlineSpan>[];
    for (final (ply, move) in moves.indexed) {
      final label = moveNumberLabel(
        move,
        startsLine: ply == 0 || _afterNote(ply),
      );
      spans.add(
        TextSpan(
          text: '${spans.isEmpty ? '' : ' '}$label${move.san}',
          style: ply == drill.shown - 1
              ? monoText.copyWith(fontWeight: FontWeight.w700)
              : monoText,
        ),
      );
      final note = displayComment(move.comment ?? '');
      if (note.isNotEmpty) {
        spans.add(TextSpan(text: ' $note', style: text.bodyMedium));
      }
    }
    // Its label scrolls with it, so a pane only a few lines high still
    // shows the line rather than the label alone.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Moves and notes', style: text.labelSmall)),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onClose,
                child: const Text('Hide'),
              ),
            ],
          ),
          SelectableText.rich(TextSpan(children: spans)),
        ],
      ),
    );
  }

  /// Whether a note stands before the move at [ply], so a Black move is
  /// numbered again after it, as a book prints `5.Nf3 {…} 5...Nc6`.
  bool _afterNote(int ply) =>
      displayComment(drill.line.moves[ply - 1].comment ?? '').isNotEmpty;
}

/// The one control the moment needs: Next while a move is being shown, the
/// ratings when a review is done, the retry when its rating did not save.
class _Control extends StatelessWidget {
  const _Control({required this.lesson, required this.short});

  final Lesson lesson;

  /// Whether the pane is short: the ratings go without their question.
  final bool short;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return switch (lesson.state) {
      Drilling() when lesson.drill.stage is Showing => Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: AppKey.nextStep.tip('Next'),
          child: FilledButton(
            onPressed: lesson.next,
            child: const Text('Next'),
          ),
        ),
      ),
      AwaitingRating(:final graded) => _Ratings(
        lesson: lesson,
        graded: graded,
        asked: !short,
      ),
      SavingLine() => Text('Saving…', style: text.bodySmall),
      LineNotSaved(:final failure) => Row(
        children: [
          Expanded(
            child: Text(
              progressProblem(failure, doing: 'save the rating'),
              style: text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          TextButton(onPressed: lesson.retry, child: const Text('Retry')),
        ],
      ),
      _ => const SizedBox(height: Space.xl),
    };
  }
}

/// How well the user knew the line, each button saying what it schedules.
/// The grade the line's mistakes earned is the filled one, and Space takes
/// it.
class _Ratings extends StatelessWidget {
  const _Ratings({
    required this.lesson,
    required this.graded,
    required this.asked,
  });

  final Lesson lesson;
  final Rating graded;

  /// Whether the question stands over the buttons, where there is room.
  final bool asked;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (asked) ...[
        Text(
          'How well did you know this?',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: Space.s),
      ],
      Wrap(
        spacing: Space.s,
        runSpacing: Space.s,
        children: [
          for (final (i, rating) in Rating.values.indexed)
            Tooltip(
              message: withKey(
                ratingLabel(rating, lesson.review),
                [
                  keyName(AppKey.rate.keys[i]),
                  if (rating == graded) AppKey.nextStep.label,
                ].join(', '),
              ),
              child: rating == graded
                  ? FilledButton(
                      onPressed: () => lesson.rate(rating),
                      child: Text(ratingLabel(rating, lesson.review)),
                    )
                  : OutlinedButton(
                      onPressed: () => lesson.rate(rating),
                      child: Text(ratingLabel(rating, lesson.review)),
                    ),
            ),
        ],
      ),
    ],
  );
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.lesson,
    required this.trainer,
    required this.onPeek,
  });

  final Lesson lesson;
  final Trainer trainer;

  /// Shows the whole line and its notes; null while they show.
  final VoidCallback? onPeek;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // A narrow pane wraps these rather than cutting them off.
      Expanded(
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: AppKey.skipLine.tip('Skip this line'),
              child: TextButton(
                onPressed: lesson.skip,
                child: const Text('Skip'),
              ),
            ),
            TextButton(
              onPressed: lesson.restart,
              child: const Text('Restart line'),
            ),
            RowActions(
              tooltip: 'Line actions',
              children: [
                MenuItemButton(
                  onPressed: onPeek,
                  child: const Text('View moves and notes'),
                ),
                MenuItemButton(
                  onPressed: () => unawaited(lesson.exclude()),
                  child: const Text('Exclude from training'),
                ),
              ],
            ),
          ],
        ),
      ),
      Tooltip(
        message: AppKey.leaveLesson.tip('Back to lines'),
        child: TextButton(
          onPressed: trainer.leave,
          child: const Text('Back to lines'),
        ),
      ),
    ],
  );
}

/// The sitting is over: what it came to, and the ways on.
class _Over extends StatelessWidget {
  const _Over({required this.lesson, required this.trainer});

  final Lesson lesson;
  final Trainer trainer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tally = lesson.tally;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sittingOver(lesson.kind), style: text.titleMedium),
          const SizedBox(height: Space.s),
          Text(
            '${tally.lines} ${tally.lines == 1 ? 'line' : 'lines'} · '
            '${tally.right} right · ${tally.wrong} wrong',
            style: text.bodySmall,
          ),
          const SizedBox(height: Space.l),
          Wrap(spacing: Space.s, runSpacing: Space.s, children: _ways()),
        ],
      ),
    );
  }

  List<Widget> _ways() => [
    FilledButton(onPressed: trainer.leave, child: const Text('Back to lines')),
    if (trainer.dueCount > 0)
      OutlinedButton(
        onPressed: trainer.review,
        child: Text('Review ${trainer.dueCount} more'),
      ),
    if (trainer.untrainedCount > 0)
      OutlinedButton(
        onPressed: trainer.learn,
        child: Text('Learn more · ${trainer.untrainedCount} left'),
      ),
  ];
}

/// Whether [lesson] is waiting for the user's move.
bool askingFor(Lesson lesson) =>
    lesson.state is Drilling && lesson.drill.stage is Asking;
