import '../chess/generation/evaluation_source.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/generation/draft_lines.dart' show expectimaxText;
import '../chess/generation/eval.dart';
import '../chess/generation/search_node.dart';
import '../engines/engine_line.dart' show Centipawns;
import '../storage/chapter_files.dart';
import '../storage/settings.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'finds.dart';
import 'line_preview.dart';

/// The Expectimax panel: the expectimax search from the
/// board and its values.
///
/// Editable search settings and the play/stop action head the panel. Under them, for the position on
/// the board, every move the search looked at with what it is worth
/// against the modelled opponent (Expectimax) and what the engine alone
/// says (Engine), both from White's side. At the opponent's move each reply
/// also says how often it is played, and a reply that throws away half a
/// pawn or more against their best is marked `?`: a trap. The table follows
/// the board and fills in while the search runs. Clicking a row plays the
/// move; resting on it floats the position after it.
///
/// A search on a repertoire chapter can then be turned into lines, written
/// into a draft chapter beside it; nothing is written until asked.
class SearchPane extends StatefulWidget {
  const SearchPane({
    super.key,
    required this.fill,
    required this.session,
    required this.settings,
    this.onOpenChapter,
  });

  final FillGaps fill;
  final DocumentSession session;

  /// Where the opponent's rating and the cover rule are kept: the Replies
  /// tab reads the same two numbers.
  final SettingsStore settings;

  /// Opens the draft the lines were written to.
  final ValueChanged<ChapterRef>? onOpenChapter;

  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane>
    with ListeningState<SearchPane> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;
  late final _elo = TextEditingController(
    text: '${widget.settings.value.opponentElo}',
  );
  late final _depth = TextEditingController(
    text: widget.fill.depth?.toString() ?? '',
  );
  late final _candidates = TextEditingController(
    text: '${widget.fill.candidateMoves}',
  );
  late final _cover = TextEditingController(
    text: widget.fill.replyFloor == 0
        ? '0'
        : '${(1 / widget.fill.replyFloor).round()}',
  );

  /// Why the last press of Search did nothing: a number out of range or a
  /// refusal. Cleared by the next press.
  String? _problem;

  /// The run and the position the rows are for.
  (FillTarget?, Fen)? _rowsFor;

  (FillTarget?, Fen) get _rowsNow =>
      (widget.fill.found?.target, widget.session.fen);

  @override
  void initState() {
    super.initState();
    _rowsFor = _rowsNow;
  }

  /// Merged anew each time the pane is rebuilt from above, so [changed]
  /// runs once more then; it compares, so that costs nothing.
  @override
  Listenable listenableOf(SearchPane widget) =>
      Listenable.merge([widget.fill, widget.session.anyChange]);

  /// A row that goes takes the pointer's exit with it, so the floated board
  /// goes with the rows: at another position, or when another run starts.
  /// The values filling in as the run goes keep it.
  @override
  void changed() {
    final rowsFor = _rowsNow;
    if (rowsFor == _rowsFor) return;
    _rowsFor = rowsFor;
    _leave();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    _elo.dispose();
    _depth.dispose();
    _candidates.dispose();
    _cover.dispose();
    super.dispose();
  }

  FillRequest get _request => FillRequest(
    elo: widget.settings.value.opponentElo,
    depthPlies: widget.fill.depth,
    source: widget.fill.source,
    candidateMoves: widget.fill.candidateMoves,
    replyFloor: widget.fill.replyFloor,
  );

