import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../chess/pgn/study.dart';
import '../ui/listening_state.dart';
import '../ui/selection.dart';
import '../ui/theme.dart';
import 'chapter_commands.dart';
import 'comment_blocks.dart';
import 'document_session.dart';
import 'line_preview.dart';

/// The move list, read like a book: the main line as running text, each
/// comment as a paragraph of its own under the move it is on, each
/// variation as an indented block right after the move it replaces, the
/// way Lichess lays out a study. Clicking a move puts the cursor on it.
/// A move written inside a comment floats its position under the pointer,
/// and plays into the document when it follows on from the move the
/// comment is on.
///
/// The lines are built once for each tree and kept while the tree is the
/// same value: moving the cursor rebuilds only the move it left and the
/// move it reached, not a whole book of moves per arrow key.
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

class _MoveTreeViewState extends State<MoveTreeView>
    with CommentPreviews<MoveTreeView> {
  @override
  DocumentSession get session => widget.session;

  final _selection = Selection<NodePath>();

  /// The lines last built, and the tree and orientation they show.
  ({GameTree tree, Side side, Widget lines})? _built;

  @override
  void initState() {
    super.initState();
    _selection.follow(widget.session.cursorListenable);
  }

  @override
  void didUpdateWidget(MoveTreeView old) {
    super.didUpdateWidget(old);
    if (old.session == widget.session) return;
    _selection.follow(widget.session.cursorListenable);
    _built = null;
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  /// Takes the moves out. Nothing is said about it: the moves are gone from
  /// the tree on screen, and Ctrl+Z puts them back.
  void _deleteFrom(NodePath path) => deleteFrom(widget.session, path);

  Widget _comment(String comment, Fen at, NodePath from) => CommentBlocks(
    comment: comment,
    at: at,
    orientation: widget.session.orientation,
    onHover: hoverMove,
    onLeave: leaveMove,
    from: from,
    shown: session.commentLine,
    onRead: (moves, at) => readFrom(from, moves, at),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final tree = widget.session.tree;
        final shownTo = widget.session.shownTo;
        if (tree == null || tree.isEmpty || shownTo?.isRoot == true) {
          _built = null;
          return Center(
            child: Text(
              'No moves',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        if (shownTo != null) {
          _built = null;
          return _found(tree, shownTo);
        }
        final side = widget.session.orientation;
        final built = _built;
        if (built != null &&
            identical(built.tree, tree) &&
            built.side == side) {
          return built.lines;
        }
        final lines = _lines(tree, side);
        _built = (tree: tree, side: side, lines: lines);
        return lines;
      },
    );
  }

  /// The moves found so far of a line the user is asked to find: one row
  /// of moves and nothing else, so no note or variation gives the rest away.
  Widget _found(GameTree tree, NodePath shownTo) {
    _selection.reset();
    final builder = _LineBuilder(
      widget.session,
      _selection,
      (path) => const [],
      _deleteFrom,
      _comment,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        readingCardInset,
        Space.s,
        readingCardInset,
        Space.l,
      ),
      child: _Row(builder.found(tree, shownTo)),
    );
  }

  Widget _lines(GameTree tree, Side side) {
    _selection.reset();
    final builder = _LineBuilder(
      widget.session,
      _selection,
      (path) => widget.moveMenu?.call(path) ?? const [],
      _deleteFrom,
      _comment,
    );
    return LinePreviewOverlay(
      preview: preview,
      orientation: side,
      child: SingleChildScrollView(
        // Another game starts at the top: the scroll offset belongs to the
        // game it was scrolled in, and an edit keeps it.
        key: ValueKey((widget.session.source, widget.session.game)),
        padding: const EdgeInsets.fromLTRB(
          readingCardInset,
          Space.s,
          readingCardInset,
          Space.l,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (displayComment(tree.rootComment ?? '').isNotEmpty)
              _comment(tree.rootComment!, tree.rootFen, const NodePath.root()),
            ...builder.line(const NodePath.root(), tree.children),
          ],
        ),
      ),
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
  _LineBuilder(
    this.session,
    this.selection,
    this.moveMenu,
    this.onDeleteFrom,
    this.comment,
  );

  final DocumentSession session;
  final Selection<NodePath> selection;

  /// Asked when a move's menu opens, not when the lines are built, so the
  /// entries are the mode's as they are then.
  final MoveMenu moveMenu;

  /// Asked for the moves under a move to be taken out, so the screen can say
  /// what went and offer it back.
  final ValueChanged<NodePath> onDeleteFrom;

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

  /// The moves from the start to [limit] as tokens that only move the
  /// cursor: nothing can be done to a move of a line still being found.
  List<Widget> found(GameTree tree, NodePath limit) => [
    for (final (depth, node) in tree.lineTo(limit).indexed)
      _MoveToken(
        label: moveNumberLabel(node, startsLine: depth == 0),
        san: node.san,
        selected: selection.of(NodePath.of(limit.indexes.take(depth + 1))),
        quizStarts: false,
        quizEnds: false,
        onTap: () => session.goTo(NodePath.of(limit.indexes.take(depth + 1))),
        actions: () => const [],
      ),
  ];

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
      selected: selection.of(path),
      quizStarts: hasToken(node.comment, quizStartMarker),
      quizEnds: hasToken(node.comment, quizEndMarker),
      onTap: () => session.goTo(path),
      actions: () => [
        MenuItemButton(
          onPressed: () => promoteVariation(session, path),
          child: const Text('Promote variation'),
        ),
        MenuItemButton(
          onPressed: () => makeMainLine(session, path),
          child: const Text('Make main line'),
        ),
        MenuItemButton(
          onPressed: () => onDeleteFrom(path),
          child: const Text('Delete from here'),
        ),
        ...moveMenu(path),
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
/// When it becomes the selected one it scrolls itself into view. The menu's
/// entries are made when it opens: a list of a thousand moves has no use for
/// a thousand menus nobody opened.
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
  final ValueListenable<bool> selected;

  /// A quiz starts at this move, or ends after it. Shown as a small flag, so
  /// a marker that is only a token in the file is still something the reader
  /// can see.
  final bool quizStarts;
  final bool quizEnds;

  final VoidCallback onTap;

  /// What the right button offers for this move, asked when it opens.
  final List<Widget> Function() actions;

  @override
  State<_MoveToken> createState() => _MoveTokenState();
}

class _MoveTokenState extends State<_MoveToken>
    with ListeningState<_MoveToken> {
  final _menu = MenuController();

  /// Whether this move was the selected one when last drawn, so a rebuilt
  /// list does not scroll to a move that was already selected.
  bool _selected = false;
  bool _menuOpen = false;

  @override
  Listenable listenableOf(_MoveToken widget) => widget.selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected.value;
    if (_selected) _reveal();
  }

  @override
  void changed() {
    final now = widget.selected.value;
    if (now && !_selected) _reveal();
    setState(() => _selected = now);
  }

  void _menuShown(bool open) {
    if (mounted && open != _menuOpen) setState(() => _menuOpen = open);
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
      onOpen: () => _menuShown(true),
      onClose: () => _menuShown(false),
      menuChildren: _menuOpen ? widget.actions() : const [],
      child: InkWell(
        onTap: widget.onTap,
        onSecondaryTap: _menu.open,
        onLongPress: _menu.open,
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: moveTokenPadding,
          decoration: BoxDecoration(
            color: _selected ? scheme.primary.withValues(alpha: 0.35) : null,
            borderRadius: BorderRadius.circular(3),
          ),
          child: _label(scheme),
        ),
      ),
    );
  }
}
