import 'package:flutter/material.dart';

import '../../../models/engine_settings.dart';
import '../../../services/games_library/game_filter.dart';
import '../../../services/tactics/mining_settings.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/system_info.dart';
import '../../../widgets/labeled_toggle.dart';
import '../controllers/recent_games_controller.dart';

/// What the user chose, handed back to the pane so one Apply produces one
/// reload.
class HomeReviewSettingsResult {
  const HomeReviewSettingsResult({required this.filters});

  final GamesListFilters filters;
}

/// The dialog behind the review strip's gear — the only one there is. Which
/// time controls count as "my games", and how hard the engine is allowed to
/// work. Whether the analysis starts by itself is not here: that checkbox sits
/// on the strip next to the refresh and gear buttons, in plain sight.
///
/// Titled "Analysis settings", matching its button: "Review settings" was a
/// third thing called a review, next to Opening review and the analysis run.
///
/// Cores and depth used to be a second button on the same strip, labelled
/// "Review speed…", which read as a different feature rather than as the same
/// settings. They are a section here now; the strip still *states* both numbers
/// on its engine-load row, because how much of the laptop goes away is
/// something to see without opening anything.
///
/// Both are shared, not local to this screen: cores is the app-wide
/// [EngineSettings.workers] (the same number the Settings screen shows) and
/// depth is [MiningSettings.depth]. Turning either down here turns it down
/// everywhere.
///
/// Deliberately absent, each because it is already on screen:
///
/// * **Usernames and how many games count as recent** — the accounts card in
///   the right-hand pane, always visible. This dialog used to carry a second
///   copy of both, which is how a screen ends up feeling like nothing but
///   menus: four sections here, two of them duplicates of what you can see
///   without opening anything.
/// * **How long mined puzzles stay trainable** — that is puzzle expiry, and it
///   lives on the Tactics card's Filters dialog next to the queue it governs.
class HomeReviewSettingsDialog extends StatefulWidget {
  const HomeReviewSettingsDialog({super.key, required this.filters});

  final GamesListFilters filters;

  @override
  State<HomeReviewSettingsDialog> createState() =>
      _HomeReviewSettingsDialogState();
}

class _HomeReviewSettingsDialogState extends State<HomeReviewSettingsDialog> {
  late Set<GameSpeed> _speeds;
  late final TextEditingController _cores;
  late final TextEditingController _depth;
  final int _maxCores = getLogicalCores();

  static const _speedLabels = {
    GameSpeed.ultraBullet: 'UltraBullet',
    GameSpeed.bullet: 'Bullet',
    GameSpeed.blitz: 'Blitz',
    GameSpeed.rapid: 'Rapid',
    GameSpeed.classical: 'Classical',
    GameSpeed.correspondence: 'Correspondence',
  };

  @override
  void initState() {
    super.initState();
    _speeds = {...widget.filters.speeds};
    _cores = TextEditingController(text: '${EngineSettings.instance.workers}');
    _depth = TextEditingController(text: '${MiningSettings.instance.depth}');
  }

  @override
  void dispose() {
    _cores.dispose();
    _depth.dispose();
    super.dispose();
  }

  /// Out-of-range and unparseable input is clamped rather than rejected: a
  /// dialog that refuses to close over a typo in a box you can see is worse
  /// than one that quietly puts the number back in range.
  void _apply() {
    final cores = int.tryParse(_cores.text.trim());
    if (cores != null) {
      EngineSettings.instance.workers = cores.clamp(1, _maxCores);
    }
    final depth = int.tryParse(_depth.text.trim());
    if (depth != null) {
      MiningSettings.instance.setDepth(
        depth.clamp(MiningSettings.minDepth, MiningSettings.maxDepth),
      );
    }
    // Auto-start is edited on the strip, not here — pass it through untouched.
    Navigator.of(context).pop(
      HomeReviewSettingsResult(
        filters: widget.filters.copyWith(speeds: _speeds),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Analysis settings'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('Time controls to download'),
              for (final entry in _speedLabels.entries)
                AppCheckbox(
                  label: entry.value,
                  value: _speeds.contains(entry.key),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _speeds.add(entry.key);
                    } else {
                      _speeds.remove(entry.key);
                    }
                  }),
                ),
              _label('How hard it works'),
              _numberField(
                key: const Key('review-cores-field'),
                controller: _cores,
                label: 'CPU cores to use',
                hint:
                    'Between 1 and $_maxCores on this machine. More cores '
                    'analyse your games faster; fewer leave the machine usable '
                    'while it runs.',
              ),
              const SizedBox(height: 14),
              _numberField(
                key: const Key('review-depth-field'),
                controller: _depth,
                label: 'Engine depth',
                hint:
                    'Between ${MiningSettings.minDepth} and '
                    '${MiningSettings.maxDepth}. Deeper is more accurate about '
                    'what was really a mistake, and slower.',
              ),
              const SizedBox(height: 14),
              Text(
                'An analysis already running keeps the settings it started with; '
                'these apply to the next game it picks up.',
                style: AppTextStyles.body.copyWith(
                  fontSize: 11,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }

  /// A number box with its label on its own line: the box holds two digits, and
  /// a floating `labelText` would be clipped to that width.
  Widget _numberField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 96,
          child: TextField(
            key: key,
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: AppTextStyles.body.copyWith(
            fontSize: 11.5,
            color: AppColors.onSurfaceMuted,
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      text,
      style: AppTextStyles.body.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: AppColors.onSurfaceMuted,
      ),
    ),
  );
}
