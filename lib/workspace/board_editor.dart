import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/position_setup.dart';
import '../ui/theme.dart';
import 'board_view.dart';

/// What a press on the editor's board does.
sealed class EditorTool {
  const EditorTool();
}

/// Pieces are dragged: across the board to move, off it to take away.
final class PointerTool extends EditorTool {
  const PointerTool();
}

/// Every square pressed or stroked across gets [piece].
final class PieceBrush extends EditorTool {
  const PieceBrush(this.piece);

  final Piece piece;

  @override
  bool operator ==(Object other) => other is PieceBrush && other.piece == piece;

  @override
  int get hashCode => piece.hashCode;
}

/// Every square pressed or stroked across is emptied.
final class EraserTool extends EditorTool {
  const EraserTool();
}

/// Setting a chess position up by hand, as Lichess's board editor does.
///
/// A strip of spare pieces above and below the board, each `[pointer] K Q
/// R B N P [bin]`, the far side's on top, so they swap with the flip. A
/// spare piece dragged onto the board lands there; clicked, it becomes a
/// brush that paints every square pressed or stroked across until another
/// tool is picked. A right-click empties a square. Beside the board: the
/// side to move, Start position, Clear board, Flip board, the castling
/// rights the board allows and the en-passant square; under it the FEN,
/// which is the same position as text — typed or pasted, it sets the
/// board as soon as it can be read.
///
/// Nothing is refused while the position is built; [onChanged] hears the
/// position after every change, as a FEN when a game could start from it
/// and null when not, and the editor says why not.
class BoardEditor extends StatefulWidget {
  const BoardEditor({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final Fen initial;
  final ValueChanged<Fen?> onChanged;

  /// How wide the editor is: the board, the gap and the controls.
  static const width = editorBoardSize + Space.l + editorControlsWidth;

  @override
  State<BoardEditor> createState() => _BoardEditorState();
}

class _BoardEditorState extends State<BoardEditor> {
  Setup _setup = Setup.standard;
  late final _fen = TextEditingController(text: _setup.fen);
  EditorTool _tool = const PointerTool();
  Side _bottom = Side.white;

  /// Whether the FEN field holds text no position can be read from.
  bool _unread = false;

  @override
  void initState() {
    super.initState();
    _setup = SetupEdits.read(widget.initial.value) ?? Setup.standard;
  }

  @override
  void dispose() {
    _fen.dispose();
    super.dispose();
  }

  /// Shows [next] on the board and in the FEN field.
  void _set(Setup next) {
    if (!mounted) return;
    setState(() {
      _setup = next;
      _unread = false;
      _fen.text = next.fen;
    });
    _report();
  }

  /// Typed text sets the board once it can be read; until then the board
  /// stays as it was and the text is the problem.
  void _typed(String text) {
    if (!mounted) return;
    final read = SetupEdits.read(text);
    setState(() {
      _unread = read == null;
      if (read != null) _setup = read;
    });
    _report();
  }

  void _report() =>
      widget.onChanged(_unread || _setup.illegal != null ? null : _setup.asFen);

  void _pick(EditorTool tool) {
    if (mounted) setState(() => _tool = tool);
  }

  /// A press or a stroke across [square] with the tool in hand.
  void _paint(Square square) {
    final here = _setup.board.pieceAt(square);
    switch (_tool) {
      case PieceBrush(:final piece) when here != piece:
        _set(_setup.withPiece(square, piece));
      case EraserTool() when here != null:
        _set(_setup.withPiece(square, null));
      case PointerTool() || PieceBrush() || EraserTool():
        break;
    }
  }

  String? get _problem => _unread
      ? 'Could not read that FEN.'
      : switch (_setup.illegal) {
          null => null,
          IllegalSetupCause.empty => 'The board is empty.',
          IllegalSetupCause.kings => 'Each side needs exactly one king.',
          IllegalSetupCause.oppositeCheck =>
            'The side not to move is in check.',
          IllegalSetupCause.impossibleCheck =>
            'No game could reach this check.',
          IllegalSetupCause.pawnsOnBackrank =>
            'Pawns cannot stand on the first or last rank.',
          IllegalSetupCause.variant => 'This is not a chess position.',
        };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: BoardEditor.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  _spares(_bottom.opposite),
                  const SizedBox(height: Space.xs),
                  _board(context),
                  const SizedBox(height: Space.xs),
                  _spares(_bottom),
                ],
              ),
              const SizedBox(width: Space.l),
              Expanded(child: _controls(context)),
            ],
          ),
          const SizedBox(height: Space.m),
          TextField(
            controller: _fen,
            onChanged: _typed,
            style: monoText,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'FEN',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Copy FEN',
                icon: const Icon(Icons.copy, size: IconSize.menu),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _fen.text)),
              ),
            ),
          ),
          // One line held for the reason, so the dialog does not grow
          // and shrink as the position turns legal and back.
          SizedBox(
            height: editorProblemHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _problem ?? '',
                style: TextStyle(color: scheme.error),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _spares(Side side) =>
      _SpareStrip(side: side, tool: _tool, onPick: _pick);

  Widget _board(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.buttons != kSecondaryButton) return;
      final square = squareAt(event.localPosition, editorBoardSize, _bottom);
      if (square != null) _set(_setup.withPiece(square, null));
    },
    child: ChessboardEditor(
      size: editorBoardSize,
      orientation: _bottom,
      pieces: readFen(_setup.board.fen),
      pointerMode: _tool is PointerTool
          ? EditorPointerMode.drag
          : EditorPointerMode.edit,
      settings: BoardTheme.of(context).settings(coordinates: true),
      onEditedSquare: _paint,
      onDroppedPiece: (from, to, piece) => _set(
        from == null ? _setup.withPiece(to, piece) : _setup.withMove(from, to),
      ),
      onDiscardedPiece: (square) => _set(_setup.withPiece(square, null)),
    ),
  );

  Widget _controls(BuildContext context) {
    final label = Theme.of(context).textTheme.labelSmall;
    final passable = _setup.enPassantSquares;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<Side>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: Side.white, label: Text('White to play')),
            ButtonSegment(value: Side.black, label: Text('Black to play')),
          ],
          selected: {_setup.turn},
          onSelectionChanged: (side) => _set(_setup.withTurn(side.first)),
        ),
        const SizedBox(height: Space.m),
        TextButton(
          onPressed: () => _set(Setup.standard),
          child: const Text('Start position'),
        ),
        TextButton(
          onPressed: () => _set(_setup.withBoard(Board.empty)),
          child: const Text('Clear board'),
        ),
        TextButton(
          onPressed: () {
            if (mounted) setState(() => _bottom = _bottom.opposite);
          },
          child: const Text('Flip board'),
        ),
        const SizedBox(height: Space.m),
        Text('Castling', style: label),
        _castling('White', kingside: Square.h1, queenside: Square.a1),
        _castling('Black', kingside: Square.h8, queenside: Square.a8),
        const SizedBox(height: Space.m),
        Text('En passant', style: label),
        const SizedBox(height: Space.xs),
        Wrap(
          spacing: Space.xs,
          children: [
            for (final square in [null, ...passable])
              ChoiceChip(
                label: Text(square?.name ?? 'None'),
                selected: _setup.epSquare == square,
                showCheckmark: false,
                onSelected: (_) => _set(_setup.withEnPassant(square)),
              ),
          ],
        ),
      ],
    );
  }

  /// One side's two castling rights, each offered only while its king and
  /// rook are at home.
  Widget _castling(
    String side, {
    required Square kingside,
    required Square queenside,
  }) => Row(
    children: [
      SizedBox(width: editorSideLabelWidth, child: Text(side)),
      for (final (rook, name) in [(kingside, 'O-O'), (queenside, 'O-O-O')])
        Row(
          children: [
            Checkbox(
              key: ValueKey('castling ${rook.name}'),
              semanticLabel: '$side $name',
              value: _setup.castlingRights.has(rook),
              onChanged: _setup.canCastle(rook)
                  ? (on) => _set(_setup.withCastling(rook, on: on == true))
                  : null,
            ),
            Text(name, style: monoText),
            const SizedBox(width: Space.s),
          ],
        ),
    ],
  );
}

