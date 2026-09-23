import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/generation/draft_lines.dart' show expectimaxText;
import '../chess/generation/eval.dart';
import '../chess/generation/search_node.dart';
import '../engines/engine_line.dart' show Centipawns;
import '../storage/chapter_files.dart';
import '../storage/settings.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'fill_gaps.dart';
import 'line_preview.dart';

/// The Search tab of the reading card: the expectimax search from the
/// board and its values.
///
/// On top, the three numbers a search is asked for and the one button that
/// starts it, or stops it while it runs. Under them, for the position on
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

class _SearchPaneState extends State<SearchPane> {
  late final _elo = TextEditingController(
    text: '${widget.settings.value.opponentElo}',
  );
  late final _depth = TextEditingController(text: '${widget.fill.depth}');
  late final _onceIn = TextEditingController(
    text: '${widget.settings.value.coverOnceIn}',
  );
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  /// Why the last press of Search did nothing: a number out of range or a
  /// refusal. Cleared by the next press.
  String? _problem;

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    _elo.dispose();
    _depth.dispose();
    _onceIn.dispose();
    super.dispose();
  }

  int? _number(TextEditingController box, int min, int max) {
    final value = int.tryParse(box.text.trim());
    return value != null && value >= min && value <= max ? value : null;
  }

  Future<void> _search() async {
    final elo = _number(_elo, Settings.minElo, Settings.maxElo);
    final depth = _number(_depth, minFillDepth, maxFillDepth);
    final onceIn = _number(
      _onceIn,
      Settings.minCoverOnceIn,
      Settings.maxCoverOnceIn,
    );
    final problem = elo == null
        ? 'Rating: ${Settings.minElo} to ${Settings.maxElo}'
        : depth == null
        ? 'Depth: $minFillDepth to $maxFillDepth'
        : onceIn == null
        ? 'Skip under 1 in: '
              '${Settings.minCoverOnceIn} to ${Settings.maxCoverOnceIn}'
        : null;
    setState(() => _problem = problem);
    if (elo == null || depth == null || onceIn == null) return;
    widget.fill.depth = depth;
    final s = widget.settings.value;
    if (s.opponentElo != elo || s.coverOnceIn != onceIn) {
      unawaited(
        widget.settings.update(
          s.copyWith(opponentElo: elo, coverOnceIn: onceIn),
        ),
      );
    }
    final refusal = await widget.fill.start(
      FillRequest(elo: elo, depthPlies: depth, onceIn: onceIn),
    );
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
    widget.session.playMove(uci);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.fill, widget.session.anyChange]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _form(context),
            _status(context),
            const Divider(height: 1),
            Expanded(child: _table(context)),
            ?_linesRow(context),
          ],
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final fill = widget.fill;
    final state = fill.state;
    final running = state is FillRunning ? state : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _NumberBox(
            label: 'Opponent',
            box: _elo,
            width: searchEloWidth,
            enabled: running == null,
            onSubmitted: _search,
          ),
          const SizedBox(width: Space.m),
          _NumberBox(
            label: 'Depth',
            box: _depth,
            width: searchDepthWidth,
            enabled: running == null,
            onSubmitted: _search,
          ),
          const SizedBox(width: Space.m),
          _NumberBox(
            label: 'Skip under 1 in',
            box: _onceIn,
            width: searchOnceInWidth,
            enabled: running == null,
            onSubmitted: _search,
          ),
          const Spacer(),
          if (running == null)
            Tooltip(
              message: withKey('Search from the board', 'Ctrl+G'),
              child: FilledButton(
                onPressed: fill.canStart ? () => unawaited(_search()) : null,
                child: const Text('Search'),
              ),
            )
          else
            Tooltip(
              message: 'Stop and keep what it found',
              child: FilledButton.tonal(
                onPressed: running.stopping ? null : fill.finish,
                child: const Text('Stop'),
              ),
            ),
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
        'Scores every move from here against the opponent, $forSide.',
        false,
      ),
      FillRunning(:final depth, :final of, :final nodes, :final stopping) => (
        stopping
            ? 'Stopping at depth $depth · $nodes positions'
            : 'Searching $forSide · depth $depth of $of · $nodes positions',
        false,
      ),
      FillDone(:final depth, :final nodes, :final complete) => (
        '${complete ? 'Searched' : 'Stopped at'} depth $depth $forSide · '
            '$nodes positions · rated ${found?.request.elo ?? ''}',
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

  Widget _table(BuildContext context) {
    final found = widget.fill.found;
    if (found == null) return const SizedBox.shrink();
    final session = widget.session;
    final tree = session.tree;
    final node = tree == null
        ? null
        : found.at(tree.rootFen, [
            for (final move in tree.lineTo(session.cursor)) move.san,
          ]);
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
            'This position is not in the search.',
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

  /// Under a finished search on a repertoire chapter: the way to turn it
  /// into lines, or what became of that.
  Widget? _linesRow(BuildContext context) {
    final fill = widget.fill;
    final theme = Theme.of(context);
    final lines = fill.lines;
    final Widget child;
    if (lines is LinesWritten) {
      final open = widget.onOpenChapter;
      final count = lines.lines == 1 ? '1 line' : '${lines.lines} lines';
      child = Row(
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

/// A labelled number field, narrow enough for three in a row.
class _NumberBox extends StatelessWidget {
  const _NumberBox({
    required this.label,
    required this.box,
    required this.width,
    required this.enabled,
    required this.onSubmitted,
  });

  final String label;
  final TextEditingController box;
  final double width;
  final bool enabled;
  final Future<void> Function() onSubmitted;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: TextField(
      controller: box,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, isDense: true),
      onSubmitted: (_) => unawaited(onSubmitted()),
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
    required this.side,
    required this.ours,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final _Row row;

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
                  child: Text(
                    _engineText(after.evalForUs, white: white),
                    style: muted,
                    textAlign: TextAlign.right,
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
