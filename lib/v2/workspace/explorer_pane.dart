import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/explorer_answer.dart';
import '../ui/theme.dart';
import 'document_session.dart';
import 'explorer.dart';
import 'explorer_menu.dart';
import 'line_preview.dart';

export 'explorer_menu.dart' show ExplorerGear;

/// The Explorer tab of the reading card, lila's opening explorer: what a
/// database has seen played from the position on the board.
///
/// One muted line says which database and how it is narrowed; clicking it
/// opens the same menu as the gear at the strip's edge. Under it the table,
/// one row per move, most played first: the move, how many games and what
/// share, and how they ended as a bar; a tick when the chapter plays the
/// move here; a totals row to close it. Then the games the database names,
/// which open in the viewer. Clicking a move plays it, and on a repertoire
/// chapter that writes it; resting the pointer on one floats the position
/// after it.
class ExplorerPane extends StatefulWidget {
  const ExplorerPane({
    super.key,
    required this.session,
    required this.explorer,
    this.onOpenGame,
  });

  final DocumentSession session;
  final Explorer explorer;

  /// Asked to open one of the listed games, which is the shell's business:
  /// the game becomes a file and the viewer shows it. Null when nothing
  /// can, and then the games are listed without a click.
  final ValueChanged<ExplorerGame>? onOpenGame;

  @override
  State<ExplorerPane> createState() => _ExplorerPaneState();
}

class _ExplorerPaneState extends State<ExplorerPane> {
  final _preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    _preview.dispose();
    super.dispose();
  }

  void _hover(ExplorerRow row, Offset anchor) {
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

  void _play(ExplorerRow row) {
    _leave();
    widget.session.playMove(row.uci);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.explorer, widget.session]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Summary(explorer: widget.explorer),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final explorer = widget.explorer;
    return switch (explorer.state) {
      ExplorerIdle() => const _Sentence(
        'Open a chapter or a game to see what is played.',
      ),
      ExplorerAsking(:final source) => _Sentence('Asking ${source.title}…'),
      ExplorerNothing(:final sentence) => _Sentence(sentence),
      ExplorerFailed(:final sentence) => _Sentence(
        sentence,
        retry: explorer.retry,
      ),
      ExplorerShown(:final rows, :final answer) => _table(rows, answer),
    };
  }

  Widget _table(List<ExplorerRow> rows, ExplorerAnswer answer) {
    final explorer = widget.explorer;
    return ListView(
      children: [
        if (explorer.notice case final notice?)
          _Sentence(notice, retry: explorer.retry),
        const _Header(),
        for (final row in rows)
          _MoveRow(
            key: ValueKey(row.uci),
            row: row,
            onHover: (anchor) => _hover(row, anchor),
            onLeave: _leave,
            onTap: () => _play(row),
          ),
        _Totals(answer: answer),
        if (answer.games.isNotEmpty) ...[
          const Divider(height: 1),
          for (final game in answer.games)
            _GameRow(
              key: ValueKey(game.id),
              game: game,
              fetching: explorer.fetchingGame == game.id,
              onTap: widget.onOpenGame == null || explorer.fetchingGame != null
                  ? null
                  : () => widget.onOpenGame!(game),
            ),
        ],
      ],
    );
  }
}

/// One muted line saying what is asked, and the way to change it.
class _Summary extends StatelessWidget {
  const _Summary({required this.explorer});

  final Explorer explorer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ExplorerMenu(
      explorer: explorer,
      builder: (context, controller) => InkWell(
        onTap: controller.isOpen ? controller.close : controller.open,
        child: SizedBox(
          height: engineBarHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: Space.m),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                explorer.choice.summary,
                style: text.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A sentence where the table would be, with `Try again` when that is a
/// thing to do.
class _Sentence extends StatelessWidget {
  const _Sentence(this.words, {this.retry});

  final String words;
  final Future<void> Function()? retry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(words, style: text.bodySmall),
          if (retry case final again?)
            TextButton(
              onPressed: () => unawaited(again()),
              child: const Text('Try again'),
            ),
        ],
      ),
    );
  }
}

