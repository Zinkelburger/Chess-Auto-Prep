import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../ui/name_dialog.dart';
import '../../ui/theme.dart';

/// What the user asked for: a name and the side the repertoire is for.
typedef NewRepertoire = ({String name, Side side});

/// Asks for a new repertoire, or answers null when the user backed out.
///
/// The side is asked for here rather than later because it is written into
/// the chapter file as it is created, and a chapter with no moves has nothing
/// else to say which side it belongs to. It rides along under the shared name
/// dialog's field, which owns the name, its validation and the buttons.
Future<NewRepertoire?> showNewRepertoireDialog(BuildContext context) async {
  var side = Side.white;
  final name = await showNameDialog(
    context,
    title: 'Create repertoire',
    label: 'Repertoire name',
    hint: 'My Sicilian',
    confirm: 'Create',
    extra: (context, changed) => _SidePicker(
      side: side,
      onChanged: (chosen) {
        side = chosen;
        changed();
      },
    ),
  );
  return name == null ? null : (name: name, side: side);
}

class _SidePicker extends StatelessWidget {
  const _SidePicker({required this.side, required this.onChanged});

  final Side side;
  final ValueChanged<Side> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Playing side', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: Space.xs),
        SegmentedButton<Side>(
          segments: const [
            ButtonSegment(value: Side.white, label: Text('White')),
            ButtonSegment(value: Side.black, label: Text('Black')),
          ],
          selected: {side},
          onSelectionChanged: (chosen) => onChanged(chosen.first),
        ),
      ],
    );
  }
}
