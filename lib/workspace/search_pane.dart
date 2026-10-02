import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/generation/evaluation_source.dart';
import '../chess/generation/expectimax_options.dart';
import '../chess/generation/mainline_book.dart' show MainlineConfig;
import '../chess/generation/search_node.dart';
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
import 'search_table.dart';
import '../ui/app_keys.dart';
import '../ui/choice_field.dart';

/// The Expectimax panel: the expectimax search from the
/// board and its values.
///
/// One bar heads the panel and never moves: the button that starts,
/// pauses and resumes the search, its depth, and the gear that swaps the
/// results for the rest of the settings. Under it one line names the side
/// the search prepares, on a button that turns the board to the other, and
/// says what the search is doing.
///
/// Then, for the position on the board, every move the search looked at
/// with what it is worth when White is the prepared side and Black replies
/// as the model predicts (White), what it is worth the other way round
/// (Black), and what the engine alone says (Engine), all from White's side:
/// a move whose value for the other side sits well off the engine's is one
/// the side playing it is expected to go wrong after. Each move the model
/// was asked about also says how often it is played, and a reply that
/// throws away half a pawn or more against their best is marked `?`: a
/// trap. The table follows the board and fills in while the search runs.
/// Clicking a row plays the move; resting on it floats the position after
/// it.
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

  void _hover(Fen after, String uci, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      _preview.value = LinePreview(fen: after, lastMove: uci, anchor: anchor);
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
  Widget _bar(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final replies = _book ? null : _repliesField();
      final fontSize = Theme.of(context).textTheme.labelLarge!.fontSize!;
      final scale = math.max(
        1.0,
        MediaQuery.textScalerOf(context).scale(fontSize) / fontSize,
      );
      final available = size.maxWidth - Space.m - Space.xs;
      final runWidth = math.min(
        searchRunWidth * scale,
        available - kMinInteractiveDimension,
      );
      final depthWidth = searchDepthWidth * scale;
      final repliesWidth = searchRepliesWidth * scale;
      final withDepth =
          runWidth + Space.s + depthWidth + kMinInteractiveDimension;
      // Account for the gear's whole hit target and scaled labels before
      // keeping controls on the bar. Extra fields move to the next row.
      final depthInBar = available >= withDepth;
      final inline = available >= withDepth + Space.s + repliesWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: searchBarHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
              child: Row(
                children: [
                  SizedBox(width: runWidth, child: _runButton()),
                  if (depthInBar) ...[
                    const SizedBox(width: Space.s),
                    _depthBox(width: depthWidth),
                  ],
                  if (inline && replies != null) ...[
                    const SizedBox(width: Space.s),
                    SizedBox(width: repliesWidth, child: replies),
                  ],
                  const Spacer(),
                  _gear(context),
                ],
              ),
            ),
          ),
          if (!depthInBar || (!inline && replies != null))
            SizedBox(
              height: searchRepliesRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.m),
                child: Row(
                  children: [
                    if (!depthInBar) _depthBox(width: depthWidth),
                    if (!depthInBar && replies != null)
                      const SizedBox(width: Space.s),
                    if (!inline && replies != null) Expanded(child: replies),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _depthBox({required double width}) => Tooltip(
    message: _book
        ? 'Follow the opponent\'s master replies this many '
              'half-moves from the board; past it every line runs '
              'on as ChessDB\'s mainline.'
        : 'Half-moves searched from the board. Empty goes on '
              'until paused.',
    child: SearchNumberBox(
      name: SearchSettingCopy.depth.$1,
      label: SearchSettingCopy.depth.$1,
      empty: _book ? '${MainlineConfig.defaultBranchPlies}' : 'No limit',
      value: _options.depth,
      min: ExpectimaxOptions.minDepth,
      max: ExpectimaxOptions.maxDepth,
      width: width,
      enabled: !widget.fill.running,
      onProblem: _problem,
      onChanged: (depth) => unawaited(
        widget.settings.update(
          widget.settings.value.copyWith(expectimax: _options.withDepth(depth)),
        ),
      ),
    ),
  );

  /// Where the opponent's replies come from: typed or picked, taken at once.
  Widget _repliesField() => Tooltip(
    message:
        'Where the opponent\'s replies and how often each is played '
        'come from.',
    child: ChoiceField(
      text: _options.replies.label,
      options: [for (final source in ReplySource.values) source.label],
      hint: 'Maia or a database',
      label: SearchSettingCopy.replies.$1,
      enabled: !widget.fill.running,
      onSubmitted: (picked) {
        final source = ReplySource.values
            .where((source) => source.label == picked)
            .firstOrNull;
        if (source == null || source == _options.replies) return;
        unawaited(
          widget.settings.update(
            widget.settings.value.copyWith(
              expectimax: _options.copyWith(replies: source),
            ),
          ),
        );
      },
    ),
  );

  Widget _gear(BuildContext context) => IconButton(
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
  );

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

  /// What the next search will be.
  String get _summary {
    if (_book) return 'ChessDB\'s best moves, master replies';
    final e = _options;
    final maia = 'Maia ${widget.settings.value.opponentElo}';
    return [
      if (e.replies == ReplySource.maia)
        maia
      else if (e.maiaFallback)
        '$maia under ${e.fallbackUnder} games',
      'best ${e.rootMoves}, then ${e.candidateMoves}',
      if (e.source != EvaluationSource.stockfish) e.source.label,
    ].join(' · ');
  }

  /// The side the search prepares, which is the bottom of the board, as a
  /// button that turns the board to the other. Held while a search runs,
  /// as the rest of its settings are.
  Widget _sideButton() {
    final white = widget.session.orientation == Side.white;
    return Tooltip(
      message: AppKey.flip.tip(
        'Search for ${white ? 'Black' : 'White'} and turn the board',
      ),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: Space.s),
        ),
        onPressed: widget.fill.running ? null : widget.session.flip,
        icon: const Icon(Icons.swap_vert, size: IconSize.action),
        label: Text(white ? 'White' : 'Black'),
      ),
    );
  }

  /// One line of fixed height: the side, then what will run, how far the
  /// search has got, what it did, or what went wrong. While a search with
  /// no depth runs, the way to let it finish the depth it is on sits at the
  /// line's end.
  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.fill.state;
    final problem = _invalid ?? _refusal;
    final (words, error) = switch (state) {
      _ when problem != null => (problem, true),
      FillIdle() => (_summary, false),
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
        padding: const EdgeInsets.only(left: Space.xs, right: Space.xs),
        child: Row(
          children: [
            _sideButton(),
            const SizedBox(width: Space.s),
            // The line is one line; resting on it says the rest.
            Expanded(
              child: Tooltip(
                message: words,
                child: Text(
                  words,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: error ? theme.colorScheme.error : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
    final side = widget.session.orientation;
    final mine = widget.fill.nodeAtBoard(request: found.request);
    final other = widget.fill.nodeAtBoard(
      request: found.request,
      side: side.opposite,
    );
    final rows = searchRows(side: side, mine: mine, other: other);
    if (rows.isNotEmpty) {
      return SearchTable(
        rows: rows,
        ours: widget.session.fen.whiteToMove == (side == Side.white),
        sides: found.request.method == SearchMethod.mainline
            ? [side]
            : const [Side.white, Side.black],
        engineDepthAt: widget.fill.engineDepthAt,
        shareTip: (from) => repliesFromTip(
          from,
          database: found.request.replies.label,
          elo: found.request.elo,
          fallbackUnder: found.request.fallbackUnder,
        ),
        onHover: (row, anchor) => _hover(row.after, row.move.uci, anchor),
        onLeave: _leave,
        onPlay: (row) => _play(row.move.uci),
      );
    }
    return switch (mine ?? other) {
      null => _offTree(context, found),
      TerminalNode() => _sentence(context, 'The game is over here.'),
      _ => _sentence(
        context,
        widget.fill.running
            ? 'Not reached yet.'
            : 'The search stopped before this position.',
      ),
    };
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
