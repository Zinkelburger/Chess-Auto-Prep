import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/generation/finds.dart';
import '../chess/pgn/tree_edit.dart' show positionOf;
import '../storage/finds_store.dart';
import '../ui/row_actions.dart';
import '../ui/theme.dart';
import 'finds.dart';
import 'line_preview.dart';

/// The Positions column: everything the searches have pointed out, one row
/// a position, in the column a mode keeps its own list in.
///
/// Clicking a row puts its line on an analysis board at the position, so
/// the board, the move list and the engine all read it as they would any
/// line, and it can be played on, edited or saved. ↑ and ↓ walk the rows
/// the same way. Resting on a row floats the position beside it.
class FindsPanel extends StatefulWidget {
  const FindsPanel({
    super.key,
    required this.finds,
    required this.onOpen,
    this.trailing,
  });

  final Finds finds;

  /// Puts the find's line on the board at its position.
  final ValueChanged<KeptFind> onOpen;

  /// What sits in the toolbar's corner: the host's switch and toggle.
  final Widget? trailing;

  @override
  State<FindsPanel> createState() => _FindsPanelState();
}

class _FindsPanelState extends State<FindsPanel> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Side _previewSide = Side.white;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    widget.finds.load();
  }

  @override
  void didUpdateWidget(FindsPanel old) {
    super.didUpdateWidget(old);
    if (old.finds != widget.finds) widget.finds.load();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  void _hover(KeptFind kept, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      final last = _lastMove(kept);
      if (last == null) return;
      setState(() => _previewSide = kept.side);
      _preview.value = LinePreview(
        fen: kept.find.fen,
        lastMove: last,
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _preview.value = null;
  }

  void _open(KeptFind kept) {
    _leave();
    widget.onOpen(kept);
  }

  @override
  Widget build(BuildContext context) {
    final finds = widget.finds;
    return LinePreviewOverlay(
      preview: _preview,
      orientation: _previewSide,
      child: ListenableBuilder(
        listenable: finds,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(trailing: widget.trailing),
            _Order(finds: finds),
            _Kinds(finds: finds),
            _CountLine(finds: finds),
            Expanded(child: _list(context, finds)),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, Finds finds) {
    final shown = finds.shown;
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Text(
          finds.all.isEmpty
              ? 'Nothing found yet. Run a search from the Search tab; '
                    'what it points out is listed here.'
              : 'None of these kinds.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      itemCount: shown.length,
      itemExtent: trainRowHeight,
      itemBuilder: (context, at) {
        final kept = shown[at];
        return _FindRow(
          key: ValueKey(kept.id),
          kept: kept,
          open: finds.selected == kept.id,
          onOpen: () => _open(kept),
          onRemove: () => finds.remove(kept.id),
          onHover: (anchor) => _hover(kept, anchor),
          onLeave: _leave,
        );
      },
    );
  }
}

/// The column's name and the host's controls in the corner.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.trailing});

  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Positions',
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _Order extends StatelessWidget {
  const _Order({required this.finds});

  final Finds finds;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
    child: SegmentedButton<FindOrder>(
      segments: const [
        ButtonSegment(
          value: FindOrder.worth,
          label: Text('Top'),
          tooltip: 'How often it comes up times how much it matters',
        ),
        ButtonSegment(
          value: FindOrder.reach,
          label: Text('Common'),
          tooltip: 'How often a game gets there',
        ),
        ButtonSegment(
          value: FindOrder.newest,
          label: Text('Newest'),
          tooltip: 'The last found first',
        ),
      ],
      selected: {finds.order},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Space.xs),
        ),
      ),
      onSelectionChanged: (picked) => finds.sortBy(picked.single),
    ),
  );
}

class _Kinds extends StatelessWidget {
  const _Kinds({required this.finds});

  final Finds finds;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
    child: Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: [
        for (final kind in FindKind.values)
          FilterChip(
            label: Text(kindName(kind)),
            tooltip: _kindTip(kind),
            selected: finds.kinds.contains(kind),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => finds.toggle(kind),
          ),
      ],
    ),
  );
}

class _CountLine extends StatelessWidget {
  const _CountLine({required this.finds});

  final Finds finds;

