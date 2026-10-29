import 'package:flutter/material.dart';

import '../../ui/app_keys.dart';
import '../document/document_session.dart';

/// `Read | Edit` at the foot of the card in the PGN Viewer and Study: the
/// one control that turns editing on and off there. Reading keeps what is
/// done on the board off the file until it is saved; editing opens the
/// strip of glyphs and the note, and saves every change as it is made.
class EditSwitch extends StatelessWidget {
  const EditSwitch({super.key, required this.session, required this.editing});

  final DocumentSession session;
  final ValueNotifier<bool> editing;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session, editing]),
    builder: (context, _) => SegmentedButton<bool>(
      segments: [
        const ButtonSegment(
          value: false,
          label: Text('Read'),
          tooltip: 'Read the game: moves played stay off the file',
        ),
        ButtonSegment(
          value: true,
          label: const Text('Edit'),
          tooltip: AppKey.edit.tip('Edit the game: changes save as you go'),
        ),
      ],
      selected: {editing.value},
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelectionChanged: session.chapter == null || session.shownTo != null
          ? null
          : (picked) => editing.value = picked.single,
    ),
  );
}
