import 'dart:isolate';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/build_tree_node.dart';
import '../../services/generation/generation_config.dart';
import '../../services/generation/line_extractor.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/training_line_planner.dart';
import '../../services/generation/trap_extractor.dart';
import '../../utils/findability.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/movetext_builder.dart';
import '../../utils/fen_utils.dart';

Future<TrainingLinePlan> _plan(
  BuildTree tree,
  TreeBuildConfig config,
  int length,
  bool lessRepetition,
) => Isolate.run(() {
  final extractor = LineExtractor(
    config: config,
    fenMap: FenMap()..populate(tree.root),
  );
  var lines = extractor.extract(tree);
  if (config.trapsOnly) {
    final traps = TrapExtractor(
      playAsWhite: config.playAsWhite,
      findabilityPRef: pRefForElo(config.maiaElo),
    ).extract(tree);
    lines = keepLinesThroughTraps(lines, traps, (line) => line.movesSan);
  }
  if (extractor.wasTruncated) {
    throw StateError('Line extraction was truncated.');
  }
  return TrainingLinePlanner.build(
    lines,
    rootWhiteToMove: tree.root.isWhiteToMove,
    playAsWhite: config.playAsWhite,
    targetOwnMoves: length,
    reduceRepetition: lessRepetition,
  );
});

/// Build a separate, directly trainable study from a finished search. The
/// original repertoire is never trimmed, and changing this plan needs no search.
class TrainingPlanCard extends StatefulWidget {
  const TrainingPlanCard({
    super.key,
    required this.tree,
    required this.config,
    required this.name,
    required this.onCreateStudy,
  });
  final BuildTree tree;
  final TreeBuildConfig config;
  final String name;
  final Future<void> Function(String name, String pgn) onCreateStudy;
  @override
  State<TrainingPlanCard> createState() => _TrainingPlanCardState();
}

class _TrainingPlanCardState extends State<TrainingPlanCard> {
  TrainingLinePlan? _planValue;
  int _length = 4, _count = 0, _revision = 0;
  bool _lessRepetition = true, _working = false, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_replan());
  }

  @override
  void didUpdateWidget(covariant TrainingPlanCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tree, widget.tree) ||
        oldWidget.config != widget.config) {
      unawaited(_replan());
    }
  }

  Future<void> _replan() async {
    final revision = ++_revision;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final result = await _plan(
        widget.tree,
        widget.config,
        _length,
        _lessRepetition,
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _planValue = result;
        _count = result.exercises.length;
        _working = false;
      });
    } catch (e) {
      if (mounted && revision == _revision) {
        setState(() {
          _error = '$e';
          _working = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final plan = _planValue;
    if (plan == null || _count < 1) return;
    setState(() => _saving = true);
    try {
      final pgn = plan.toPgn(
        count: _count,
        startFen: widget.tree.root.fen,
        playAsWhite: widget.config.playAsWhite,
        name: widget.name,
        searchLabel: widget.config.isRollingSearch
            ? 'Fast (4-ply, approximate)'
            : widget.config.buildMode == BuildMode.stockfishExpectimax
            ? 'Pure finite horizon'
            : widget.config.buildMode.name,
      );
      await widget.onCreateStudy('${widget.name} study', pgn);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create study: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _planValue;
    final disabled = _working || _saving;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Turn this repertoire into a study',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Create exercises from the saved search tree. Shared opening moves play as context; the trainer quizzes only the marked segment. Your full repertoire stays available.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<int>(
                    key: const ValueKey('study-exercise-length'),
                    initialValue: _length,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Target moves of your own',
                    ),
                    items: [
                      for (final n in [2, 4, 6])
                        DropdownMenuItem(
                          value: n,
                          child: Text('$n moves per exercise'),
                        ),
                    ],
                    onChanged: disabled
                        ? null
                        : (v) {
                            if (v != null) {
                              _length = v;
                              unawaited(_replan());
                            }
                          },
                  ),
                ),
                SizedBox(
                  width: 290,
                  child: CheckboxListTile(
                    key: const ValueKey('study-less-repetition'),
                    value: _lessRepetition,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Prefer less repeated practice'),
                    subtitle: const Text(
                      'Rank coverage gained per practised move.',
                    ),
                    onChanged: disabled
                        ? null
                        : (v) {
                            _lessRepetition = v!;
                            unawaited(_replan());
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Exercises finish after your reply. Checks, captures and promotions can extend them past the target; a quiet move pair is a reading boundary, not a safety guarantee.',
              style: AppTextStyles.caption,
            ),
            if (_working)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Preparing study options…'),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!),
              ),
            if (plan != null) ...[
              const SizedBox(height: 12),
              Text(
                '$_count of ${plan.exercises.length} exercises · ${plan.decisionsAt(_count)} distinct decisions',
                style: AppTextStyles.body,
              ),
              Text(
                '${(plan.coverageAt(_count) * 100).toStringAsFixed(1)}% of weighted prepared decisions · ${plan.practicedMovesAt(_count)} moves to practise',
              ),
              if (plan.exercises.length > 1)
                Slider(
                  key: const ValueKey('study-exercise-count'),
                  value: _count.toDouble(),
                  min: 1,
                  max: plan.exercises.length.toDouble(),
                  divisions: plan.exercises.length - 1,
                  label: '$_count exercises',
                  onChanged: disabled
                      ? null
                      : (v) => setState(() => _count = v.round()),
                ),
              const Text(
                'Coverage uses the saved tree’s opponent probabilities and horizon. It measures the preparation you selected to study, not future playing results.',
                style: AppTextStyles.caption,
              ),
              if (!widget.tree.buildComplete)
                const Text(
                  'This search is incomplete. The study contains only committed preparation.',
                ),
              if (plan.unansweredFrontierMass > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'The search stops before our next answer on ${(plan.unansweredFrontierMass * 100).toStringAsFixed(1)}% of modeled paths. Extend the search to prepare those replies.',
                  ),
                ),
              const SizedBox(height: 12),
              for (final e in plan.exercises.take(_count).take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${e.start > 0 ? 'Context: ${buildNumberedMovetext(e.line.movesSan.take(e.start).toList(), startMoveNumber: fullMoveNumber(widget.tree.root.fen), whiteToMoveFirst: widget.tree.root.isWhiteToMove)}\n' : ''}'
                    '${buildNumberedMovetext(e.quizMoves, startMoveNumber: fullMoveNumber(widget.tree.root.fen) + (e.start + (widget.tree.root.isWhiteToMove ? 0 : 1)) ~/ 2, whiteToMoveFirst: widget.config.playAsWhite)}\n'
                    '${e.ownMoves} ${e.ownMoves == 1 ? 'move' : 'moves'} to practise · ${e.quietBoundary ? 'quiet boundary' : 'search frontier'}',
                    style: AppTextStyles.caption,
                  ),
                ),
              FilledButton.icon(
                key: const ValueKey('create-training-study'),
                onPressed: disabled || _count == 0 ? null : _save,
                icon: const Icon(Icons.school_outlined),
                label: Text(
                  _saving ? 'Creating study…' : 'Create and open study copy',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