/// One colour's spare pieces between the pointer and the bin, one square
/// wide each.
class _SpareStrip extends StatelessWidget {
  const _SpareStrip({
    required this.side,
    required this.tool,
    required this.onPick,
  });

  final Side side;
  final EditorTool tool;
  final ValueChanged<EditorTool> onPick;

  static const _roles = [
    Role.king,
    Role.queen,
    Role.rook,
    Role.bishop,
    Role.knight,
    Role.pawn,
  ];

  @override
  Widget build(BuildContext context) {
    const size = editorBoardSize / 8;
    final colour = side == Side.white ? 'White' : 'Black';
    return SizedBox(
      width: editorBoardSize,
      height: size,
      child: Row(
        children: [
          _Slot(
            tooltip: 'Move pieces',
            selected: tool is PointerTool,
            onTap: () => onPick(const PointerTool()),
            child: const Icon(Icons.pan_tool_alt_outlined),
          ),
          for (final role in _roles)
            _spare(Piece(color: side, role: role), '$colour ${role.name}'),
          _Slot(
            tooltip: 'Erase pieces',
            selected: tool is EraserTool,
            onTap: () => onPick(const EraserTool()),
            child: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  /// Clicked, the piece is the brush, or clicked again the pointer; dragged,
  /// it is put down where it is dropped and the tool stays.
  Widget _spare(Piece piece, String name) {
    const size = editorBoardSize / 8;
    final brush = PieceBrush(piece);
    final image = PieceWidget(
      piece: piece,
      size: size,
      pieceAssets: PieceSet.cburnettAssets,
    );
    return _Slot(
      tooltip: name,
      selected: tool == brush,
      onTap: () => onPick(tool == brush ? const PointerTool() : brush),
      child: Draggable<Piece>(
        data: piece,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Transform.translate(
          offset: const Offset(-size / 2, -size / 2),
          child: image,
        ),
        child: image,
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(Space.xs),
          child: InkWell(
            borderRadius: BorderRadius.circular(Space.xs),
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// Asks for a position set up on the board editor, starting from
/// [initial]; answers it, or null when the user backed out. `Use this
/// position` waits until a game could start from what is on the board.
Future<Fen?> showBoardEditor(
  BuildContext context, {
  required Fen initial,
  String title = 'Set up a position',
}) => showDialog<Fen>(
  context: context,
  builder: (_) => _BoardEditorDialog(initial: initial, title: title),
);

class _BoardEditorDialog extends StatefulWidget {
  const _BoardEditorDialog({required this.initial, required this.title});

  final Fen initial;
  final String title;

  @override
  State<_BoardEditorDialog> createState() => _BoardEditorDialogState();
}

class _BoardEditorDialogState extends State<_BoardEditorDialog> {
  Fen? _position;

  @override
  void initState() {
    super.initState();
    _position = playableFen(widget.initial.value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: BoardEditor(
        initial: widget.initial,
        onChanged: (fen) {
          if (mounted) setState(() => _position = fen);
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _position == null
            ? null
            : () => Navigator.pop(context, _position),
        child: const Text('Use this position'),
      ),
    ],
  );
}
