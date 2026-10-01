import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/generation/draft_lines.dart' show expectimaxText;
import '../chess/generation/eval.dart';
import '../chess/generation/evaluation_source.dart';
import '../chess/generation/expectimax_options.dart';
import '../chess/generation/mainline_book.dart' show MainlineConfig;
import '../chess/generation/search_node.dart';
import '../engines/engine_line.dart' show Centipawns;
import '../storage/chapter_files.dart';
import '../storage/settings_store.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'finds.dart';
import 'line_preview.dart';
import 'search_settings.dart';
import '../ui/app_keys.dart';
import '../ui/move_notation.dart';

/// The Expectimax panel: the expectimax search from the
/// board and its values.
///
/// One bar heads the panel and never moves: the button that starts,
/// pauses and resumes the search, its depth, and the gear that swaps the
/// results for the rest of the settings. Under a one-line status, for the
/// position on the board, every move the search looked at with what it is worth
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

  /// Where the search's settings are kept: the bar, the gear and
  /// Settings ▸ Expectimax all change them here.
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

  /// Whether the gear's settings are shown where the results are.
  bool _settingsOpen = false;

  /// What is typed in a box and cannot be taken; gone once it can.
  String? _invalid;

  /// Why the last press of the button did nothing. Cleared by the next.
  String? _refusal;

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
    super.dispose();
  }

  FillRequest get _request => FillRequest.of(widget.settings.value);

  void _problem(String? invalid) {
    if (!mounted || invalid == _invalid) return;
    setState(() => _invalid = invalid);
  }

  void _toggleSettings() {
    // A box left mid-number puts its setting back before it goes.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _settingsOpen = !_settingsOpen);
  }

  Future<void> _search() async {
    if (_invalid != null) return;
    setState(() => _refusal = null);
    final refusal = await widget.fill.resume(_request, orAfresh: true);
    if (!mounted || refusal == null) return;
    setState(() => _refusal = refusal);
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
        setState(() => _refusal = problem);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.fill,
        widget.session.anyChange,
        widget.settings,
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
                  _bar(context),
                  _status(context),
                  const Divider(height: 1),
                  Expanded(
                    child: _settingsOpen
                        ? SearchSettingsView(
                            settings: widget.settings,
                            locked: widget.fill.running,
                            onProblem: _problem,
                          )
                        : _table(context),
                  ),
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

  ExpectimaxOptions get _options => widget.settings.value.expectimax;

  bool get _book => _options.method == SearchMethod.mainline;

  /// The bar: the one button, the depth and the gear, each where it always
  /// is whatever the search is doing.
  Widget _bar(BuildContext context) {
    final running = widget.fill.running;
    return SizedBox(
      height: searchBarHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
        child: Row(
          children: [
            SizedBox(width: searchRunWidth, child: _runButton()),
            const SizedBox(width: Space.s),
            Tooltip(
              message: _book
                  ? 'Follow the opponent\'s master replies this many '
                        'half-moves from the board; past it every line runs '
                        'on as ChessDB\'s mainline.'
                  : 'Half-moves searched from the board. Empty goes on '
                        'until paused.',
              child: SearchNumberBox(
                name: SearchSettingCopy.depth.$1,
                label: SearchSettingCopy.depth.$1,
                empty: _book
                    ? '${MainlineConfig.defaultBranchPlies}'
                    : 'No limit',
                value: _options.depth,
                min: ExpectimaxOptions.minDepth,
                max: ExpectimaxOptions.maxDepth,
                width: searchDepthWidth,
                enabled: !running,
                onProblem: _problem,
                onChanged: (depth) => unawaited(
                  widget.settings.update(
                    widget.settings.value.copyWith(
                      expectimax: _options.withDepth(depth),
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.settings, size: IconSize.action),
              tooltip: _settingsOpen ? 'Show results' : 'Expectimax settings',
              isSelected: _settingsOpen,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              selectedIcon: Icon(
                Icons.settings,
                size: IconSize.action,
                color: Theme.of(context).colorScheme.primary,
              ),
              onPressed: _toggleSettings,
            ),
          ],
        ),
      ),
    );
  }

  /// Start, Resume or Pause: one button in one place.
  Widget _runButton() {
    final fill = widget.fill;
    final running = switch (fill.state) {
      final FillRunning running => running,
      _ => null,
    };
    if (running != null) {
      return Tooltip(
        message: 'Finish the current position, then pause and keep the results',
        child: FilledButton.icon(
          icon: const Icon(Icons.pause),
          onPressed: running.stopping ? null : fill.finish,
          label: const Text('Pause'),
        ),
      );
    }
    // A search with these settings covers the board: pressing goes on.
    final resumable = switch (fill.nodeAtBoard(request: _request)) {
      OurNode() || OpponentNode() => true,
      _ => false,
    };
    return Tooltip(
      message: AppKey.search.tip(
        resumable
            ? 'Go on from the search at this board'
            : 'Search from the board',
      ),
      child: FilledButton.icon(
        onPressed: fill.canStart ? () => unawaited(_search()) : null,
        icon: const Icon(Icons.play_arrow),
        label: Text(
          resumable
              ? 'Resume'
              : _book
              ? 'Build'
              : 'Expectimax',
        ),
      ),
    );
  }

  /// What the next search will be, for the side it is for.
  String _summary(String forSide) => _book
      ? '$forSide · ChessDB\'s best moves, master replies'
      : '$forSide · Maia ${widget.settings.value.opponentElo} · '
            'best ${_options.rootMoves}, then ${_options.candidateMoves}'
            '${_options.source == EvaluationSource.stockfish ? '' : ' · ${_options.source.label}'}';

  /// One line of fixed height: what will run, how far the search has got,
  /// what it did, or what went wrong. While a search with no depth runs,
  /// the way to let it finish the depth it is on sits at the line's end.
  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final side = widget.fill.found?.side ?? widget.session.orientation;
    final state = widget.fill.state;
    final problem = _invalid ?? _refusal;
    final (words, error) = switch (state) {
      _ when problem != null => (problem, true),
      FillIdle() => (
        _summary(side == Side.white ? 'For White' : 'For Black'),
        false,
      ),
      FillRunning(:final lastPly?, :final nodes, stopping: false) => (
        'Pausing after depth $lastPly · $nodes positions',
        false,
      ),
      FillRunning(:final depth, :final of, :final nodes, :final stopping) => (
        '${stopping ? 'Pausing at depth' : 'Depth'} $depth'
            '${of == null || stopping ? '' : ' of $of'} · $nodes positions',
        false,
      ),
      FillDone(
        :final depth,
        :final nodes,
        :final complete,
        :final sourceLost,
        :final stoppedBy,
      ) =>
        (
          '${complete ? 'Searched' : 'Stopped at'} depth $depth · '
              '$nodes positions'
              '${sourceLost ? ' · ChessDB stopped answering' : ''}'
              '${stoppedBy == null ? '' : ' · $stoppedBy'}${_findsWords()}',
          false,
        ),
      FillFailed(:final reason) => (reason, true),
    };
    return SizedBox(
      height: searchStatusHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                words,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: error ? theme.colorScheme.error : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (state case FillRunning(
              of: null,
              lastPly: null,
              stopping: false,
              :final depth,
            ))
              Tooltip(
                message:
                    'Score every position at this depth, then pause and '
                    'keep the tree',
                child: TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: widget.fill.finishLevel,
                  child: Text('Finish depth ${depth < 1 ? 1 : depth}'),
                ),
              )
            else
              const SizedBox(width: Space.s),
          ],
        ),
      ),
    );
  }

  /// What the run pointed out, and where to see it.
  String _findsWords() => switch (widget.fill.finds?.recorded) {
    FindsReading() => '',
    FindsUnsaved() => ' · search positions not saved',
    FindsKept(count: 0) => '',
    FindsKept(:final count) => ' · $count found (Positions, Ctrl+P)',
    null => '',
  };

  Widget _table(BuildContext context) {
    final found = widget.fill.found;
    if (found == null)
      return _sentence(
        context,
        widget.fill.running
            ? 'Evaluating the first moves…'
            : 'Press ▶ ${_book ? 'Build' : 'Expectimax'} to evaluate moves from this position.',
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
            'No saved results here yet. Start '
            '${_book ? 'Build' : 'Expectimax'} from this board.',
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
                    displaySan(
                      context,
                      row.trap ? '${row.move.san}?' : row.move.san,
                    ),
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
                        ? 'Depth unknown (saved or database result)'
                        : 'Depth $engineDepth',
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
