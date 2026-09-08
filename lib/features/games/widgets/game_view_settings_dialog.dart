import 'package:flutter/material.dart';

import '../../../core/pgn_viewer_controller.dart'
    show Perspective, PerspectiveMode;
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_shortcuts.dart';
import '../../../widgets/game_nav_bar.dart' show kAutoPlaySpeeds;
import '../../../widgets/settings/settings_widgets.dart';
import '../../../widgets/shortcut_tooltip.dart';
import '../models/game_view_preferences.dart';

/// Per-view preferences use the same groups and controls as global settings.
class GameViewSettingsDialog extends StatefulWidget {
  const GameViewSettingsDialog({
    super.key,
    required this.preferences,
    required this.onChanged,
    required this.onFlip,
    required this.onPerspective,
    this.player,
    this.onReadingOptions,
    this.onFullscreen,
  });

  final GameViewPreferences preferences;
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

  void _update(GameViewPreferences value) {
    if (!mounted) return;
    setState(() => _prefs = value);
    widget.onChanged(value);
  }

  Widget _action(String label, VoidCallback? action, {AppShortcut? shortcut}) =>
      ListTile(
        dense: true,
        title: Text(label, style: AppTextStyles.body),
        trailing: shortcut == null
            ? null
            : Text(shortcut.label, style: AppTextStyles.caption),
        onTap: action == null
            ? null
            : () {
                Navigator.pop(context);
                action();
              },
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
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
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsGroup(
              title: 'Analysis',
              icon: Icons.analytics_outlined,
              children: [
                SettingsSwitchTile(
                  label: 'Analysis overview',
                  value: _prefs.graph,
                  onChanged: (v) => _update(_prefs.copyWith(graph: v)),
                ),
                SettingsSwitchTile(
                  label: 'Live engine controls',
                  value: _prefs.engine,
                  onChanged: (v) => _update(_prefs.copyWith(engine: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Playback',
              icon: Icons.play_arrow_outlined,
              children: [
                SettingsSwitchTile(
                  label: 'Playback controls',
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
                        if (speed != _prefs.speed)
                          (speed, '${speed}s per move'),
                    ],
                    onChanged: (v) => _update(_prefs.copyWith(speed: v)),
                  ),
                  SettingsSwitchTile(
                    label: 'Continue to next game',
                    value: _prefs.autoNext,
                    onChanged: (v) => _update(_prefs.copyWith(autoNext: v)),
                  ),
                ],
              ],
            ),
            SettingsGroup(
              title: 'Board and moves',
              icon: Icons.grid_on_outlined,
              children: [
                _action('Move list…', widget.onReadingOptions),
                _action(
                  'Flip board',
                  widget.onFlip,
                  shortcut: AppShortcut.flipBoard,
                ),
                _action(
                  'Always view as White',
                  () => widget.onPerspective(
                    const Perspective(mode: PerspectiveMode.white),
                  ),
                ),
                _action(
                  'Always view as Black',
                  () => widget.onPerspective(
                    const Perspective(mode: PerspectiveMode.black),
                  ),
                ),
                if (widget.player case final player?)
                  _action(
                    'Follow $player',
                    () => widget.onPerspective(
                      Perspective(
                        mode: PerspectiveMode.player,
                        playerName: player,
                      ),
                    ),
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
      ),
    ),
  );
}