  Future<bool> _applySettings() async {
    final elo = int.tryParse(_elo.text.trim());
    final depthText = _depth.text.trim();
    final depth = int.tryParse(depthText);
    final candidates = int.tryParse(_candidates.text.trim());
    final cover = int.tryParse(_cover.text.trim());
    final problem =
        elo == null || elo < Settings.minElo || elo > Settings.maxElo
        ? 'Maia rating: ${Settings.minElo} to ${Settings.maxElo}'
        : depthText.isNotEmpty &&
              (depth == null || depth < minFillDepth || depth > maxFillDepth)
        ? 'Depth: $minFillDepth to $maxFillDepth, or empty for no limit'
        : candidates == null || candidates < 1 || candidates > 218
        ? 'Candidates: 1 to 218'
        : cover == null || cover < 0 || cover == 1
        ? 'Reply coverage: 2 or more games, or 0 for every reply'
        : null;
    if (!mounted) return false;
    setState(() => _problem = problem);
    if (problem != null) return false;
    widget.fill.depth = depth;
    widget.fill.candidateMoves = candidates!;
    widget.fill.replyFloor = cover == 0 ? 0 : 1 / cover!;
    await widget.settings.update(
      widget.settings.value.copyWith(opponentElo: elo!),
    );
    return mounted;
  }

  Future<void> _search({bool resume = false}) async {
    if (!await _applySettings()) return;
    final request = _request;
    final refusal = resume
        ? await widget.fill.resume(request)
        : await widget.fill.start(request);
    if (!mounted || refusal == null) return;
    setState(() => _problem = refusal);
  }

