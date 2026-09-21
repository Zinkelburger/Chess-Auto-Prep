import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../chess/pgn/study.dart';
import '../chess/pv_text.dart';
import '../ui/theme.dart';
import 'chapter_commands.dart';
import 'comment_blocks.dart';
import 'document_session.dart';
import 'line_preview.dart';
import 'undo_notice.dart';

/// What the move menu says when moves are taken out. The moves are gone from
/// every line that played them, so the notice names the move rather than a
/// number of lines.
String deletedFromHere(String san) => 'Deleted the moves from $san.';

/// The move list, read like a book: the main line as running text, each
/// comment as a paragraph of its own under the move it is on, each
/// variation as an indented block right after the move it replaces, the
/// way Lichess lays out a study. Clicking a move puts the cursor on it.
/// A move written inside a comment floats its position under the pointer,
/// and plays into the document when it follows on from the move the
/// comment is on.
class MoveTreeView extends StatefulWidget {
  const MoveTreeView({super.key, required this.session, this.moveMenu});

  final DocumentSession session;

  /// What the mode showing the move list adds to a move's menu, under the
  /// edits every mode has. The list knows nothing about the entries: it says
  /// which move was clicked and shows what it is given.
  final MoveMenu? moveMenu;

  @override
  State<MoveTreeView> createState() => _MoveTreeViewState();
}

