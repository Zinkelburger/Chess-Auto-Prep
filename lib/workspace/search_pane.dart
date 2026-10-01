import '../chess/generation/evaluation_source.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/generation/mainline_book.dart' show MainlineConfig;
import '../chess/generation/search_node.dart';
import '../storage/chapter_files.dart';
import '../storage/settings.dart';
import '../storage/settings_store.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'finds.dart';
import 'line_preview.dart';
import 'search_table.dart';
import '../ui/app_keys.dart';

/// The Expectimax panel: the expectimax search from the
/// board and its values.
///
/// Editable search settings and the play/stop action head the panel. Under them, for the position on
/// the board, every move the search looked at with what it is worth when
/// White is the prepared side and Black replies as the model predicts
/// (White), what it is worth the other way round (Black), and what the
/// engine alone says (Engine), all from White's side: a move whose value
/// for the other side sits well off the engine's is one the side playing
/// it is expected to go wrong after. Each move the model was asked about
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
  late final _evalDepth = TextEditingController(
    text: '${widget.fill.evalDepth}',
  );
  late final _rootMoves = TextEditingController(
    text: '${widget.fill.rootMoves}',
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
    _evalDepth.dispose();
    _rootMoves.dispose();
    _candidates.dispose();
    _cover.dispose();
    super.dispose();
  }

  FillRequest get _request =>
      widget.fill.requestFor(widget.settings.value.opponentElo);

  Future<bool> _applySettings() async {
    final elo = int.tryParse(_elo.text.trim());
    final depthText = _depth.text.trim();
    final depth = int.tryParse(depthText);
    final rootMoves = int.tryParse(_rootMoves.text.trim());
    final candidates = int.tryParse(_candidates.text.trim());
    final cover = int.tryParse(_cover.text.trim());
    final evalDepth = int.tryParse(_evalDepth.text.trim());
    final problem =
        elo == null || elo < Settings.minElo || elo > Settings.maxElo
        ? 'Maia rating: ${Settings.minElo} to ${Settings.maxElo}'
        : depthText.isNotEmpty &&
              (depth == null || depth < minFillDepth || depth > maxFillDepth)
        ? 'Depth: $minFillDepth to $maxFillDepth, or empty for no limit'
        : rootMoves == null || rootMoves < 1 || rootMoves > 218
        ? 'Root moves: 1 to 218'
        : candidates == null || candidates < 1 || candidates > 218
        ? 'Candidates: 1 to 218'
        : cover == null || cover < 0 || cover == 1
        ? 'Reply coverage: 2 or more games, or 0 for every reply'
        : evalDepth == null ||
              evalDepth < minFillEvalDepth ||
              evalDepth > maxFillEvalDepth
        ? 'Engine depth: $minFillEvalDepth to $maxFillEvalDepth'
        : null;
    if (!mounted) return false;
    setState(() => _problem = problem);
    if (problem != null) return false;
    widget.fill.depth = depth;
    widget.fill.rootMoves = rootMoves!;
    widget.fill.candidateMoves = candidates!;
    widget.fill.replyFloor = cover == 0 ? 0 : 1 / cover!;
    widget.fill.evalDepth = evalDepth!;
    await widget.settings.update(
      widget.settings.value.copyWith(opponentElo: elo!),
    );
    return mounted;
  }

  Future<void> _search() async {
    if (!await _applySettings()) return;
    final refusal = await widget.fill.resume(_request, orAfresh: true);
    if (!mounted || refusal == null) return;
    setState(() => _problem = refusal);
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

  bool get _book => widget.fill.method == SearchMethod.mainline;

  /// Maia practical or the ChessDB mainline book. The book asks no model
  /// and no engine, so their fields go while it is chosen.
  Widget _methodChoice() => SegmentedButton<SearchMethod>(
    segments: [
      for (final method in SearchMethod.values)
        ButtonSegment(value: method, label: Text(method.label)),
    ],
    selected: {widget.fill.method},
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    onSelectionChanged: widget.fill.running
        ? null
        : (picked) {
            if (!mounted) return;
            setState(() {
              widget.fill.method = picked.single;
              _problem = null;
            });
          },
  );

  List<Widget> _settingsFields() => [
    _methodChoice(),
    if (_book)
      Tooltip(
        message:
            'Follow the opponent\'s master replies this many half-moves '
            'from the board; past it every line runs on as ChessDB\'s '
            'mainline. Empty is ${MainlineConfig.defaultBranchPlies}.',
        child: _NumberBox(
          label: 'Depth',
          box: _depth,
          width: searchDepthWidth,
          hint: '${MainlineConfig.defaultBranchPlies}',
          enabled: !widget.fill.running,
          onSubmitted: () => unawaited(_applySettings()),
          onChanged: () => unawaited(_applySettings()),
        ),
      )
    else
      ..._practicalFields(),
  ];

  List<Widget> _practicalFields() => [
    _NumberBox(
      label: 'Maia rating',
      box: _elo,
      width: searchEloWidth,
      enabled: !widget.fill.running,
      onSubmitted: () => unawaited(_applySettings()),
      onChanged: () => unawaited(_applySettings()),
    ),
    Tooltip(
      message: 'Our best engine moves searched for our first move.',
      child: _NumberBox(
        label: 'Root moves',
        box: _rootMoves,
        width: searchEloWidth,
        enabled: !widget.fill.running,
        onSubmitted: () => unawaited(_applySettings()),
        onChanged: () => unawaited(_applySettings()),
      ),
    ),
    Tooltip(
      message: 'Our best engine moves searched at each later move.',
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
          'Engine depth each position is scored at. Hover an Engine value '
          'for the depth it was scored at.',
      child: _NumberBox(
        label: 'Engine depth',
        box: _evalDepth,
        width: searchEloWidth,
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
    // A search with these settings covers the board: pressing goes on.
    final resumable =
        running == null &&
        switch (fill.nodeAtBoard(request: _request)) {
          OurNode() || OpponentNode() => true,
          _ => false,
        };
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
              message: AppKey.search.tip(
                resumable
                    ? 'Go on from the search at this board'
                    : 'Search from the board',
              ),
              child: FilledButton.icon(
                onPressed: fill.canStart ? () => unawaited(_search()) : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(switch ((resumable, _book)) {
                  (true, true) => 'Resume build',
                  (true, false) => 'Resume expectimax',
                  (false, true) => 'Build',
                  (false, false) => 'Expectimax',
                }),
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
        _book
            ? 'ChessDB\'s best moves against master replies · $forSide'
            : 'Best ${widget.fill.rootMoves} at the root, '
                  '${widget.fill.candidateMoves} deeper · $forSide',
        false,
      ),
      FillRunning(:final depth, :final of, :final nodes, :final stopping) => (
        '${stopping ? 'Stopping at' : 'Searching'} depth $depth'
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
            : 'Press ▶ Expectimax to evaluate moves from this position.',
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
