import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/generation/draft_lines.dart';
import '../chess/generation/traps.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart' show moveNumberLabel;
import '../ui/theme.dart';
import 'document_session.dart';
import 'fill_found.dart';
import 'fill_gaps.dart';
import 'line_preview.dart';

/// The Prep tab of the reading card: what the last search from the board
/// found, the traps first and then the lines, each one click from the
/// board. A trap stops on the opponent's mistake, so the punishment is
/// there to be found; a line goes to its end. Resting the pointer on a row
/// floats the position it leads to. Before any search it says what one
/// does; the search is started from the strip's `Generate…`.
class PrepPane extends StatefulWidget {
  const PrepPane({
    super.key,
    required this.fill,
    required this.session,
    required this.onGo,
  });

  final FillGaps fill;

  /// For the side the floated board is seen from.
  final DocumentSession session;

  /// Asked to put the item at this index of [FillFound.items] on the board.
  final ValueChanged<int> onGo;

  @override
  State<PrepPane> createState() => _PrepPaneState();
}

class _PrepPaneState extends State<PrepPane> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  /// A row rebuilt or gone from under the pointer never hears it leave, so
  /// the floated board goes whenever the run's results change.
  @override
  void initState() {
    super.initState();
    widget.fill.addListener(_leave);
  }

  @override
  void didUpdateWidget(PrepPane old) {
    super.didUpdateWidget(old);
    if (old.fill != widget.fill) {
      old.fill.removeListener(_leave);
      widget.fill.addListener(_leave);
    }
  }

  @override
  void dispose() {
    widget.fill.removeListener(_leave);
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  void _hover(FoundItem item, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      final last = item.moves[item.stopAfter - 1];
      _preview.value = LinePreview(
        fen: last.after,
        lastMove: last.move.uci,
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _preview.value = null;
  }

  void _go(int index) {
    _leave();
    widget.onGo(index);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.fill, widget.session]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.fill.found?.side ?? widget.session.orientation,
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final found = widget.fill.found;
    if (found == null) {
      return switch (widget.fill.state) {
        FillRunning() => const _Sentence(
          'Searching. The traps and lines it finds are listed here.',
        ),
        // A failure is said once, on the fill's line above the tabs.
        FillIdle() || FillDone() || FillFailed() => const _Sentence(
          'Generate searches from the board for the moves that score best '
          'against a human opponent, and the traps along the way.',
        ),
      };
    }
    final items = found.items;
    final picked = widget.fill.picked;
    final traps = found.traps.length;
    return ListView.builder(
      itemCount: items.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _Heading(
            'Traps · $traps',
            empty: traps == 0 ? 'No trap on these lines.' : null,
          );
        }
        if (index == traps + 1) {
          return _Heading('Lines · ${found.lines.length}');
        }
        final at = index <= traps ? index - 1 : index - 2;
        final item = items[at];
        return _Row(
          key: ValueKey(at),
          item: item,
          picked: at == picked,
          onHover: (anchor) => _hover(item, anchor),
          onLeave: _leave,
          onTap: () => _go(at),
        );
      },
    );
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.m),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );
}

/// A section's name and count, muted, with a line under it when it has
/// nothing to list.
class _Heading extends StatelessWidget {
  const _Heading(this.words, {this.empty});

  final String words;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            words,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (empty case final empty?) ...[
            const SizedBox(height: Space.xs),
            Text(empty, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// One trap or line: the moves in mono on top, what they are worth muted
/// under them.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.item,
    required this.picked,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final FoundItem item;
  final bool picked;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = monoText.copyWith(color: scheme.onSurfaceVariant);
    final (moves, after, about) = switch (item) {
      FoundTrap(:final trap) => _trapWords(trap),
      FoundLine(:final line) => _lineWords(line),
    };
    return Material(
      color: picked ? scheme.surfaceContainerHigh : Colors.transparent,
      child: MouseRegion(
        onEnter: (_) => onHover(_anchor(context)),
        onExit: (_) => onLeave(),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.m,
              vertical: Space.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: moves,
                        style: monoText.copyWith(color: scheme.onSurface),
                      ),
                      if (after.isNotEmpty)
                        TextSpan(text: ' $after', style: muted),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  about,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mistake with its `?` and our answer after it, then where it is set,
/// how often it is played and what it throws away.
(String, String, String) _trapWords(Trap trap) {
  final at = trap.toTrap.length;
  final numbered = _numbered(trap.moves, breakAt: at);
  final setUp = numbered.take(at).join(' ');
  final pawns = (trap.lossCp / 100).toStringAsFixed(1);
  return (
    '${numbered[at]}?',
    numbered.skip(at + 1).join(' '),
    [
      if (setUp.isNotEmpty) 'after $setUp',
      'played ${_percent(trap.share)}',
      'loses $pawns',
      _onceIn(trap.springs),
    ].join(' · '),
  );
}

/// The line's moves, then how often it is reached and what the search
/// thinks its end is worth.
(String, String, String) _lineWords(DraftLine line) => (
  _numbered(line.moves).join(' '),
  '',
  '${_onceIn(line.reach)} · ${expectimaxText(line.moves.last.value)}',
);

/// [moves] as the move list numbers them, one word per move. The move at
/// [breakAt] starts a line of its own, so a Black move there reads
/// `5...Nxe4` rather than `Nxe4`.
List<String> _numbered(List<DraftMove> moves, {int breakAt = 0}) => [
  for (final (i, move) in moves.indexed)
    '${moveNumberLabel(
          MoveNode(san: move.move.san, uci: move.move.uci, fen: move.after),
          startsLine: i == 0 || i == breakAt,
        )}'
        '${move.move.san}',
];

String _percent(double share) => share >= 0.995
    ? '100%'
    : share < 0.005
    ? '<1%'
    : '${(share * 100).round()}%';

/// How often a game from the board gets here, the way a player counts it.
String _onceIn(double reach) {
  if (reach >= 0.5) return 'most games';
  if (reach <= 0) return 'rarely';
  final n = (1 / reach).round();
  return n <= 1 ? 'most games' : '1 game in $n';
}
