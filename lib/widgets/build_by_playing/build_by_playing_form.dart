/// Start form for a Build-by-Playing session. Small modal — the session
/// itself lives inline in the repertoire screen; this only collects the
/// database source, starting point, and (behind Advanced) branching knobs.
library;

import 'package:flutter/material.dart';

import '../../constants/chess_constants.dart';
import '../../features/coverage/services/coverage_service.dart';
import '../../services/build_by_playing/build_by_playing_config.dart';
import '../lichess_db_selector.dart';
import '../starting_position_card.dart';

/// Show the form; resolves to the chosen config, or null if cancelled.
///
/// [atRoot] means the board already sits on the repertoire root, so the
/// start-from choice is moot and the toggle is disabled. When the board is
/// elsewhere, the toggle defaults to "From current position" — a position
/// the user deliberately set up must never be discarded silently.
///
/// [rootFen]/[rootMoveSans] describe the repertoire's saved root position
/// (the `// Root:` header; the starting position when none is saved).
/// [currentFen]/[currentMoveSans] describe the board position. Both feed the
/// starting-position preview so the user sees exactly where the session will
/// begin. Pass rootFen as null to hide the whole start-from section
/// (mid-session settings, where the session start is already fixed).
Future<BuildByPlayingConfig?> showBuildByPlayingForm(
  BuildContext context, {
  required BuildByPlayingConfig initial,
  required bool atRoot,
  String? rootFen,
  List<String> rootMoveSans = const [],
  String? currentFen,
  List<String> currentMoveSans = const [],
  bool boardFlipped = false,
}) {
  return showDialog<BuildByPlayingConfig>(
    context: context,
    builder: (_) => _BuildByPlayingDialog(
      initial: initial,
      atRoot: atRoot,
      rootFen: rootFen,
      rootMoveSans: rootMoveSans,
      currentFen: currentFen,
      currentMoveSans: currentMoveSans,
      boardFlipped: boardFlipped,
    ),
  );
}

class _BuildByPlayingDialog extends StatefulWidget {
  const _BuildByPlayingDialog({
    required this.initial,
    required this.atRoot,
    required this.rootFen,
    required this.rootMoveSans,
    required this.currentFen,
    required this.currentMoveSans,
    required this.boardFlipped,
  });

  final BuildByPlayingConfig initial;
  final bool atRoot;
  final String? rootFen;
  final List<String> rootMoveSans;
  final String? currentFen;
  final List<String> currentMoveSans;
  final bool boardFlipped;

  @override
  State<_BuildByPlayingDialog> createState() => _BuildByPlayingDialogState();
}

class _BuildByPlayingDialogState extends State<_BuildByPlayingDialog> {
  late bool _useMasters = widget.initial.useMasters;
  late Set<String> _speeds = widget.initial.speeds
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  late Set<String> _ratings = widget.initial.ratings
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  // Default to the position the user set up on the board; "from repertoire
  // root" is the explicit opt-out, never a silent reset.
  late bool _fromCurrentPosition = !widget.atRoot;

  late final TextEditingController _coverMinProbCtrl = TextEditingController(
      text: (widget.initial.coverMinProb * 100).toStringAsFixed(0));
  late final TextEditingController _oppMassTargetCtrl = TextEditingController(
      text: (widget.initial.oppMassTarget * 100).toStringAsFixed(0));
  late final TextEditingController _oppMaxChildrenCtrl =
      TextEditingController(text: '${widget.initial.oppMaxChildren}');
  late final TextEditingController _maxPlyCtrl =
      TextEditingController(text: '${widget.initial.maxPly}');
  late final TextEditingController _minCumProbCtrl = TextEditingController(
      text: (widget.initial.minCumulativeProbability * 100).toString());
  late final TextEditingController _minGamesCtrl =
      TextEditingController(text: '${widget.initial.minGames}');

  @override
  void dispose() {
    _coverMinProbCtrl.dispose();
    _oppMassTargetCtrl.dispose();
    _oppMaxChildrenCtrl.dispose();
    _maxPlyCtrl.dispose();
    _minCumProbCtrl.dispose();
    _minGamesCtrl.dispose();
    super.dispose();
  }

  /// Label for the non-current-position segment, spelling out where the
  /// session would actually begin.
  String get _rootOptionLabel {
    if (widget.rootMoveSans.isNotEmpty) return 'From repertoire root';
    final root = widget.rootFen;
    final isStandardStart = root == null ||
        root.split(' ').first == kStandardStartFen.split(' ').first;
    return isStandardStart ? 'From initial position' : 'From repertoire start';
  }

