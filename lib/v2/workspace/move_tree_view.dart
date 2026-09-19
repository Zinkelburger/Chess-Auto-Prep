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
              if (tree.rootComment case final comment?) _Comment(text: comment),
              ..._LineBuilder(
                session,
              ).build(const NodePath.root(), tree.children, depth: 0),
            ],
          ),
        );
      },
    );
  }
}

/// Turns a forest into widgets. [build] renders `siblings[first]` and the
/// main continuations below it as one line. When the line starts at the
/// main move (`first == 0`), the other siblings are its variations and appear
/// as indented blocks straight after it; a variation block starts at its own
/// index and shows no siblings, since the main call already did.
final class _LineBuilder {
  _LineBuilder(this.session);

  final DocumentSession session;

  List<Widget> build(
    NodePath parent,
    List<MoveNode> siblings, {
    int first = 0,
    required int depth,
  }) {
    final blocks = <Widget>[];
    var tokens = <Widget>[];
    var path = parent;
    var index = first;
    var startsLine = true;
    while (index < siblings.length) {
      final node = siblings[index];
      final nodePath = path.child(index);
      tokens.add(_token(node, nodePath, startsLine: startsLine));
      if (node.comment case final comment?) {
        final text = displayComment(comment);
        if (text.isNotEmpty) tokens.add(_Comment(text: text));
      }
      startsLine = node.comment != null;
      if (index == 0 && siblings.length > 1) {
        blocks.add(_Line(tokens));
        tokens = <Widget>[];
        for (var i = 1; i < siblings.length; i++) {
          blocks.add(
            _VariationBlock(
              depth: depth + 1,
              children: build(path, siblings, first: i, depth: depth + 1),
            ),
          );
        }
        startsLine = true;
      }
      path = nodePath;
      siblings = node.children;
      index = 0;
    }
    if (tokens.isNotEmpty) blocks.add(_Line(tokens));
    return blocks;
  }

  Widget _token(MoveNode node, NodePath path, {required bool startsLine}) {
    return _MoveToken(
      label: moveNumberLabel(node, startsLine: startsLine),
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
  const _VariationBlock({required this.depth, required this.children});

  final int depth;
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

class _MoveToken extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (selected) _keepVisible(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.35) : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              if (label.isNotEmpty)
                TextSpan(
                  text: '$label ',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              TextSpan(text: san),
            ],
          ),
          style: monoText.copyWith(color: scheme.onSurface),
        ),
      ),
    );
  }

  /// Scrolls the list so the selected move is on screen after this frame,
  /// which is when it has a position.
  void _keepVisible(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 100),
      );
    });
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