class _MoveTreeViewState extends State<MoveTreeView> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  /// The board appears once the pointer has rested on a move.
  void _hover(PvMove move, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      _preview.value = LinePreview(
        fen: move.after,
        lastMove: move.uci,
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _preview.value = null;
  }

  /// Plays [moves] from the move at [from], where the comment they were
  /// written in belongs. A move that does not land, because the document
  /// refused it, ends the walk there.
  void _play(NodePath from, List<PvMove> moves) {
    _leave();
    final session = widget.session;
    session.goTo(from);
    for (final move in moves) {
      session.playMove(move.uci);
      if (session.fen != move.after) return;
    }
  }

  /// Takes the moves out and offers the same way back a deleted line does:
  /// this removes more than a line does, so it may not be the one edit that
  /// cannot be taken back with one click.
  void _deleteFrom(MoveNode node, NodePath path) {
    deleteFrom(widget.session, path);
    showDeletionNotice(context, widget.session, deletedFromHere(node.san));
  }

  Widget _comment(String comment, Fen at, NodePath from) => CommentBlocks(
    comment: comment,
    at: at,
    orientation: widget.session.orientation,
    onHover: _hover,
    onLeave: _leave,
    onPlay: (moves) => _play(from, moves),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final tree = widget.session.tree;
        if (tree == null || tree.isEmpty) {
          return Center(
            child: Text(
              'No moves',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final builder = _LineBuilder(
          widget.session,
          widget.moveMenu,
          _deleteFrom,
          _comment,
        );
        return LinePreviewOverlay(
          preview: _preview,
          orientation: widget.session.orientation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (displayComment(tree.rootComment ?? '').isNotEmpty)
                  _comment(
                    tree.rootComment!,
                    tree.rootFen,
                    const NodePath.root(),
                  ),
                ...builder.line(const NodePath.root(), tree.children),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Where a line is: one sibling list under one parent, and which sibling.
typedef _Branch = ({NodePath parent, List<MoveNode> siblings, int branch});

/// What a mode adds to the menu on the move at `path`.
typedef MoveMenu = List<Widget> Function(NodePath path);

/// A comment laid out from the position [at], belonging to the move at
/// [from] — the one a line of analysis in it is played from.
typedef _CommentWidget = Widget Function(String comment, Fen at, NodePath from);

final class _LineBuilder {
  _LineBuilder(this.session, this.moveMenu, this.onDeleteFrom, this.comment);

  final DocumentSession session;
  final MoveMenu? moveMenu;

  /// Asked for the moves under a move to be taken out, so the screen can say
  /// what went and offer it back.
  final void Function(MoveNode node, NodePath path) onDeleteFrom;

  final _CommentWidget comment;

  /// The line that starts at `siblings[branch]` and follows main
  /// continuations to the end. A comment is a paragraph of its own, so the
  /// moves before it close their row and the move after it shows its number
  /// again, as in print. The other siblings of a main move are its
  /// variations and interrupt the line as indented blocks, each a line of
  /// its own; the siblings of a variation's first move are not repeated.
  List<Widget> line(
    NodePath parent,
    List<MoveNode> siblings, {
    int branch = 0,
  }) {
    final blocks = <Widget>[];
    var tokens = <Widget>[];
    var numbered = true;
    var at = (parent: parent, siblings: siblings, branch: branch);
    void breakRow() {
      if (tokens.isNotEmpty) blocks.add(_Row(tokens));
      tokens = <Widget>[];
      numbered = true;
    }

    while (true) {
      final node = at.siblings[at.branch];
      final path = at.parent.child(at.branch);
      // A note the file wrote before the move introduces it, so it is read
      // before it too.
      if (displayComment(node.startingComment ?? '').isNotEmpty) {
        breakRow();
        blocks.add(
          comment(node.startingComment!, at.parent.fenIn(session), at.parent),
        );
      }
      tokens.add(_token(node, path, numbered: numbered));
      numbered = false;
      if (displayComment(node.comment ?? '').isNotEmpty) {
        breakRow();
        blocks.add(comment(node.comment!, node.fen, path));
      }
      if (at.branch == 0 && at.siblings.length > 1) {
        breakRow();
        blocks.addAll(_variations(at));
      }
      if (node.children.isEmpty) break;
      at = (parent: path, siblings: node.children, branch: 0);
    }
    breakRow();
    return blocks;
  }

  Iterable<Widget> _variations(_Branch at) sync* {
    for (var branch = 1; branch < at.siblings.length; branch++) {
      yield _VariationBlock(
        children: line(at.parent, at.siblings, branch: branch),
      );
    }
  }

  Widget _token(MoveNode node, NodePath path, {required bool numbered}) {
    return _MoveToken(
      label: moveNumberLabel(node, startsLine: numbered),
      san: node.san + node.nags.map(nagGlyph).nonNulls.join(),
      selected: session.cursor == path,
      quizStarts: hasToken(node.comment, quizStartMarker),
      quizEnds: hasToken(node.comment, quizEndMarker),
      onTap: () => session.goTo(path),
      actions: [
        MenuItemButton(
          onPressed: () => promoteVariation(session, path),
          child: const Text('Promote variation'),
        ),
        MenuItemButton(
          onPressed: () => makeMainLine(session, path),
          child: const Text('Make main line'),
        ),
        MenuItemButton(
          onPressed: () => onDeleteFrom(node, path),
          child: const Text('Delete from here'),
        ),
        ...?moveMenu?.call(path),
      ],
    );
  }
}

extension on NodePath {
  /// The position at this path in the session's tree.
  Fen fenIn(DocumentSession session) =>
      session.tree?.fenAt(this) ?? Fen.initial;
}

/// A row of moves that wrap as text does.
class _Row extends StatelessWidget {
  const _Row(this.tokens);

  final List<Widget> tokens;

  @override
  Widget build(BuildContext context) =>
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: tokens);
}

class _VariationBlock extends StatelessWidget {
  const _VariationBlock({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Space.xs),
      padding: const EdgeInsets.only(left: variationIndent),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// One clickable move, with what can be done to it on the right button.
/// When it becomes the selected one it scrolls itself into view.
class _MoveToken extends StatefulWidget {
  const _MoveToken({
    required this.label,
    required this.san,
    required this.selected,
    required this.quizStarts,
    required this.quizEnds,
    required this.onTap,
    required this.actions,
  });

  final String label;
  final String san;
  final bool selected;

  /// A quiz starts at this move, or ends after it. Shown as a small flag, so
  /// a marker that is only a token in the file is still something the reader
  /// can see.
  final bool quizStarts;
  final bool quizEnds;

  final VoidCallback onTap;

  /// What the right button offers for this move.
  final List<Widget> actions;

  @override
  State<_MoveToken> createState() => _MoveTokenState();
}

class _MoveTokenState extends State<_MoveToken> {
  final _menu = MenuController();

  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(_MoveToken old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  /// After the frame, because the token has no position until it is laid out.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 100),
      );
    });
  }

  /// The move's number and SAN, with a flag on either side when a quiz
  /// starts at it or ends after it.
  Widget _label(ColorScheme scheme) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (widget.quizStarts)
        Icon(
          Icons.play_arrow,
          size: IconSize.menu,
          color: scheme.onSurfaceVariant,
        ),
      Text.rich(
        TextSpan(
          children: [
            if (widget.label.isNotEmpty)
              TextSpan(
                text: '${widget.label} ',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            TextSpan(text: widget.san),
          ],
        ),
        style: readingMoveText.copyWith(color: scheme.onSurface),
      ),
      if (widget.quizEnds)
        Icon(Icons.stop, size: IconSize.menu, color: scheme.onSurfaceVariant),
    ],
  );

  /// The right button, and a long press for a pointer that has no right
  /// button, open what can be done to this move.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _menu,
      menuChildren: widget.actions,
      child: InkWell(
        onTap: widget.onTap,
        onSecondaryTap: _menu.open,
        onLongPress: _menu.open,
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: widget.selected
                ? scheme.primary.withValues(alpha: 0.35)
                : null,
            borderRadius: BorderRadius.circular(3),
          ),
          child: _label(scheme),
        ),
      ),
    );
  }
}