  @override
  Widget build(BuildContext context) {
    final shown = finds.shown.length;
    final all = finds.all.length;
    final count = shown == all
        ? _positions(all)
        : '$shown of ${_positions(all)}';
    final last = switch (finds.recorded) {
      FindsReading() => ' · reading the last search…',
      FindsKept(:final count) => ' · last search found $count',
      null => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, Space.xs),
      child: Text(
        '$count$last',
        style: Theme.of(context).textTheme.labelSmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  static String _positions(int n) => n == 1 ? '1 position' : '$n positions';
}

/// One find: what it is and the move it is about, then the numbers that
/// make it worth a look.
class _FindRow extends StatelessWidget {
  const _FindRow({
    super.key,
    required this.kept,
    required this.open,
    required this.onOpen,
    required this.onRemove,
    required this.onHover,
    required this.onLeave,
  });

  final KeptFind kept;

  /// Whether its line is the one on the board.
  final bool open;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;

  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width, box.size.height / 2));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final find = kept.find;
    return MouseRegion(
      onEnter: (_) => onHover(_anchor(context)),
      onExit: (_) => onLeave(),
      child: Material(
        color: open ? scheme.secondaryContainer : Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: '${kindName(find.kind)}  '),
                            TextSpan(
                              text: keyMoveText(kept),
                              style: monoText.copyWith(color: scheme.onSurface),
                            ),
                          ],
                        ),
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        findNumbers(kept),
                        style: theme.textTheme.labelSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                RowActions(
                  children: [
                    MenuItemButton(
                      onPressed: onRemove,
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String kindName(FindKind kind) => switch (kind) {
  FindKind.trap => 'Trap',
  FindKind.onlyMove => 'Only move',
  FindKind.theirOnlyMove => 'Their only move',
  FindKind.practical => 'Practical',
};

String _kindTip(FindKind kind) => switch (kind) {
  FindKind.trap =>
    'A reply they play often that throws away half a pawn or more',
  FindKind.onlyMove => 'One move of yours holds; the rest lose',
  FindKind.theirOnlyMove =>
    'One reply holds for them, and they find it less than half the time',
  FindKind.practical =>
    'Not the engine\'s first choice, but it scores better against them',
};

/// The move the find is about, numbered, a blunder marked `?`.
String keyMoveText(KeptFind kept) {
  final find = kept.find;
  if (find.keyPly >= find.sans.length) return '';
  final (number, black) = _moveNumber(kept.rootFen, find.keyPly);
  final san = find.sans[find.keyPly];
  final mark = find.kind == FindKind.trap ? '?' : '';
  return black ? '$number…$san$mark' : '$number.$san$mark';
}

/// The numbers under a find: how often it comes up and what is at stake.
String findNumbers(KeptFind kept) {
  final find = kept.find;
  final pawns = (find.lossCp / 100).toStringAsFixed(1);
  final percent = '${(find.share * 100).round()}%';
  final stake = switch (find.kind) {
    FindKind.trap => 'played $percent · loses $pawns',
    FindKind.onlyMove => 'the rest lose $pawns+',
    FindKind.theirOnlyMove => 'found $percent · the rest lose $pawns+',
    FindKind.practical => 'gives up $pawns, scores better',
  };
  final side = kept.side == Side.white ? 'White' : 'Black';
  return '$stake · ${_reach(find.reach)} · $side';
}

String _reach(double reach) {
  if (reach >= 0.995) return 'every game';
  if (reach <= 0) return 'rare';
  final onceIn = (1 / reach).round();
  return onceIn > 9999 ? 'rare' : '1 in $onceIn games';
}

/// The number of the move [ply] half-moves after [root], and whether it is
/// Black's.
(int, bool) _moveNumber(Fen root, int ply) {
  final fields = root.value.split(' ');
  final blackFirst = fields.length > 1 && fields[1] == 'b';
  final first = fields.length > 5 ? int.tryParse(fields[5]) ?? 1 : 1;
  final offset = ply + (blackFirst ? 1 : 0);
  return (first + offset ~/ 2, offset.isOdd);
}

/// The last move to the find's position as UCI, for the floated board's
/// highlight; null when the line cannot be played from its root.
String? _lastMove(KeptFind kept) {
  var position = positionOf(kept.rootFen);
  if (position == null || kept.find.ply == 0) return null;
  String? uci;
  for (final san in kept.find.sans.take(kept.find.ply)) {
    final move = position!.parseSan(san);
    if (move == null) return null;
    uci = move.uci;
    position = position.play(move);
  }
  return uci;
}