  double _percent(TextEditingController ctrl, double fallback) {
    final v = double.tryParse(ctrl.text.trim());
    if (v == null) return fallback;
    return (v / 100).clamp(0.0, 1.0);
  }

  int _int(TextEditingController ctrl, int fallback, int min, int max) {
    final v = int.tryParse(ctrl.text.trim());
    if (v == null) return fallback;
    return v.clamp(min, max);
  }

  void _submit() {
    final initial = widget.initial;
    Navigator.of(context).pop(BuildByPlayingConfig(
      useMasters: _useMasters,
      speeds: _speeds.join(','),
      ratings: _ratings.join(','),
      coverMinProb: _percent(_coverMinProbCtrl, initial.coverMinProb),
      oppMassTarget: _percent(_oppMassTargetCtrl, initial.oppMassTarget),
      oppMaxChildren:
          _int(_oppMaxChildrenCtrl, initial.oppMaxChildren, 1, 20),
      maxPly: _int(_maxPlyCtrl, initial.maxPly, 2, 100),
      minCumulativeProbability:
          _percent(_minCumProbCtrl, initial.minCumulativeProbability),
      minGames: _int(_minGamesCtrl, initial.minGames, 1, 100000),
      startFromCurrentPosition: _fromCurrentPosition,
    ));
  }

  Widget _advancedField({
    required TextEditingController controller,
    required String label,
    required String tooltip,
    String? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Tooltip(
        message: tooltip,
        child: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            suffixText: suffix,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Build by playing'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'The opponent plays its most popular database replies. '
                'At each new position you explore freely, then commit '
                'your move to the repertoire.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              LichessDbSelector(
                database: _useMasters
                    ? LichessDatabase.masters
                    : LichessDatabase.lichess,
                onDatabaseChanged: (db) => setState(
                    () => _useMasters = db == LichessDatabase.masters),
                selectedSpeeds: _speeds,
                onSpeedsChanged: (s) => setState(() => _speeds = s),
                selectedRatings: _ratings,
                onRatingsChanged: (r) => setState(() => _ratings = r),
              ),
              if (widget.rootFen != null) ...[
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                        value: false, label: Text(_rootOptionLabel)),
                    const ButtonSegment(
                        value: true, label: Text('From current position')),
                  ],
                  selected: {_fromCurrentPosition},
                  onSelectionChanged: widget.atRoot
                      ? null
                      : (s) =>
                          setState(() => _fromCurrentPosition = s.first),
                ),
                const SizedBox(height: 8),
                StartingPositionCard(
                  label: 'SESSION STARTS FROM',
                  fen: _fromCurrentPosition
                      ? (widget.currentFen ?? widget.rootFen!)
                      : widget.rootFen!,
                  moveSans: _fromCurrentPosition
                      ? widget.currentMoveSans
                      : widget.rootMoveSans,
                  flipped: widget.boardFlipped,
                ),
              ],
              const SizedBox(height: 8),
              ExpansionTile(
                title: const Text('Advanced', style: TextStyle(fontSize: 14)),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 4),
                children: [
                  _advancedField(
                    controller: _coverMinProbCtrl,
                    label: 'Cover opponent replies played at least',
                    suffix: '%',
                    tooltip: 'Every opponent reply played at least this '
                        'often gets its own branch.',
                  ),
                  _advancedField(
                    controller: _oppMassTargetCtrl,
                    label: 'Stop adding replies after covering',
                    suffix: '% of games',
                    tooltip: 'Once the branched replies cover this share of '
                        'games, rarer replies are skipped (unless they pass '
                        'the threshold above).',
                  ),
                  _advancedField(
                    controller: _oppMaxChildrenCtrl,
                    label: 'Most opponent replies per position',
                    tooltip: 'Hard cap on how many opponent replies are '
                        'branched at any one position.',
                  ),
                  _advancedField(
                    controller: _maxPlyCtrl,
                    label: 'Maximum line depth in half-moves',
                    tooltip: 'Lines end after this many half-moves from the '
                        'session start.',
                  ),
                  _advancedField(
                    controller: _minCumProbCtrl,
                    label: 'Stop lines rarer than',
                    suffix: '% cumulative',
                    tooltip: 'Lines end once the combined probability of the '
                        'opponent\'s moves drops below this.',
                  ),
                  _advancedField(
                    controller: _minGamesCtrl,
                    label: 'Minimum games in database',
                    tooltip: 'Lines end at positions with fewer database '
                        'games than this.',
                  ),
                ],
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
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Start session'),
        ),
      ],
    );
  }
}
