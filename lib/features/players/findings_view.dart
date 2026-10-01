import 'package:flutter/material.dart';

import '../../ui/check_row.dart';
import '../../ui/field_row.dart';
import '../../ui/move_notation.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import 'player_analysis.dart';
import 'player_hunt.dart';

/// The top of the Findings list: the button that runs the engine over the
/// player's most played positions, its settings folded beside it, how far
/// the run is, and the findings put aside.
class EngineRun extends StatefulWidget {
  const EngineRun({
    super.key,
    required this.analysis,
    required this.hunt,
    required this.dismissed,
    required this.showDismissed,
    required this.onShowDismissed,
  });

  final PlayerAnalysis analysis;
  final PlayerHunt hunt;

  /// How many findings are put aside, and whether the list shows those.
  final int dismissed;
  final bool showDismissed;
  final ValueChanged<bool> onShowDismissed;

  @override
  State<EngineRun> createState() => _EngineRunState();
}

class _EngineRunState extends State<EngineRun> {
  bool _settingsOpen = false;

  void _toggleSettings() {
    if (mounted) setState(() => _settingsOpen = !_settingsOpen);
  }

  @override
  Widget build(BuildContext context) {
    final hunt = widget.hunt;
    final theme = Theme.of(context);
    final wrong = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.xs, Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _controls(hunt),
          if (_settingsOpen)
            Padding(
              padding: const EdgeInsets.only(right: Space.s),
              child: _EngineFields(hunt: hunt),
            ),
          if (hunt.running) ...[
            const SizedBox(height: Space.s),
            Padding(
              padding: const EdgeInsets.only(right: Space.s),
              child: LinearProgressIndicator(
                minHeight: progressLineHeight,
                value: hunt.total == 0 ? null : hunt.done / hunt.total,
              ),
            ),
          ],
          if (hunt.practicalWarning case final warning?)
            Text(warning, style: theme.textTheme.bodySmall),
          if (hunt.error case final error?) Text(error, style: wrong),
          _summary(hunt, theme),
        ],
      ),
    );
  }

  Widget _controls(PlayerHunt hunt) => Row(
    children: [
      Expanded(
        child: Tooltip(
          message:
              'Check the most played positions for bad evaluations and '
              'strong replies these games never met. Scores are from the '
              'player’s side.',
          child: FilledButton(
            onPressed: widget.analysis.busy
                ? null
                : hunt.running
                ? hunt.stop
                : hunt.start,
            child: Text(
              hunt.running
                  ? 'Stop · ${hunt.done} / ${hunt.total}'
                  : 'Analyze with engine',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
      // The gear the engine under the board has, for the same thing: how
      // hard this engine looks.
      IconButton(
        onPressed: _toggleSettings,
        isSelected: _settingsOpen,
        icon: const Icon(Icons.settings, size: IconSize.action),
        tooltip: _settingsOpen
            ? 'Hide the analysis settings'
            : 'Analysis settings',
      ),
    ],
  );

  /// What the last run came to, and the way to the findings put aside.
  /// Before any run, what the button looks for.
  Widget _summary(PlayerHunt hunt, ThemeData theme) {
    if (hunt.findings.isEmpty) {
      final words = hunt.running
          ? ''
          : hunt.total > 0
          ? '${hunt.done} positions checked · no findings'
          : 'Finds positions this player handles badly, and strong replies '
                'their opponents never tried.';
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, Space.s, Space.s, Space.xs),
        child: Text(words, style: theme.textTheme.labelSmall),
      );
    }
    final found = hunt.findings.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            hunt.running
                ? '$found ${found == 1 ? 'finding' : 'findings'} so far'
                : '${hunt.done} positions checked · '
                      '$found ${found == 1 ? 'finding' : 'findings'}',
            style: theme.textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: widget.dismissed == 0 && !widget.showDismissed
              ? null
              : () => widget.onShowDismissed(!widget.showDismissed),
          child: Text(
            widget.showDismissed
                ? 'Back to findings'
                : 'Dismissed (${widget.dismissed})',
          ),
        ),
      ],
    );
  }
}

/// The settings of the next run. Nothing here changes while one is going.
class _EngineFields extends StatelessWidget {
  const _EngineFields({required this.hunt});

  final PlayerHunt hunt;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FieldRow(
        label: 'Depth',
        child: NumberField(
          label: 'Depth',
          value: hunt.depth,
          min: 8,
          max: 30,
          onChanged: (v) => hunt.configure(depth: v),
        ),
      ),
      FieldRow(
        label: 'Positions to check',
        tooltip: 'The most played positions are checked first.',
        child: NumberField(
          label: 'Positions to check',
          value: hunt.limit,
          min: 1,
          max: 1000,
          step: 25,
          onChanged: (v) => hunt.configure(limit: v),
        ),
      ),
      if (hunt.model == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Text(
            'Practical chances need the Maia model, which is not installed.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        )
      else
        CheckRow(
          label: 'Include practical chances',
          tooltip:
              'Uses Maia to estimate the replies a player of this rating '
              'is likely to find.',
          value: hunt.practical,
          onChanged: hunt.running
              ? null
              : (on) => hunt.configure(practical: on),
        ),
      if (hunt.practical) ...[
        FieldRow(
          label: 'Player rating',
          child: NumberField(
            label: 'Player rating',
            value: hunt.rating,
            min: 400,
            max: 3000,
            step: 100,
            onChanged: (v) => hunt.configure(rating: v),
          ),
        ),
        FieldRow(
          label: 'Positions to probe',
          child: NumberField(
            label: 'Positions to probe',
            value: hunt.probes,
            min: 1,
            max: 100,
            onChanged: (v) => hunt.configure(probes: v),
          ),
        ),
      ],
    ],
  );
}

/// One finding: what kind it is and the engine's score from the player's
/// side, the moves to the position, then how many games reached it and the
/// reply that punishes it.
class FindingRow extends StatelessWidget {
  const FindingRow({
    super.key,
    required this.finding,
    required this.dismissed,
    required this.onOpen,
    required this.onToggle,
  });

  final PlayerWeakness finding;

  /// Whether this is a finding put aside, which the button brings back.
  final bool dismissed;
  final VoidCallback onOpen;

  /// Puts the finding aside or brings it back; null while a save is going.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final games = finding.position.count;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, 0, Space.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title(theme),
                  Text(
                    displaySan(
                      context,
                      finding.position.label,
                    ).replaceAll('. ', '.\u00A0'),
                    style: monoText.copyWith(color: scheme.onSurface),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    displaySan(
                      context,
                      '$games ${games == 1 ? 'game' : 'games'} · '
                      '${finding.continuation}',
                    ),
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: dismissed ? 'Restore finding' : 'Dismiss finding',
              icon: Icon(
                dismissed ? Icons.undo : Icons.close,
                size: IconSize.menu,
              ),
              onPressed: onToggle,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _title(ThemeData theme) => Row(
    children: [
      Flexible(
        child: Text(
          finding.title,
          style: theme.textTheme.labelSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(width: Space.s),
      Text(
        finding.score.text,
        style: monoText.copyWith(color: theme.colorScheme.onSurface),
      ),
    ],
  );
}
