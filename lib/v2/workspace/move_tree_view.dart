import 'package:flutter/material.dart';

import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../chess/pgn/study.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'chapter_commands.dart';
import 'undo_notice.dart';

/// What the move menu says when moves are taken out. The moves are gone from
/// every line that played them, so the notice names the move rather than a
/// number of lines.
String deletedFromHere(String san) => 'Deleted the moves from $san.';

/// The move list: the main line as running text, each variation as an
/// indented block right after the move it replaces, the way Lichess lays
/// out a study. Clicking a move puts the cursor on it.
class MoveTreeView extends StatelessWidget {
  const MoveTreeView({super.key, required this.session, this.moveMenu});

  final DocumentSession session;

  /// What the mode showing the move list adds to a move's menu, under the
  /// edits every mode has. The list knows nothing about the entries: it says
  /// which move was clicked and shows what it is given.
  final MoveMenu? moveMenu;

  /// Takes the moves out and offers the same way back a deleted line does:
  /// this removes more than a line does, so it may not be the one edit that
  /// cannot be taken back with one click.
  void _deleteFrom(BuildContext context, MoveNode node, NodePath path) {
    deleteFrom(session, path);
    showDeletionNotice(context, session, deletedFromHere(node.san));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final tree = session.tree;
        if (tree == null || tree.isEmpty) {
          return Center(
            child: Text(
              'No moves',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(Space.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (displayComment(tree.rootComment ?? '') case final prose
                  when prose.isNotEmpty)
                _Comment(text: prose),
              ..._LineBuilder(
                session,
                moveMenu,
                (node, path) => _deleteFrom(context, node, path),
              ).line(const NodePath.root(), tree.children),
            ],
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

final class _LineBuilder {
  _LineBuilder(this.session, this.moveMenu, this.onDeleteFrom);

  final DocumentSession session;
  final MoveMenu? moveMenu;

  /// Asked for the moves under a move to be taken out, so the screen can say
  /// what went and offer it back.
  final void Function(MoveNode node, NodePath path) onDeleteFrom;

  /// The line that starts at `siblings[branch]` and follows main
  /// continuations to the end. The other siblings of a main move are its
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
    while (true) {
      final node = at.siblings[at.branch];
      final path = at.parent.child(at.branch);
      // A note the file wrote before the move introduces it, so it is read
      // before it too, and the move that follows shows its number again.
      final introduction = displayComment(node.startingComment ?? '');
      if (introduction.isNotEmpty) {
        tokens.add(_Comment(text: introduction));
        numbered = true;
      }
      tokens.add(_token(node, path, numbered: numbered));
      final comment = displayComment(node.comment ?? '');
      if (comment.isNotEmpty) tokens.add(_Comment(text: comment));
      // As in print, a move after a comment shows its number again.
      numbered = comment.isNotEmpty;
      if (at.branch == 0 && at.siblings.length > 1) {
        blocks.add(_Line(tokens));
        blocks.addAll(_variations(at));
        tokens = <Widget>[];
        numbered = true;
      }
      if (node.children.isEmpty) break;
      at = (parent: path, siblings: node.children, branch: 0);
    }
    if (tokens.isNotEmpty) blocks.add(_Line(tokens));
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

class _Line extends StatelessWidget {
  const _Line(this.tokens);

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
      padding: const EdgeInsets.only(left: Space.m),
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
        style: monoText.copyWith(color: scheme.onSurface),
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

class _Comment extends StatelessWidget {
  const _Comment({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
      ),
    );
  }
}
