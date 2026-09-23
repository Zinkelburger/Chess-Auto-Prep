import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/pgn/move_label.dart' show numberedMoves;
import '../ui/app_action.dart';
import '../ui/theme.dart';
import 'repertoire_tree.dart';
import 'document_session.dart';
import 'line_preview.dart';

/// The Tree tab of the reading card: the user's own repertoires as an
/// opening explorer. For the position on the board, every move any of the
/// side's repertoires plays, most lines first: the move, how many lines go
/// through it, how the biggest of them goes on, and which files hold it.
///
/// While it is up the board is a free board: clicking a move, or playing
/// any move on the board, steps into the file when the file plays it and
/// otherwise plays it past the file without writing it, and the tree
/// follows. Clicking the file a move is found in opens that file there.
/// Resting the pointer on a move floats the position after it.
class TreePane extends StatefulWidget {
  const TreePane({
    super.key,
    required this.session,
    required this.tree,
    this.onOpen,
  });

  final DocumentSession session;
  final RepertoireTree tree;

  /// Asked to put another file on the board where a move leads, which is
  /// the shell's business. Null when nothing can, and then only the moves
  /// of the document on the board can be clicked.
  final ValueChanged<TreePlace>? onOpen;

  @override
  State<TreePane> createState() => _TreePaneState();
}

class _TreePaneState extends State<TreePane> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  /// A row rebuilt or gone from under the pointer never hears it leave, so
  /// the floated board goes whenever the rows do.
  @override
  void initState() {
    super.initState();
    widget.tree.watch();
    widget.tree.addListener(_leave);
  }

  @override
  void didUpdateWidget(TreePane old) {
    super.didUpdateWidget(old);
    if (old.tree != widget.tree) {
      old.tree.removeListener(_leave);
      old.tree.unwatch();
      widget.tree.watch();
      widget.tree.addListener(_leave);
    }
  }

  @override
  void dispose() {
    widget.tree.removeListener(_leave);
    widget.tree.unwatch();
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  void _hover(TreeRow row, Offset anchor) {
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

  void _play(TreeRow row) {
    _leave();
    widget.tree.play(row.uci);
  }

  void _open(TreePlace place) {
    _leave();
    widget.onOpen?.call(place);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.tree,
        widget.tree.board,
        widget.session,
      ]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Summary(tree: widget.tree),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (widget.tree.state) {
    TreeReading() => const _Sentence('Reading your repertoires…'),
    TreeNothing(:final sentence) => _Sentence(sentence),
    TreeShown(:final rows) => ListView.builder(
      itemCount: rows.length + 1,
      itemBuilder: (context, index) => index == 0
          ? const _Header()
          : _MoveRow(
              key: ValueKey(rows[index - 1].uci),
              row: rows[index - 1],
              onHover: (anchor) => _hover(rows[index - 1], anchor),
              onLeave: _leave,
              onTap: () => _play(rows[index - 1]),
              onOpen: widget.onOpen == null
                  ? null
                  : () => _open(rows[index - 1].places.first),
            ),
    ),
  };
}

/// One muted line saying whose repertoires are shown and how many files,
/// or, past the file, the moves played off it with the ways back.
class _Summary extends StatelessWidget {
  const _Summary({required this.tree});

  final RepertoireTree tree;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final off = tree.offFile;
    final side = tree.side == Side.white ? 'White' : 'Black';
    final files = tree.fileCount;
    final words = off.isNotEmpty
        ? 'Off the file: ${numberedMoves(off)}'
        : tree.state is TreeReading
        ? '$side repertoires'
        : '$side repertoires · $files ${files == 1 ? 'file' : 'files'}';
    return SizedBox(
      height: engineBarHeight,
      child: Row(
        children: [
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(
              words,
              style: text.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (off.isNotEmpty) ...[
            IconButton(
              tooltip: withKey('Take back', '←'),
              iconSize: IconSize.menu,
              visualDensity: VisualDensity.compact,
              onPressed: tree.back,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Back to the file',
              iconSize: IconSize.menu,
              visualDensity: VisualDensity.compact,
              onPressed: tree.backToFile,
              icon: const Icon(Icons.close),
            ),
          ],
        ],
      ),
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

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      height: explorerHeaderHeight,
      child: Row(
        children: [
          const SizedBox(width: Space.m),
          SizedBox(
            width: explorerMoveWidth,
            child: Text('Move', style: style),
          ),
          SizedBox(
            width: treeLinesWidth,
            child: Text('Lines', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: Space.m),
          Expanded(child: Text('Goes on', style: style)),
          const SizedBox(width: Space.m),
          SizedBox(
            width: treeFilesWidth,
            child: Text('Found in', style: style),
          ),
          const SizedBox(width: Space.m),
        ],
      ),
    );
  }
}

class _MoveRow extends StatelessWidget {
  const _MoveRow({
    super.key,
    required this.row,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
    required this.onOpen,
  });

  final TreeRow row;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  /// Opens the file with the most lines at the move; null when nothing can.
  final VoidCallback? onOpen;

  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = monoText.copyWith(color: scheme.onSurfaceVariant);
    return Material(
      color: Colors.transparent,
      child: MouseRegion(
        onEnter: (_) => onHover(_anchor(context)),
        onExit: (_) => onLeave(),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: replyRowHeight,
            child: Row(
              children: [
                const SizedBox(width: Space.m),
                SizedBox(width: explorerMoveWidth, child: _move(scheme)),
                SizedBox(
                  width: treeLinesWidth,
                  child: Text(
                    '${row.lines}',
                    textAlign: TextAlign.right,
                    style: muted,
                  ),
                ),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Text(
                    row.goesOn,
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Space.m),
                SizedBox(width: treeFilesWidth, child: _files(context)),
                const SizedBox(width: Space.m),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The file with the most lines, and how many more; all of them under
  /// the pointer. Clicking it opens the first one there.
  Widget _files(BuildContext context) {
    final names = row.names;
    return Tooltip(
      message: [
        if (onOpen != null) 'Open ${names.first} here' else names.first,
        if (names.length > 1) 'Also in ${names.skip(1).join(', ')}',
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onOpen,
        child: Text(
          names.length == 1
              ? names.first
              : '${names.first} +${names.length - 1}',
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// The move alone, as the explorer shows it: every row would carry the
  /// same number.
  Widget _move(ColorScheme scheme) => Text(
    row.san,
    style: monoText.copyWith(color: scheme.onSurface),
    overflow: TextOverflow.ellipsis,
  );
}
