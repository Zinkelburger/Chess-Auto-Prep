import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'document_session.dart';
import 'gap_hunt.dart';
import 'gap_walk.dart' show MissingReply;
import 'line_preview.dart';
import 'replies.dart';

/// The Replies tab of the reading card: what the opponent plays at the
/// position on the board, how often, and whether the chapter answers it.
///
/// One row per move, most likely first: the share in a gutter, the move,
/// and a tick when the chapter already plays it. At our own move a column
/// after the move holds what a fill said the move is worth, read off the
/// document's `[%expectimax]` tokens, or `not in tree` where no run
/// reached it; nothing is worked out while browsing. A reply the opponent plays
/// often enough and the chapter does not answer is a gap and its row says
/// so; the gap Next took the user to is the tinted row. Clicking a row plays
/// the move, which at the opponent's move adds their reply and puts the
/// board on our answer to write. Resting the pointer on a row floats the
/// position after it.
class RepliesPane extends StatefulWidget {
  const RepliesPane({
    super.key,
    required this.session,
    required this.replies,
    required this.gaps,
  });

  final DocumentSession session;
  final Replies replies;

  /// The walk the status line counts, and the gap whose row is tinted.
  final GapHunt gaps;

  @override
  State<RepliesPane> createState() => _RepliesPaneState();
}

class _RepliesPaneState extends State<RepliesPane> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  void _hover(ReplyRow row, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      _preview.value = LinePreview(
        fen: row.after,
        lastMove: row.uci,
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _preview.value = null;
  }

  void _play(ReplyRow row) {
    _leave();
    widget.session.playMove(row.uci);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.replies,
        widget.gaps,
        widget.session,
      ]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Status(replies: widget.replies, gaps: widget.gaps),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget sentence(String words) => Padding(
      padding: const EdgeInsets.all(Space.m),
      child: Text(words, style: text.bodySmall),
    );
    return switch (widget.replies.table) {
      RepliesEmpty() => sentence('Open a chapter to see what they play.'),
      RepliesPending() => const SizedBox.shrink(),
      RepliesFailed(:final reason) => sentence(reason),
      RepliesShown(:final rows, :final ourMove) =>
        rows.isEmpty
            ? sentence('No moves here.')
            : _rows(rows, ourMove: ourMove),
    };
  }

  Widget _rows(List<ReplyRow> rows, {required bool ourMove}) {
    final marked = switch (widget.gaps.highlighted) {
      MissingReply(:final uci) => uci,
      _ => null,
    };
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return _ReplyRow(
          key: ValueKey(row.uci),
          row: row,
          marked: row.uci == marked,
          ourMove: ourMove,
          onHover: (anchor) => _hover(row, anchor),
          onLeave: _leave,
          onTap: () => _play(row),
        );
      },
    );
  }
}

/// One line above the rows: whose move, the rating, and how the chapter is
/// doing — the gaps left and the share of games it answers.
class _Status extends StatelessWidget {
  const _Status({required this.replies, required this.gaps});

  final Replies replies;
  final GapHunt gaps;

  String get _words {
    final table = replies.table;
    final who = switch (table) {
      RepliesShown(ourMove: true) => 'Our candidates',
      _ => 'Their replies',
    };
    final rating = '$who · ${replies.elo}';
    final walk = gaps.walk;
    if (gaps.walking && walk == null) return '$rating · finding gaps…';
    if (walk == null) return rating;
    final found = walk.gaps.length;
    final covered = (walk.covered * 100).round();
    final counted = found == 1 ? '1 gap' : '$found gaps';
    return '$rating · $counted · $covered% covered';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: engineBarHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: Space.m),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _words,
                style: text.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyRow extends StatelessWidget {
  const _ReplyRow({
    super.key,
    required this.row,
    required this.marked,
    required this.ourMove,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final ReplyRow row;

  /// This is the gap Next took the user to.
  final bool marked;

  final bool ourMove;
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
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    return Material(
      color: marked ? scheme.surfaceContainerHighest : Colors.transparent,
      child: MouseRegion(
        onEnter: (_) => onHover(_anchor(context)),
        onExit: (_) => onLeave(),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: replyRowHeight,
            child: Row(
              children: [
                SizedBox(
                  width: replyShareWidth,
                  child: Text(
                    _percent(row.share),
                    textAlign: TextAlign.center,
                    style: monoText.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (row.label.isNotEmpty)
                          TextSpan(text: '${row.label} ', style: muted),
                        TextSpan(text: row.san),
                      ],
                    ),
                    style: monoText.copyWith(color: scheme.onSurface),
                  ),
                ),
                if (ourMove) _expectimax(theme),
                _mark(theme),
                const SizedBox(width: Space.m),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What the fill made of the move, or that none reached it.
  Widget _expectimax(ThemeData theme) {
    final scheme = theme.colorScheme;
    final value = row.expectimax;
    return Padding(
      padding: const EdgeInsets.only(right: Space.m),
      child: Text(
        value ?? 'not in tree',
        style: value == null
            ? theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              )
            : monoText.copyWith(color: scheme.onSurface),
      ),
    );
  }

  /// A tick for a move the chapter plays; the name of the chapter that
  /// answers a reply this one does not; the word for a reply it must answer
  /// and nothing does. Nothing for the rest.
  Widget _mark(ThemeData theme) {
    final scheme = theme.colorScheme;
    if (row.inRepertoire) {
      return Icon(
        Icons.check,
        size: IconSize.menu,
        color: scheme.onSurfaceVariant,
      );
    }
    if (row.elsewhere case final chapter?) {
      return Text(
        chapter,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        overflow: TextOverflow.ellipsis,
      );
    }
    if (row.gap) return Text('gap', style: theme.textTheme.labelSmall);
    return const SizedBox.shrink();
  }
}

/// `31%`, or `<1%` for a share the chapter plays but the model barely does.
String _percent(double share) {
  final percent = (share * 100).round();
  return percent < 1 ? '<1%' : '$percent%';
}