/// The column names over the rows, in the rows' own widths.
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
            width: explorerGamesWidth,
            child: Text('Games', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: Space.m),
          Expanded(child: Text('White / Draw / Black', style: style)),
          const SizedBox(width: IconSize.menu + Space.m),
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
  });

  final ExplorerRow row;
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
                  width: explorerGamesWidth,
                  child: Text(
                    '${formatGameCount(row.games)} · ${row.share}',
                    textAlign: TextAlign.right,
                    style: monoText.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: Space.m),
                Expanded(
                  child: ResultBar(
                    white: row.white,
                    draws: row.draws,
                    black: row.black,
                  ),
                ),
                SizedBox(width: IconSize.menu, child: _tick(scheme)),
                const SizedBox(width: Space.m),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The move, numbered as a line's first move is.
  Widget _move(ColorScheme scheme) => Text.rich(
    TextSpan(
      children: [
        if (row.label.isNotEmpty)
          TextSpan(
            text: '${row.label} ',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        TextSpan(text: row.san),
      ],
    ),
    style: monoText.copyWith(color: scheme.onSurface),
    overflow: TextOverflow.ellipsis,
  );

  /// A tick for a move the chapter plays here; the room for one otherwise,
  /// so the bars line up.
  Widget? _tick(ColorScheme scheme) => row.inRepertoire
      ? Icon(Icons.check, size: IconSize.menu, color: scheme.onSurfaceVariant)
      : null;
}

/// The `Σ` row: every game at the position, however it went on.
class _Totals extends StatelessWidget {
  const _Totals({required this.answer});

  final ExplorerAnswer answer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = answer.whiteTotal + answer.drawTotal + answer.blackTotal;
    return SizedBox(
      height: replyRowHeight,
      child: Row(
        children: [
          const SizedBox(width: Space.m),
          SizedBox(
            width: explorerMoveWidth,
            child: Text(
              'Σ',
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          SizedBox(
            width: explorerGamesWidth,
            child: Text(
              formatGameCount(total),
              textAlign: TextAlign.right,
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: ResultBar(
              white: answer.whiteTotal,
              draws: answer.drawTotal,
              black: answer.blackTotal,
            ),
          ),
          const SizedBox(width: IconSize.menu + Space.m),
        ],
      ),
    );
  }
}

/// How the games went, as lila draws it: White's wins, the draws and
/// Black's wins side by side in the row, each as wide as its share, with
/// the share written in the parts wide enough to carry it.
class ResultBar extends StatelessWidget {
  const ResultBar({
    super.key,
    required this.white,
    required this.draws,
    required this.black,
  });

  final int white;
  final int draws;
  final int black;

  @override
  Widget build(BuildContext context) {
    final total = white + draws + black;
    if (total == 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(Space.xs),
      child: SizedBox(
        height: replyRowHeight - Space.s,
        child: Row(
          children: [
            _part(white, total, resultBarWhite, resultBarBlack),
            _part(draws, total, resultBarDraw, resultBarWhite),
            _part(black, total, resultBarBlack, resultBarWhite),
          ],
        ),
      ),
    );
  }

  Widget _part(int count, int total, Color fill, Color ink) {
    if (count == 0) return const SizedBox.shrink();
    final share = count / total;
    return Expanded(
      flex: (share * 1000).round().clamp(1, 1000),
      child: ColoredBox(
        color: fill,
        child: share >= resultBarLabelFrom
            ? Center(
                child: Text(
                  '${(share * 100).round()}%',
                  style: monoText.copyWith(color: ink),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              )
            : null,
      ),
    );
  }
}

/// One game the database names: the players with their ratings, how it
/// ended and when. Clicking it hands it to the viewer.
class _GameRow extends StatelessWidget {
  const _GameRow({
    super.key,
    required this.game,
    required this.fetching,
    required this.onTap,
  });

  final ExplorerGame game;
  final bool fetching;
  final VoidCallback? onTap;

  String _player(String name, int? elo) => elo == null ? name : '$name ($elo)';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: listRowHeight,
          child: Row(
            children: [
              const SizedBox(width: Space.m),
              Expanded(
                child: Text(
                  '${_player(game.white, game.whiteElo)} – '
                  '${_player(game.black, game.blackElo)}',
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Space.m),
              Text(game.result, style: monoText),
              const SizedBox(width: Space.m),
              SizedBox(
                width: explorerGamesWidth / 2,
                child: Text(
                  fetching ? 'Fetching…' : '${game.year ?? ''}',
                  style: muted,
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: Space.m),
            ],
          ),
        ),
      ),
    );
  }
}
