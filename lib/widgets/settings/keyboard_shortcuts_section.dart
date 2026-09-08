import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_shortcuts.dart';
import '../../utils/shortcut_reference.dart';
import 'settings_widgets.dart';

class KeyboardShortcutsSection extends StatelessWidget {
  const KeyboardShortcutsSection({super.key});

  Widget _row(String action, String keys) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(action, style: AppTextStyles.body)),
        const SizedBox(width: 16),
        Text(keys, style: AppTextStyles.mono),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 20),
        child: Text(
          'Shortcuts act on the current view. Text fields keep their normal editing keys; move inputs also allow navigation keys. Hover a control to see its shortcut.',
          style: AppTextStyles.muted,
        ),
      ),
      SettingsGroup(
        title: 'Switch view',
        icon: Icons.apps,
        children: [
          for (final mode in availableModeMenuOrder())
            _row(
              mode.label,
              KeyChord(
                AppShortcut.candidateKeys[mode.shortcutNumber - 1],
                control: true,
              ).label,
            ),
        ],
      ),
      for (final group in shortcutReference.map((e) => e.group).toSet())
        SettingsGroup(
          title: group,
          icon: Icons.keyboard_outlined,
          children: [
            for (final entry in shortcutReference.where(
              (e) => e.group == group,
            ))
              _row(entry.description, entry.shortcut.label),
            if (group == 'Game reader')
              _row(
                'Choose the numbered continuation at a fork',
                '${AppShortcut.forkCandidates.first.label}–${AppShortcut.forkCandidates.last.label}',
              ),
          ],
        ),
      SettingsGroup(
        title: 'Repertoire planner',
        icon: Icons.route_outlined,
        children: [
          _row('Undo start move or leave preview / redo start move', '← / →'),
          _row('Begin or continue', 'Enter'),
          _row('Previous question', 'Backspace'),
          _row('Stop here', 'G'),
          _row('Select numbered answer', '1–9'),
        ],
      ),
      SettingsGroup(
        title: 'Bughouse',
        icon: Icons.grid_on_outlined,
        children: [
          _row('Previous / next ply', '← / →'),
          _row('Start / end', 'Home / End'),
          _row('Flip board A / board B', 'F / G'),
          _row('Toggle analysis', 'Space'),
        ],
      ),
    ],
  );
}