  void _hover(SearchNode after, String uci, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      _preview.value = LinePreview(
        fen: after.fen,
        lastMove: uci,
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _preview.value = null;
  }

  void _play(String uci) {
    _leave();
    unawaited(
      widget.fill.followMove(uci).then((problem) {
        if (!mounted || problem == null) return;
        setState(() => _problem = problem);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.fill,
        widget.session.anyChange,
        ?widget.fill.finds,
      ]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: LayoutBuilder(
          builder: (context, size) => SingleChildScrollView(
            child: SizedBox(
              height: math.max(
                size.maxHeight,
                widget.fill.treeSaveProblem == null
                    ? searchPaneMinHeight
                    : searchRecoveryMinHeight,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _form(context),
                  Tooltip(
                    message:
                        'Engine evaluation target, separate from Expectimax search depth. '
                        'Cached scores may be deeper; database scores and proven mates may differ. '
                        'Hover an Engine value for its recorded depth.',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.m),
                      child: Text(
                        'Engine target: depth $fillEvalDepth',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  _status(context),
                  const Divider(height: 1),
                  Expanded(child: _table(context)),
                  if (widget.fill.treeSaveProblem != null)
                    Padding(
                      padding: const EdgeInsets.all(Space.m),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.fill.treeSaveProblem!),
                          Wrap(
                            spacing: Space.s,
                            children: [
                              OutlinedButton(
                                onPressed: () =>
                                    unawaited(widget.fill.retryTree()),
                                child: const Text('Retry saving tree'),
                              ),
                              TextButton(
                                onPressed: widget.fill.discardTreeSave,
                                child: const Text('Discard tree save'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ?_linesRow(context),
                  if (widget.fill.canDiscardDraft)
                    TextButton(
                      onPressed: widget.fill.discardDraftSave,
                      child: const Text('Discard draft save'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _settingsFields() => [
    _NumberBox(
      label: 'Maia rating',
      box: _elo,
      width: searchEloWidth,
      enabled: !widget.fill.running,
      onSubmitted: () => unawaited(_applySettings()),
      onChanged: () => unawaited(_applySettings()),
    ),
    Tooltip(
      message:
          'Our best engine candidates from ply 2 onward. All legal moves are considered near the root.',
      child: _NumberBox(
        label: 'Candidates',
        box: _candidates,
        width: searchEloWidth,
        enabled: !widget.fill.running,
        onSubmitted: () => unawaited(_applySettings()),
        onChanged: () => unawaited(_applySettings()),
      ),
    ),
    Tooltip(
      message:
          'Search depth in half-moves from the current board. Empty means no depth limit.',
      child: _NumberBox(
        label: 'Depth',
        box: _depth,
        width: searchDepthWidth,
        hint: 'No limit',
        enabled: !widget.fill.running,
        onSubmitted: () => unawaited(_applySettings()),
        onChanged: () => unawaited(_applySettings()),
      ),
    ),
    Tooltip(
      message:
          'Expand reply paths met at least once in this many games. Rarer replies keep their engine value. 0 expands every reply.',
      child: _NumberBox(
        label: '1 in N games',
        box: _cover,
        width: searchEloWidth,
        enabled: !widget.fill.running,
        onSubmitted: () => unawaited(_applySettings()),
        onChanged: () => unawaited(_applySettings()),
      ),
    ),
    PopupMenuButton<EvaluationSource>(
      tooltip: 'Evaluation source',
      enabled: !widget.fill.running,
      initialValue: widget.fill.source,
      onSelected: (source) {
        if (mounted) setState(() => widget.fill.source = source);
      },
      itemBuilder: (_) => [
        for (final source in EvaluationSource.values)
          PopupMenuItem(value: source, child: Text(source.label)),
      ],
      child: Padding(
        padding: const EdgeInsets.all(Space.s),
        child: Text(widget.fill.source.label),
      ),
    ),
  ];

  Widget _form(BuildContext context) {
    final fill = widget.fill;
    final state = fill.state;
    final running = state is FillRunning ? state : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.s),
      child: Wrap(
        spacing: Space.s,
        runSpacing: Space.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ..._settingsFields(),
          if (running == null) ...[
            Tooltip(
              message:
                  'Continue a search from this board, including a saved search',
              child: IconButton(
                icon: const Icon(Icons.playlist_play),
                onPressed: fill.canStart
                    ? () => unawaited(_search(resume: true))
                    : null,
              ),
            ),
            Tooltip(
              message: withKey(
                'Search from the board (pauses after $fillNodeBudget new positions)',
                'Ctrl+G',
              ),
              child: FilledButton.icon(
                onPressed: fill.canStart ? () => unawaited(_search()) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Expectimax'),
              ),
            ),
          ] else ...[
            // A search with a depth ends there by itself.
            if (running.of == null) ...[
              Tooltip(
                message:
                    'Score every position at this depth, then stop and '
                    'keep the tree',
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.pause),
                  onPressed: running.stopping || running.lastPly != null
                      ? null
                      : fill.finishLevel,
                  label: Text(
                    'Stop after finishing depth '
                    '${running.lastPly ?? (running.depth < 1 ? 1 : running.depth)}',
                  ),
                ),
              ),
              const SizedBox(width: Space.s),
            ],
            Tooltip(
              message:
                  'Finish the current position, then stop and keep the results',
              child: FilledButton.icon(
                icon: const Icon(Icons.pause),
                onPressed: running.stopping ? null : fill.finish,
                label: const Text('Stop'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One quiet line: how far the search has got, what it did, or what
  /// went wrong.
  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final found = widget.fill.found;
    final side = found?.side ?? widget.session.orientation;
    final forSide = 'for ${side == Side.white ? 'White' : 'Black'}';
    final (words, error) = switch (widget.fill.state) {
      _ when _problem != null => (_problem!, true),
      FillIdle() => (
        'All moves near the root; best ${widget.fill.candidateMoves} deeper · $forSide',
        false,
      ),
      FillRunning(
        :final depth,
        :final of,
        :final nodes,
        :final stopping,
        :final lastPly,
      ) =>
        (
          stopping
              ? 'Stopping at depth $depth · $nodes positions'
              : 'Searching $forSide · depth $depth'
                    '${of == null ? '' : ' of $of'} · $nodes positions'
                    '${lastPly == null ? '' : ' · stops after depth $lastPly'}',
          false,
        ),
      FillDone(
        :final depth,
        :final nodes,
        :final complete,
        :final budgetReached,
      ) =>
        (
          '${complete ? 'Searched' : 'Stopped at'} depth $depth $forSide · '
              '$nodes positions · rated ${found?.request.elo ?? ''}'
              '${budgetReached ? ' · position budget reached' : ''}${complete ? '' : ' · Resume to continue'}${_findsWords()}',
          false,
        ),
      FillFailed(:final reason) => (reason, true),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
      child: Text(
        words,
        style: theme.textTheme.bodySmall?.copyWith(
          color: error ? theme.colorScheme.error : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// What the run pointed out, and where to see it.
  String _findsWords() => switch (widget.fill.finds?.recorded) {
    FindsReading() => ' · looking for positions…',
    FindsUnsaved() => ' · search positions not saved',
    FindsKept(:final count) => ' · $count found, listed in Positions (Ctrl+P)',
    null => '',
  };

  Widget _table(BuildContext context) {
    final found = widget.fill.found;
    if (found == null)
      return _sentence(
        context,
        widget.fill.running
            ? 'Evaluating the first moves…'
            : 'Press ▶ Expectimax to evaluate moves from this position.',
      );
    final node = widget.fill.nodeAtBoard(request: found.request);
    return switch (node) {
      null => _offTree(context, found),
      OurNode(:final candidates) => _rows(
        context,
        side: found.side,
        ours: true,
        rows: [
          for (final c in candidates)
            _Row(move: c.move, after: c.child, share: null, trap: false),
        ],
      ),
      OpponentNode(:final replies) => _rows(
        context,
        side: found.side,
        ours: false,
        rows: _replyRows(replies),
      ),
      TerminalNode() => _sentence(context, 'The game is over here.'),
      HorizonNode() || FrontierNode() => _sentence(
        context,
        widget.fill.running
            ? 'Not reached yet.'
            : 'The search stopped before this position.',
      ),
    };
  }

  /// The replies, most played first, each marked when it loses half a pawn
  /// or more against the best of them.
  List<_Row> _replyRows(List<ReplyMove> replies) {
    final best = replies
        .map((r) => r.child.evalForUs.cp)
        .reduce((a, b) => a < b ? a : b);
    final sorted = [...replies]
      ..sort((a, b) => b.probability.compareTo(a.probability));
    return [
      for (final r in sorted)
        _Row(
          move: r.move,
          after: r.child,
          share: r.probability,
          trap: r.child.evalForUs.cp - best >= trapLossCp,
        ),
    ];
  }

  Widget _offTree(BuildContext context, FillFound found) {
    final session = widget.session;
    final tree = session.tree;
    final start = found.target.cursor;
    final canGo =
        tree != null &&
        tree.rootFen == found.target.rootFen &&
        _sameLine([
          for (final move in tree.lineTo(start)) move.san,
        ], found.target.sans);
    return Padding(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No saved results here yet. Start Expectimax from this board.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (canGo) ...[
            const SizedBox(height: Space.s),
            OutlinedButton(
              onPressed: () => session.goTo(start),
              child: const Text('Go to where it started'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sentence(BuildContext context, String words) => Padding(
    padding: const EdgeInsets.all(Space.m),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _rows(
    BuildContext context, {
    required Side side,
    required bool ours,
    required List<_Row> rows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(ours: ours),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return _RowView(
                key: ValueKey(row.move.uci),
                row: row,
                engineDepth: widget.fill.engineDepthAt(row.after.fen),
                side: side,
                ours: ours,
                onHover: (anchor) => _hover(row.after, row.move.uci, anchor),
                onLeave: _leave,
                onTap: () => _play(row.move.uci),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _writtenLines(BuildContext context, LinesWritten lines) {
    final theme = Theme.of(context);
    final open = widget.onOpenChapter;
    final count = lines.lines == 1 ? '1 line' : '${lines.lines} lines';
    return Row(
      children: [
        Expanded(
          child: Text(
            '$count in ${lines.draft.name}',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (open != null)
          OutlinedButton(
            onPressed: () => open(lines.draft),
            child: const Text('Open'),
          ),
      ],
    );
  }

  /// Under a finished search on a repertoire chapter: the way to turn it
  /// into lines, or what became of that.
  Widget? _linesRow(BuildContext context) {
    final fill = widget.fill;
    final theme = Theme.of(context);
    final lines = fill.lines;
    final Widget child;
    if (lines is LinesWritten) {
      child = _writtenLines(context, lines);
    } else if (fill.canMakeLines || lines is LinesWriting) {
      child = Row(
        children: [
          Expanded(
            child: Text(
              lines is LinesFailed
                  ? lines.reason
                  : 'Turn the best moves into lines in a draft chapter.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: lines is LinesFailed ? theme.colorScheme.error : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          OutlinedButton(
            onPressed: fill.canMakeLines
                ? () => unawaited(fill.makeLines())
                : null,
            child: const Text('Make lines'),
          ),
        ],
      );
    } else {
      return null;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.s,
        ),
        child: child,
      ),
    );
  }
}

bool _sameLine(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A reply that loses this much against the opponent's best is a trap.
const trapLossCp = 50;

/// One move of the table: the move, where it leads, how often the opponent
/// plays it (null at our move) and whether it is a trap.
final class _Row {
  const _Row({
    required this.move,
    required this.after,
    required this.share,
    required this.trap,
  });

  final MoveRef move;
  final SearchNode after;
  final double? share;
  final bool trap;
}

/// A labelled number field, narrow enough for several in a row.
class _NumberBox extends StatelessWidget {
  const _NumberBox({
    required this.label,
    required this.box,
    required this.width,
    required this.enabled,
    required this.onSubmitted,
    this.hint,
    this.onChanged,
  });

  final String label;

  /// What an empty box means.
  final String? hint;
  final TextEditingController box;
  final double width;
  final bool enabled;
  final VoidCallback onSubmitted;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: TextField(
      controller: box,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        floatingLabelBehavior: hint == null
            ? null
            : FloatingLabelBehavior.always,
      ),
      onSubmitted: (_) => onSubmitted(),
      onChanged: (_) => onChanged?.call(),
    ),
  );
}

/// The column names over the rows.
class _Header extends StatelessWidget {
  const _Header({required this.ours});

  final bool ours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      height: searchHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Row(
          children: [
            Expanded(
              child: Text(ours ? 'Your move' : 'Their reply', style: style),
            ),
            if (!ours)
              SizedBox(
                width: searchShareWidth,
                child: Text('Played', style: style, textAlign: TextAlign.right),
              ),
            SizedBox(
              width: searchValueWidth,
              child: Text(
                'Expectimax',
                style: style,
                textAlign: TextAlign.right,
              ),
            ),
            SizedBox(
              width: searchValueWidth,
              child: Text('Engine', style: style, textAlign: TextAlign.right),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowView extends StatelessWidget {
  const _RowView({
    super.key,
    required this.row,
    required this.engineDepth,
    required this.side,
    required this.ours,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final _Row row;
  final int? engineDepth;

  /// The side the search played for, whose point of view the values are
  /// kept in; they are shown from White's.
  final Side side;
  final bool ours;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = monoText.copyWith(color: scheme.onSurface);
    final muted = monoText.copyWith(color: scheme.onSurfaceVariant);
    final after = row.after;
    // An unexpanded move is worth only what the engine says; the search's
    // own value is not in yet.
    final searched = after is! FrontierNode;
    final white = side == Side.white;
    final score = after.valuation.value;
    final share = row.share;
    return MouseRegion(
      onEnter: (_) => onHover(_anchor(context)),
      onExit: (_) => onLeave(),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: searchRowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    row.trap ? '${row.move.san}?' : row.move.san,
                    style: ink,
                  ),
                ),
                if (share != null)
                  SizedBox(
                    width: searchShareWidth,
                    child: Text(
                      _percent(share),
                      style: muted,
                      textAlign: TextAlign.right,
                    ),
                  ),
                SizedBox(
                  width: searchValueWidth,
                  child: Text(
                    searched ? expectimaxText(white ? score : 1 - score) : '…',
                    style: searched ? ink : muted,
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: searchValueWidth,
                  child: Tooltip(
                    message: engineDepth == null
                        ? 'Engine depth unavailable for this saved or database result'
                        : 'Engine depth $engineDepth',
                    child: Text(
                      _engineText(after.evalForUs, white: white),
                      style: muted,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The engine's verdict from White's side, as the engine pane writes one;
/// a mate the search found is `#`.
String _engineText(Eval eval, {required bool white}) {
  final cp = white ? eval.cp : -eval.cp;
  if (cp.abs() >= mateSaturationCp) return cp > 0 ? '+#' : '-#';
  return Centipawns(cp).text;
}

String _percent(double share) {
  final percent = (share * 100).round();
  return percent < 1 ? '<1%' : '$percent%';
}
