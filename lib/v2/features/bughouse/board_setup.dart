import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_setup.dart';
import '../../ui/listening_state.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';

/// The boxes under the boards that set a table up by hand: each board's
/// FEN and the two players' reserves on it, a line of the pieces still to
/// place, and `Set position`. The boxes follow the table as it is played;
/// what the user types stays until they set it or the table moves on. A
/// dual FEN pasted into either FEN box fills both boards.
class BoardSetup extends StatefulWidget {
  const BoardSetup({super.key, required this.lab, required this.boardSize});

  final BughouseLab lab;
  final double boardSize;

  @override
  State<BoardSetup> createState() => _BoardSetupState();
}

typedef _Fields = ({
  TextEditingController fen,
  TextEditingController white,
  TextEditingController black,
});

class _BoardSetupState extends State<BoardSetup>
    with ListeningState<BoardSetup> {
  late final Map<BoardNumber, _Fields> _fields = {
    for (final board in BoardNumber.values)
      board: (
        fen: TextEditingController(),
        white: TextEditingController(),
        black: TextEditingController(),
      ),
  };
  TablePosition? _shown;

  @override
  Listenable listenableOf(BoardSetup widget) => widget.lab;

  @override
  void initState() {
    super.initState();
    _fill();
  }

  /// A new table on the boards refills the boxes; a chip or a hover does
  /// not touch what the user is typing.
  @override
  void changed() {
    if (!identical(widget.lab.position, _shown)) _fill();
    setState(() {});
  }

  void _fill() {
    final position = _shown = widget.lab.position;
    for (final board in BoardNumber.values) {
      final boxes = boxesOf(position, board);
      final fields = _fields[board]!;
      fields.fen.text = boxes.fen;
      fields.white.text = boxes.white;
      fields.black.text = boxes.black;
    }
  }

  BoardBoxes _boxes(BoardNumber board) {
    final fields = _fields[board]!;
    return (
      fen: fields.fen.text,
      white: fields.white.text,
      black: fields.black.text,
    );
  }

  void _set() {
    for (final board in BoardNumber.values) {
      final pasted = _fields[board]!.fen.text;
      if (pasted.contains('|')) return widget.lab.loadDualFen(pasted);
    }
    widget.lab.setPosition(_boxes(BoardNumber.one), _boxes(BoardNumber.two));
  }

  @override
  void dispose() {
    for (final fields in _fields.values) {
      fields.fen.dispose();
      fields.white.dispose();
      fields.black.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problems = widget.lab.setupProblems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final board in BoardNumber.values) ...[
              if (board == BoardNumber.two) const SizedBox(width: labBoardGap),
              SizedBox(
                width: widget.boardSize,
                child: _BoardBoxes(
                  board: board,
                  fields: _fields[board]!,
                  problem: problems[board],
                  onChanged: () => setState(() {}),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: Space.s),
        SizedBox(
          width: widget.boardSize * 2 + labBoardGap,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  outstanding(_boxes(BoardNumber.one), _boxes(BoardNumber.two)),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Space.s),
              OutlinedButton(
                onPressed: _set,
                child: const Text('Set position'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BoardBoxes extends StatelessWidget {
  const _BoardBoxes({
    required this.board,
    required this.fields,
    required this.problem,
    required this.onChanged,
  });

  final BoardNumber board;
  final _Fields fields;
  final String? problem;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _box(
          fields.fen,
          '${board.label} FEN',
          onChanged,
          key: ValueKey(('fen', board)),
        ),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            for (final side in Side.values) ...[
              if (side == Side.black) const SizedBox(width: Space.s),
              Text(
                Seat.of(board, side).letter,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: _box(
                  side == Side.white ? fields.white : fields.black,
                  'Player ${Seat.of(board, side).letter}’s reserve',
                  onChanged,
                ),
              ),
            ],
          ],
        ),
        if (problem case final problem?)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(problem, style: TextStyle(color: scheme.error)),
          ),
      ],
    );
  }

  static Widget _box(
    TextEditingController controller,
    String label,
    VoidCallback onChanged, {
    Key? key,
  }) => Semantics(
    label: label,
    child: TextField(
      key: key,
      controller: controller,
      style: labSetupText,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: (_) => onChanged(),
      // Clicked away from, the focus goes back to where it was before —
      // the lab — rather than up to the window, where no key reaches it.
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(
        disposition: UnfocusDisposition.previouslyFocusedChild,
      ),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(
          horizontal: Space.s,
          vertical: Space.s,
        ),
      ),
    ),
  );
}
