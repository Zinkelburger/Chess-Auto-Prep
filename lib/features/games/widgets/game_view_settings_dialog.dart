import 'package:flutter/material.dart';
import '../../../widgets/analysis/analysis_panels_dialog.dart';

import '../../../core/pgn_viewer_controller.dart' show Perspective;
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_shortcuts.dart';
import '../../../widgets/game_nav_bar.dart' show kAutoPlaySpeeds;
import '../../../widgets/settings/settings_widgets.dart';
import '../../../widgets/settings/settings_navigation.dart';
import '../../../widgets/shortcut_tooltip.dart';
import '../models/game_view_preferences.dart';

/// Per-view preferences use the same groups and controls as global settings.
class GameViewSettingsDialog extends StatefulWidget {
  const GameViewSettingsDialog({
    super.key,
    required this.preferences,
    required this.onChanged,
    this.perspective = const Perspective(),
    required this.onFlip,
    required this.onPerspective,
    this.player,
    this.onReadingOptions,
    this.onFullscreen,
    this.embedded = false,
  });

  final bool embedded;
  final GameViewPreferences preferences;
  final Perspective perspective;
  final ValueChanged<GameViewPreferences> onChanged;
  final VoidCallback onFlip;
  final ValueChanged<Perspective> onPerspective;
  final String? player;
  final VoidCallback? onReadingOptions;
  final VoidCallback? onFullscreen;

  @override
  State<GameViewSettingsDialog> createState() => _GameViewSettingsDialogState();
}

class _GameViewSettingsDialogState extends State<GameViewSettingsDialog> {
  late GameViewPreferences _prefs = widget.preferences;
  late String _orientation = widget.perspective.toHeaderValue();

  void _update(GameViewPreferences value) {
    if (!mounted) return;
    setState(() => _prefs = value);
    widget.onChanged(value);
  }

  Widget _action(String label, VoidCallback? action, {AppShortcut? shortcut}) {
    final tile = ListTile(
      dense: true,
      title: Text(label, style: AppTextStyles.body),
      trailing: shortcut == null || !shortcut.isAssigned
          ? null
          : Text(shortcut.label, style: AppTextStyles.caption),
      onTap: action == null
          ? null
          : () {
              Navigator.pop(context);
              action();
            },
    );
    return shortcut == null
        ? tile
        : ShortcutTooltip(description: label, shortcut: shortcut, child: tile);
  }

  @override
  Widget build(BuildContext context) {
    final content = _content();
    if (widget.embedded) {
      return Padding(padding: const EdgeInsets.all(24), child: content);
    }
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Game view')),
          ShortcutIconButton(
            description: 'Close game view settings',
            shortcut: AppShortcut.leave,
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      content: SizedBox(width: 560, child: content),
    );
  }

  Widget _content() => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (SettingsChapterScope.maybeOf(context) == 2)
          const AnalysisPanelsSettingsBody(),
        if (SettingsChapterScope.maybeOf(context) == null ||
            SettingsChapterScope.maybeOf(context) == 0)
          SettingsGroup(
            title: 'Playback',
            icon: Icons.play_arrow_outlined,
            children: [
              SettingsSwitchTile(
                label: 'Playback controls',
                description:
                    'Show controls for stepping through or automatically playing moves.',
                value: _prefs.playback,
                onChanged: (v) => _update(_prefs.copyWith(playback: v)),
              ),
              if (_prefs.playback) ...[
                SettingsChoiceTile<double>(
                  label: 'Speed',
                  value: _prefs.speed,
                  items: [
                    (_prefs.speed, '${_prefs.speed}s per move'),
                    for (final speed in kAutoPlaySpeeds)
                      if (speed != _prefs.speed) (speed, '${speed}s per move'),
                  ],
                  onChanged: (v) => _update(_prefs.copyWith(speed: v)),
                ),
                SettingsSwitchTile(
                  label: 'Continue to next game',
                  description:
                      'At the final move, start playing the next game in this collection.',
                  value: _prefs.autoNext,
                  onChanged: (v) => _update(_prefs.copyWith(autoNext: v)),
                ),
              ],
            ],
          ),
        if (SettingsChapterScope.maybeOf(context) == null ||
            SettingsChapterScope.maybeOf(context) == 1)
          SettingsGroup(
            title: 'Board and moves',
            icon: Icons.grid_on_outlined,
            children: [
              SettingsSwitchTile(
                label: 'Autosave PGN edits',
                description:
                    'Save comments and variations automatically. Turn off to use the Save button.',
                value: _prefs.autoSave,
                onChanged: (v) => _update(_prefs.copyWith(autoSave: v)),
              ),
              SettingsSwitchTile(
                label: 'Auto-detect ECO and opening',
                description:
                    'Identify openings in every game and save missing ECO and Opening tags to the PGN. Existing tags are kept.',
                value: _prefs.autoDetectOpenings,
                onChanged: (v) =>
                    _update(_prefs.copyWith(autoDetectOpenings: v)),
              ),
              _action('Move list…', widget.onReadingOptions),
              _action(
                'Flip board',
                widget.onFlip,
                shortcut: AppShortcut.flipBoard,
              ),
              SettingsChoiceTile<String>(
                label: 'Board orientation',
                value: _orientation,
                items: [
                  ('white', 'Always White'),
                  ('black', 'Always Black'),
                  if (widget.player case final player?)
                    (player, 'Follow $player'),
                  if (_orientation != 'white' &&
                      _orientation != 'black' &&
                      _orientation != widget.player)
                    (_orientation, 'Follow $_orientation'),
                ],
                onChanged: (value) {
                  if (!mounted) return;
                  setState(() => _orientation = value);
                  widget.onPerspective(Perspective.fromHeaderValue(value));
                },
              ),
              _action(
                'Fullscreen',
                widget.onFullscreen,
                shortcut: AppShortcut.fullScreen,
              ),
            ],
          ),
        TextButton(
          onPressed: () => _update(const GameViewPreferences()),
          child: const Text('Restore simple defaults'),
        ),
      ],
    ),
  );
}
