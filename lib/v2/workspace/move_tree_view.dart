import 'package:flutter/material.dart';

import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../ui/theme.dart';
import 'document_session.dart';

/// The move list: the main line as running text, each variation as an
/// indented block right after the move it replaces, the way Lichess lays
/// out a study. Clicking a move puts the cursor on it.
class MoveTreeView extends StatelessWidget {
  const MoveTreeView({super.key, required this.session});

  final DocumentSession session;

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

final class _LineBuilder {
  _LineBuilder(this.session);

  final DocumentSession session;

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
      onTap: () => session.goTo(path),
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

/// One clickable move. When it becomes the selected one it scrolls itself
/// into view.
class _MoveToken extends StatefulWidget {
  const _MoveToken({
    required this.label,
    required this.san,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String san;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MoveToken> createState() => _MoveTokenState();
}

class _MoveTokenState extends State<_MoveToken> {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: widget.selected
              ? scheme.primary.withValues(alpha: 0.35)
              : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text.rich(
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
