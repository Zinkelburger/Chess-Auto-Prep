/// The "Build from my games" flow: download → build draft → prune/review →
/// merge into the repertoire (surfacing conflicts).
///
/// Self-contained so it can be launched from anywhere in the repertoire screen
/// without rewiring it. Reuses the shared Games library, the existing
/// `UnifiedAnalysisBuilder` (games → OpeningTree), and the games-repertoire
/// core engine (diff / draft / merge).
library;

import 'package:flutter/material.dart';

import '../../core/repertoire_controller.dart';
import '../../services/games_library/game_filter.dart';
import '../../services/games_library/games_library_service.dart';
import '../../services/games_repertoire/games_draft.dart';
import '../../services/games_repertoire/repertoire_merge.dart';
import '../../services/unified_analysis_builder.dart';
import '../../theme/app_colors.dart';
import 'draft_tree_view.dart';
import 'merge_conflict_sheet.dart';

/// Launch the flow as a full-screen dialog.
Future<void> showBuildFromGamesDialog(
  BuildContext context, {
  required RepertoireController controller,
  bool initialIsWhite = true,
  GamesLibraryService? library,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog.fullscreen(
      child: BuildFromGamesDialog(
        controller: controller,
        initialIsWhite: initialIsWhite,
        library: library ?? GamesLibraryService(),
      ),
    ),
  );
}

enum _Step { form, building, review }

class BuildFromGamesDialog extends StatefulWidget {
  const BuildFromGamesDialog({
    super.key,
    required this.controller,
    required this.library,
    this.initialIsWhite = true,
  });

  final RepertoireController controller;
  final GamesLibraryService library;
  final bool initialIsWhite;

  @override
  State<BuildFromGamesDialog> createState() => _BuildFromGamesDialogState();
}

class _BuildFromGamesDialogState extends State<BuildFromGamesDialog> {
  _Step _step = _Step.form;

  // Form state.
  GamesPlatform _platform = GamesPlatform.chesscom;
  final _usernameCtrl = TextEditingController();
  late bool _isWhite = widget.initialIsWhite;
  int _maxGames = 200;
  final Set<GameSpeed> _speeds = {
    GameSpeed.blitz,
    GameSpeed.rapid,
    GameSpeed.classical,
  };

  // Build state.
  String _progress = '';
  String? _error;

  // Review state.
  GamesDraft? _draft;
  int _minGames = 2;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _build() async {
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Enter a username first.');
      return;
    }
    setState(() {
      _step = _Step.building;
      _error = null;
      _progress = 'Starting…';
    });

    try {
      final records = await widget.library.getGames(
        platform: _platform,
        username: username,
        selection: GameSelection(maxGames: _maxGames, speeds: _speeds),
        onProgress: (m) {
          if (mounted) setState(() => _progress = m);
        },
      );
      if (records.isEmpty) {
        setState(() {
          _step = _Step.form;
          _error = 'No games found for "$username".';
        });
        return;
      }

      if (mounted) {
        setState(() => _progress =
            'Building opening tree from ${records.length} games…');
      }
      final pgnList = records.map((r) => r.pgn).toList();
      final (_, tree) = await UnifiedAnalysisBuilder.buildInIsolate(
        pgnList: pgnList,
        username: username,
        isWhite: _isWhite,
        strictPlayerMatching: false,
      );

      final draft = GamesDraft.against(
        tree: tree,
        isWhite: _isWhite,
        repertoire: widget.controller.tree,
      );
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _step = _Step.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.form;
        _error = 'Could not build draft: $e';
      });
    }
  }

  Future<void> _merge() async {
    final draft = _draft;
    if (draft == null) return;
    final draftTree =
        draft.materialize(filters: DraftFilters(minGames: _minGames));
    if (draftTree.isEmpty) {
      _toast('Nothing to merge — every line was filtered out.');
      return;
    }
    final result =
        widget.controller.mergeDraft(draftTree, isWhite: _isWhite);

    if (!mounted) return;
    if (result.hasConflicts) {
      await _showConflicts(result);
    } else {
      _toast('Merged ${result.addedMoves} new moves into your repertoire.');
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _showConflicts(MergeResult result) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => MergeConflictSheet(
        controller: widget.controller,
        conflicts: result.conflicts,
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(switch (_step) {
          _Step.form => 'Build repertoire from my games',
          _Step.building => 'Building…',
          _Step.review => 'Review draft',
        }),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: switch (_step) {
        _Step.form => _buildForm(),
        _Step.building => _buildProgress(),
        _Step.review => _buildReview(),
      },
    );
  }

  // ── Form ─────────────────────────────────────────────────────────────
  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Where are your games?',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<GamesPlatform>(
          segments: const [
            ButtonSegment(
                value: GamesPlatform.chesscom, label: Text('Chess.com')),
            ButtonSegment(
                value: GamesPlatform.lichess, label: Text('Lichess')),
          ],
          selected: {_platform},
          onSelectionChanged: (s) => setState(() => _platform = s.first),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _usernameCtrl,
          decoration: const InputDecoration(
            labelText: 'Username',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _build(),
        ),
        const SizedBox(height: 16),
        const Text('Which repertoire are we filling?',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('As White')),
            ButtonSegment(value: false, label: Text('As Black')),
          ],
          selected: {_isWhite},
          onSelectionChanged: (s) => setState(() => _isWhite = s.first),
        ),
        const SizedBox(height: 16),
        Text('Most recent $_maxGames games',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: _maxGames.toDouble(),
          min: 20,
          max: 1000,
          divisions: 49,
          label: '$_maxGames',
          onChanged: (v) => setState(() => _maxGames = v.round()),
        ),
        const SizedBox(height: 8),
        const Text('Time controls',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final s in [
              GameSpeed.bullet,
              GameSpeed.blitz,
              GameSpeed.rapid,
              GameSpeed.classical,
            ])
              FilterChip(
                label: Text(s.name),
                selected: _speeds.contains(s),
                onSelected: (on) => setState(() {
                  if (on) {
                    _speeds.add(s);
                  } else {
                    _speeds.remove(s);
                  }
                }),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: AppColors.danger)),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _build,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Build draft'),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_progress, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  // ── Review ───────────────────────────────────────────────────────────
  Widget _buildReview() {
    final draft = _draft!;
    final diff = draft.diff;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(spacing: 16, runSpacing: 4, children: [
                _stat('Already covered', diff.inRepertoireCount,
                    AppColors.success),
                _stat('My off-book', diff.myDeviationCount, AppColors.warning),
                _stat('Opponent gaps', diff.opponentDeviationCount,
                    AppColors.danger),
              ]),
              const SizedBox(height: 8),
              const DraftLegend(),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Min games', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _minGames.toDouble(),
                      min: 1,
                      max: 10,
                      divisions: 9,
                      label: '$_minGames',
                      onChanged: (v) =>
                          setState(() => _minGames = v.round()),
                    ),
                  ),
                  Text('$_minGames+', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: DraftTreeView(
            draft: draft,
            minGames: _minGames,
            onChanged: () => setState(() {}),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Discard lines you don\'t want, then merge the rest into '
                  'your repertoire.',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.onSurfaceMuted),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _merge,
                icon: const Icon(Icons.merge_type),
                label: const Text('Merge into repertoire'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, int n, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, color: color),
      const SizedBox(width: 6),
      Text('$n $label', style: const TextStyle(fontSize: 13)),
    ]);
  }
}
