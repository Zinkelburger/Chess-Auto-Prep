import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../ui/name_dialog.dart';
import '../../ui/theme.dart';

/// What the user asked for: a name, where the chapter starts, and which way
/// its board faces.
typedef NewChapter = ({String name, Fen root, Side? orientation});

/// Asks for a new chapter, or answers null when the user backed out.
///
/// The starting position and the orientation are asked for here because both
/// are written into the chapter as it is created: a chapter set up from a
/// FEN has no moves to work either of them out from later.
Future<NewChapter?> showNewChapterDialog(
  BuildContext context, {
  required String suggested,
}) async {
  var start = _Start.initial;
  var orientation = _Facing.automatic;
  final fen = TextEditingController();
  try {
    final name = await showNameDialog(
      context,
      title: 'New chapter',
      label: 'Chapter name',
      initial: suggested,
      confirm: 'Create',
      extra: (context, changed) => _Options(
        start: start,
        facing: orientation,
        fen: fen,
        onStart: (chosen) {
          start = chosen;
          changed();
        },
        onFacing: (chosen) {
          orientation = chosen;
          changed();
        },
      ),
    );
    if (name == null) return null;
    return (
      name: name,
      root: start == _Start.initial ? Fen.initial : Fen(fen.text.trim()),
      orientation: orientation.side,
    );
  } finally {
    fen.dispose();
  }
}

enum _Start { initial, position }

enum _Facing {
  automatic(null),
  white(Side.white),
  black(Side.black);

  const _Facing(this.side);

  /// Null means the chapter takes the side to move in its starting position,
  /// which is what a problem set up from a FEN wants.
  final Side? side;
}

class _Options extends StatelessWidget {
  const _Options({
    required this.start,
    required this.facing,
    required this.fen,
    required this.onStart,
    required this.onFacing,
  });

  final _Start start;
  final _Facing facing;
  final TextEditingController fen;
  final ValueChanged<_Start> onStart;
  final ValueChanged<_Facing> onFacing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Start from', style: text.labelSmall),
        const SizedBox(height: Space.xs),
        SegmentedButton<_Start>(
          segments: const [
            ButtonSegment(value: _Start.initial, label: Text('Initial')),
            ButtonSegment(value: _Start.position, label: Text('Position')),
          ],
          selected: {start},
          onSelectionChanged: (chosen) => onStart(chosen.first),
        ),
        if (start == _Start.position) ...[
          const SizedBox(height: Space.s),
          TextField(
            controller: fen,
            style: monoText,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'FEN',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: Space.l),
        Text('Orientation', style: text.labelSmall),
        const SizedBox(height: Space.xs),
        SegmentedButton<_Facing>(
          segments: const [
            ButtonSegment(value: _Facing.automatic, label: Text('Automatic')),
            ButtonSegment(value: _Facing.white, label: Text('White')),
            ButtonSegment(value: _Facing.black, label: Text('Black')),
          ],
          selected: {facing},
          onSelectionChanged: (chosen) => onFacing(chosen.first),
        ),
      ],
    );
  }
}
