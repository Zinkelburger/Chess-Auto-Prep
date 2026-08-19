/// "Plan a build": the full-width planning mode.
///
/// Three columns — the plan so far, the board (with engine and database
/// under it so the user can look around), and the current question — over
/// four phases: Start (where does this begin, what to prefill from), Choices
/// (the walk), Plan (review the chapters), then hand-off to [PlanRunner],
/// which creates the chapters and builds them while the user is back in the
/// builder watching the outline fill in.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../constants/chess_constants.dart';
import '../../../services/analysis_games_service.dart';
import '../../../services/generation/generation_config.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/keyboard_shortcut_utils.dart';
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/engine/inline_engine_bar.dart';
import '../../../widgets/generation/generation_config_form.dart';
import '../../repertoire/models/repertoire_outline.dart';
import '../../repertoire/widgets/repertoire_database_pane.dart';
import '../controllers/plan_controller.dart';
import '../models/plan_models.dart';
import '../services/plan_data_source.dart';
import '../services/plan_knowledge.dart';
import 'plan_candidate_table.dart';

/// Coverage floor for the walk: opponent replies below this share of games
/// are the engine's business, not the plan's. Hidden on purpose — the user
/// decides where lines start and which forks they take, not thresholds.
const double kPlanMinShare = 0.005;

/// What the screen returns when the user commits a plan.
class PlanBuildResult {
  final RepertoirePlan plan;
  final TreeBuildConfig config;
  final bool generate;
  const PlanBuildResult({
    required this.plan,
    required this.config,
    required this.generate,
  });
}

class PlanBuildScreen extends StatefulWidget {
  const PlanBuildScreen({
    super.key,
    required this.isWhite,
    required this.repertoireName,
    required this.outline,
    required this.initialMoves,
    required this.baseConfig,
    this.chesscomUsername,
    this.lichessUsername,
    this.dataSource,
    this.gamesService,
    this.defaultElo = 1800,
  });

  final bool isWhite;
  final String repertoireName;

  /// The current outline, for "already in your chapters".
  final OutlineFolder? outline;

  /// Where the board was when the user opened the planner.
  final List<String> initialMoves;

  /// Engine configuration to start from (last used, or defaults).
  final TreeBuildConfig baseConfig;

  final String? chesscomUsername;
  final String? lichessUsername;

  /// Injectable for tests.
  final PlanDataSource? dataSource;
  final AnalysisGamesService? gamesService;
  final int defaultElo;

  @override
  State<PlanBuildScreen> createState() => _PlanBuildScreenState();
}

class _PlanBuildScreenState extends State<PlanBuildScreen> {
  late final PlanDataSource _source =
      widget.dataSource ?? DefaultPlanDataSource();
  late final AnalysisGamesService _games =
      widget.gamesService ?? AnalysisGamesService();
  late final PlanController _plan = PlanController(
    source: _source,
    isWhite: widget.isWhite,
    elo: widget.defaultElo,
  );

  // Start-phase inputs.
  late List<String> _startMoves = List.of(widget.initialMoves);
  late final TextEditingController _movesText = TextEditingController(
    text: _movesLabel(widget.initialMoves),
  );
  final List<String> _redo = [];
  final FocusNode _keys = FocusNode(debugLabel: 'planner-keys');
  bool _useOwnGames = true;
  String? _ownGamesNote;
  bool _preparing = false;

  // Walk-phase state.
  final Set<String> _selected = {};

  List<String>? _previewMoves;

  // Review-phase state.
  final GlobalKey<GenerationConfigFormState> _configKey = GlobalKey();
  TreeBuildConfig? _reviewConfig;
  RepertoirePlan? _finished;

  @override
  void initState() {
    super.initState();
    _plan.addListener(_onPlanChanged);
  }

  @override
  void dispose() {
    _plan.removeListener(_onPlanChanged);
    _plan.dispose();
    _movesText.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _onPlanChanged() {
    if (!mounted) return;
    final step = _plan.step;
    setState(() {
      // A new question: reset selection to its preselection.
      if (step != null && !step.loading && _lastStepMoves != step.moves) {
        _lastStepMoves = step.moves;
        _selected
          ..clear()
          ..addAll(step.preselected);
        _previewMoves = null;
      }
    });
    if (_plan.phase == PlanPhase.review && _finished == null && !_reviewing) {
      // The walk ran out of questions on its own; finish() notifies too, so
      // this guard keeps the two from chasing each other.
      _reviewing = true;
      scheduleMicrotask(() => unawaited(_enterReview()));
    }
  }

  List<String>? _lastStepMoves;
  bool _reviewing = false;

  // ── Phase transitions ──────────────────────────────────────────────────

  Future<void> _begin() async {
    setState(() => _preparing = true);
    _plan.elo = widget.defaultElo;
    _plan.minShare = kPlanMinShare;
    _plan.knowledge = await _buildKnowledge();
    if (!mounted) return;
    setState(() => _preparing = false);
    await _plan.start(_startMoves);
  }

  Future<PlanKnowledge> _buildKnowledge() async {
    final lines = <List<String>>[
      for (final c in widget.outline?.allChapters ?? const <OutlineChapter>[])
        for (final l in c.lines ?? const <OutlineLine>[]) l.moves,
    ];
    var knowledge = PlanKnowledge(
      chapterMoves: PlanKnowledge.countOurMovesInLines(
        lines,
        isWhite: widget.isWhite,
      ),
    );
    if (!_useOwnGames) return knowledge;

    final accounts = <(String, String)>[
      if ((widget.chesscomUsername ?? '').isNotEmpty)
        ('chesscom', widget.chesscomUsername!),
      if ((widget.lichessUsername ?? '').isNotEmpty)
        ('lichess', widget.lichessUsername!),
    ];
    var totalGames = 0;
    final moves = <String, Map<String, int>>{};
    final replies = <String, Map<String, int>>{};
    for (final (platform, user) in accounts) {
      try {
        final pgn = await _games.loadAnalysisGames(platform, user);
        if (pgn == null || pgn.trim().isEmpty) continue;
        final counted = await PlanKnowledge.countOwnGames(
          pgn,
          heroNames: user,
          isWhite: widget.isWhite,
        );
        totalGames += counted.games;
        _merge(moves, counted.moves);
        _merge(replies, counted.replies);
      } catch (_) {
        // Missing cache is not an error; the column just stays empty.
      }
    }
    _ownGamesNote = accounts.isEmpty
        ? 'No accounts in Settings, so nothing to read.'
        : totalGames == 0
        ? 'No games of yours as ${widget.isWhite ? 'White' : 'Black'} in '
              'Player Analysis yet.'
        : 'Read $totalGames of your games as '
              '${widget.isWhite ? 'White' : 'Black'}.';
    return knowledge.copyWith(ownMoves: moves, ownReplies: replies);
  }

  static void _merge(MoveCounts into, MoveCounts from) {
    for (final e in from.entries) {
      final here = into.putIfAbsent(e.key, () => {});
      for (final m in e.value.entries) {
        here[m.key] = (here[m.key] ?? 0) + m.value;
      }
    }
  }

  Future<void> _enterReview() async {
    _reviewing = true;
    final plan = await _plan.finish();
    if (!mounted) return;
    setState(() {
      _finished = plan;
      _reviewing = false;
    });
  }

  void _commit({required bool generate}) {
    final plan = _finished;
    if (plan == null) return;
    final formState = _configKey.currentState;
    final config = formState == null
        ? widget.baseConfig
        : formState.toConfig(
            startFen: kStandardStartFen,
            playAsWhite: widget.isWhite,
          );
    Navigator.of(
      context,
    ).pop(PlanBuildResult(plan: plan, config: config, generate: generate));
  }

  // ── Board helpers ──────────────────────────────────────────────────────

  List<String> get _boardMoves =>
      _previewMoves ?? _plan.step?.moves ?? _startMoves;

  Position get _boardPosition {
    Position pos = Chess.initial;
    for (final san in _boardMoves) {
      final next = playSanOrNullMove(pos, san);
      if (next == null) break;
      pos = next;
    }
    return pos;
  }

  void _onStartBoardMove(CompletedMove move) {
    setState(() {
      _startMoves = [..._startMoves, move.san];
      _redo.clear();
      _movesText.text = _movesLabel(_startMoves);
    });
  }

  bool get _boardAcceptsMoves =>
      _plan.phase == PlanPhase.walking &&
      _previewMoves == null &&
      _plan.step != null &&
      !_plan.step!.loading &&
      _plan.step!.kind != PlanStepKind.confirmLeaf &&
      _plan.step!.kind != PlanStepKind.transposition;

  void _onWalkBoardMove(CompletedMove move) {
    final step = _plan.step;
    if (step == null) return;
    _plan.addCandidate(move.san);
    final after = _plan.step ?? step;
    _selectRow(after, move.san);
  }

  void _undoStartMove() {
    if (_startMoves.isEmpty) return;
    setState(() {
      _redo.add(_startMoves.last);
      _startMoves = _startMoves.sublist(0, _startMoves.length - 1);
      _movesText.text = _movesLabel(_startMoves);
    });
  }

  void _redoStartMove() {
    if (_redo.isEmpty) return;
    setState(() {
      _startMoves = [..._startMoves, _redo.removeLast()];
      _movesText.text = _movesLabel(_startMoves);
    });
  }

  /// ← / → : undo/redo a start move; in the walk, ← leaves a preview.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isTextInputFocused()) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (_plan.phase == PlanPhase.start) {
        _undoStartMove();
      } else if (_previewMoves != null) {
        setState(() {
          _previewMoves = null;
        });
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_plan.phase == PlanPhase.start) _redoStartMove();
      return KeyEventResult.handled;
    }
    if (_plan.phase == PlanPhase.start) {
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (!_preparing) unawaited(_begin());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_plan.phase == PlanPhase.walking) {
      final step = _plan.step;
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        _continue();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        if (_plan.canGoBack) unawaited(_plan.back());
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyG) {
        unawaited(_plan.stopHere());
        return KeyEventResult.handled;
      }
      // 1–9 select the nth row.
      final digit = event.character == null
          ? null
          : int.tryParse(event.character!);
      if (step != null && digit != null && digit >= 1) {
        if (digit <= step.candidates.length) {
          _selectRow(step, step.candidates[digit - 1].san);
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Row tapped: at our move it becomes *the* choice; at theirs it toggles.
  /// Either way the board shows it.
  void _selectRow(PlanStep step, String san) {
    setState(() {
      if (step.kind == PlanStepKind.ourMove) {
        _selected
          ..clear()
          ..add(san);
      } else if (!_selected.remove(san)) {
        _selected.add(san);
      }
      _previewMoves = [...step.moves, san];
    });
  }

  void _continue() {
    final step = _plan.step;
    if (step == null || step.loading) return;
    if (step.kind == PlanStepKind.confirmLeaf) {
      unawaited(_plan.confirmLeaf());
      return;
    }
    if (step.kind == PlanStepKind.transposition) {
      unawaited(_plan.skipTransposition());
      return;
    }
    final ours = step.kind == PlanStepKind.ourMove;
    if (ours && _selected.isEmpty) return;
    unawaited(
      ours
          ? _plan.choose(_selected.toList())
          : _plan.acceptCoverage(_selected.toList()),
    );
  }

  void _parseTypedMoves(String text) {
    final tokens = text
        .replaceAll(RegExp(r'\d+\.(\.\.)?'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    Position pos = Chess.initial;
    final ok = <String>[];
    for (final t in tokens) {
      final next = playSanOrNullMove(pos, t);
      if (next == null) break;
      ok.add(t);
      pos = next;
    }
    setState(() {
      _startMoves = ok;
      _redo.clear();
    });
  }

  static String _movesLabel(List<String> moves) {
    final buf = StringBuffer();
    for (var i = 0; i < moves.length; i++) {
      if (i.isEven) buf.write('${i ~/ 2 + 1}.');
      buf.write(moves[i]);
      if (i < moves.length - 1) buf.write(' ');
    }
    return buf.toString();
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final phase = _plan.phase;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Text(
              '${widget.repertoireName} ▸ Plan a build',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 24),
            _Steps(phase: phase, hasPlan: _finished != null),
          ],
        ),
        actions: [
          if (phase == PlanPhase.walking)
            TextButton.icon(
              onPressed: () => unawaited(_enterReview()),
              icon: const Icon(Icons.flag_outlined, size: 16),
              label: const Text('Finish now'),
            ),
          PopupMenuButton<String>(
            tooltip: 'Options',
            onSelected: (_) => setState(() => _useOwnGames = !_useOwnGames),
            itemBuilder: (_) => [
              CheckedPopupMenuItem<String>(
                value: 'games',
                checked: _useOwnGames,
                child: const Text('Use my games from Player Analysis'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Close planner',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      body: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;
            final left = _buildPlanSoFar();
            final board = _buildBoardColumn(
              interactive: phase == PlanPhase.start,
            );
            final card = switch (phase) {
              PlanPhase.start => _buildStartCard(),
              PlanPhase.walking => _buildStepCard(),
              PlanPhase.review => _buildReviewCard(),
            };
            if (!wide) {
              return Column(
                children: [
                  Expanded(flex: 4, child: board),
                  const Divider(height: 1),
                  Expanded(flex: 5, child: card),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 260, child: left),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: (constraints.maxWidth * 0.36).clamp(320.0, 520.0),
                  child: board,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: card),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Left: plan so far ──────────────────────────────────────────────────

  Widget _buildPlanSoFar() {
    final chapters = _finished?.chapters ?? _plan.chapters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              const Text(
                'PLAN SO FAR',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
              const SizedBox(width: 8),
              if (_plan.phase == PlanPhase.walking)
                Expanded(
                  child: Text(
                    '${_plan.answered} answered · ${_plan.openBranches} open',
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              if (_startMoves.isNotEmpty)
                Text(
                  _movesLabel(_startMoves),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              if (_plan.decisions.isNotEmpty)
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '${_plan.decisions.length} decision'
                      '${_plan.decisions.length == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    children: [
                      for (final d in _plan.decisions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '• $d',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.onSurfaceSoft,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (chapters.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'CHAPTERS · ${chapters.length}',
                  style: const TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                for (final group in _groupChapters(chapters).entries)
                  _ChapterGroup(
                    family: group.key,
                    chapters: group.value,
                    initiallyExpanded: group.value.length <= 3,
                    row: (c) => Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.article_outlined,
                            size: 13,
                            color: AppColors.onSurfaceDim,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${_shortName(c, group.key)}'
                              '${c.points.length > 1 ? '  · ${c.points.length} lines' : ''}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Middle: board, moves, engine, database ─────────────────────────────

  Widget _buildBoardColumn({required bool interactive}) {
    final pos = _boardPosition;
    final fen = pos.fen;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: AspectRatio(
            aspectRatio: 1,
            child: ChessBoardWidget(
              position: pos,
              flipped: !widget.isWhite,
              // Start: the board sets the root. Walk: a move played at the
              // question position becomes a candidate and is selected —
              // Maia's list is a suggestion, not a fence.
              enableUserMoves: interactive || _boardAcceptsMoves,
              onMove: interactive
                  ? _onStartBoardMove
                  : (_boardAcceptsMoves ? _onWalkBoardMove : null),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _boardMoves.isEmpty
                      ? 'Start position'
                      : _movesLabel(_boardMoves),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_previewMoves != null)
                TextButton(
                  onPressed: () => setState(() {
                    _previewMoves = null;
                  }),
                  child: const Text(
                    'back to question',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              if (interactive && _startMoves.isNotEmpty)
                IconButton(
                  tooltip: 'Undo move',
                  icon: const Icon(Icons.undo, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _startMoves = _startMoves.sublist(
                      0,
                      _startMoves.length - 1,
                    );
                    _movesText.text = _movesLabel(_startMoves);
                  }),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(
                      height: 30,
                      child: Text('Engine', style: TextStyle(fontSize: 12)),
                    ),
                    Tab(
                      height: 30,
                      child: Text('Database', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  labelPadding: EdgeInsets.symmetric(horizontal: 12),
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerHeight: 1,
                ),
                Expanded(
                  child: TabBarView(
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      SingleChildScrollView(
                        child: InlineEngineBar(fen: fen, isActive: true),
                      ),
                      RepertoireDatabasePane(
                        fen: fen,
                        repertoireMovesAtPosition: () => const {},
                        onPlayMove: (san) {
                          if (_plan.phase == PlanPhase.start) {
                            setState(() {
                              _startMoves = [..._startMoves, san];
                              _movesText.text = _movesLabel(_startMoves);
                            });
                          } else {
                            setState(() {
                              _previewMoves = [..._boardMoves, san];
                            });
                          }
                        },
                        onAddMove: (_) {},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Right: start card ──────────────────────────────────────────────────

  Widget _buildStartCard() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Text(
              'Where should this start?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            const Tooltip(
              waitDuration: Duration(milliseconds: 300),
              message: 'Play or type moves · ← undo · → redo',
              child: Icon(
                Icons.info_outline,
                size: 16,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final start in _commonStarts)
              ChoiceChip(
                label: Text(
                  _movesLabel(start),
                  style: const TextStyle(fontSize: 12),
                ),
                selected: _listEq(_startMoves, start),
                onSelected: (_) => setState(() {
                  _startMoves = List.of(start);
                  _redo.clear();
                  _movesText.text = _movesLabel(start);
                }),
              ),
            ChoiceChip(
              label: const Text(
                'Start position',
                style: TextStyle(fontSize: 12),
              ),
              selected: _startMoves.isEmpty,
              onSelected: (_) => setState(() {
                _startMoves = [];
                _redo.clear();
                _movesText.text = '';
              }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _movesText,
          onChanged: _parseTypedMoves,
          style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            labelText: 'Moves',
            hintText: '1.d4 d5 2.c4',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        if (_ownGamesNote != null) ...[
          const SizedBox(height: 8),
          Text(
            _ownGamesNote!,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            const Spacer(),
            FilledButton.icon(
              onPressed: _preparing ? null : () => unawaited(_begin()),
              icon: _preparing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward, size: 18),
              label: Text(_preparing ? 'Reading your games…' : 'Next'),
            ),
          ],
        ),
      ],
    );
  }

  /// White's first move — the same four for both colours: a Black repertoire
  /// is organised by what White does, and the user plays Black's reply on the
  /// board.
  List<List<String>> get _commonStarts => const [
    ['e4'],
    ['d4'],
    ['c4'],
    ['Nf3'],
  ];

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── Right: question / coverage card ────────────────────────────────────

  Widget _buildStepCard() {
    final step = _plan.step;
    if (step == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (step.kind == PlanStepKind.confirmLeaf) return _buildLeafCard(step);
    if (step.kind == PlanStepKind.transposition) {
      return _buildTranspositionCard(step);
    }
    final ours = step.kind == PlanStepKind.ourMove;
    final whiteToMove = step.fen.split(' ')[1] != 'b';
    final title = ours
        ? 'How do you play here?'
        : 'Which replies do you want to set up?';
    final manual = _plan.isManual(step.moves);
    final subtitle = manual
        ? 'Setting up by hand — no more prompts on this line. Press '
              '"Generate from here" (G) when it\'s deep enough.'
        : ours
        ? 'Pick your move — click a row or play it on the board. Enter '
              'continues, Backspace goes back.'
        : 'Ticked replies are set up as their own lines; a big new system '
              'becomes its own chapter. Play a move on the board to add a '
              'reply.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    step.positionName ?? _movesLabel(step.moves),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    ours
                        ? '${whiteToMove ? 'White' : 'Black'} (you) to move'
                        : 'Opponent to move',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceDim,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: manual ? AppColors.accent : AppColors.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
        if (step.loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 10),
                  Text(
                    'Asking the book, Maia and the engine…',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          // About ten rows tall; the rest scrolls. The buttons sit right
          // under the table, not at the bottom of the screen.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 10 * 30.0 + 28),
            child: SingleChildScrollView(
              child: PlanCandidateTable(
                candidates: step.candidates,
                selected: _selected,
                isWhiteToMove: whiteToMove,
                reachProb: step.reachProb,
                singleSelect: ours,
                ownLabel: ours ? 'You' : 'Vs you',
                onSelect: (san) => _selectRow(step, san),
                evaluating: _plan.evaluating,
                onEvaluate: (san) => unawaited(_plan.evaluateCandidate(san)),
                evalSourceLabel: switch (_source) {
                  final DefaultPlanDataSource d => d.evalSourceLabel,
                  _ => 'Eval',
                },
              ),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: step.loading || (ours && _selected.isEmpty)
                    ? null
                    : _continue,
                icon: const Icon(Icons.keyboard_return, size: 16),
                label: const Text('Continue  (Enter)'),
              ),
              OutlinedButton(
                onPressed: _plan.canGoBack
                    ? () => unawaited(_plan.back())
                    : null,
                child: const Text('‹ Back'),
              ),
              if (manual)
                FilledButton.tonal(
                  onPressed: () => unawaited(_plan.stopHere()),
                  child: const Text('Generate from here (G)'),
                )
              else
                OutlinedButton(
                  onPressed: () => unawaited(_plan.stopHere()),
                  child: const Text('Generate from here (G)'),
                ),
            ],
          ),
        ),
        const Spacer(),
      ],
    );
  }

  /// Same position, different move order: reuse or set up separately.
  Widget _buildTranspositionCard(PlanStep step) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _movesLabel(step.moves),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Same position as ${_movesLabel(step.transposesTo ?? const [])}, '
            'which is already set up.',
            style: const TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => unawaited(_plan.skipTransposition()),
                icon: const Icon(Icons.keyboard_return, size: 16),
                label: const Text('Use that line  (Enter)'),
              ),
              OutlinedButton(
                onPressed: () => unawaited(_plan.setUpSeparately()),
                child: const Text('Set up this move order separately'),
              ),
              OutlinedButton(
                onPressed: _plan.canGoBack
                    ? () => unawaited(_plan.back())
                    : null,
                child: const Text('‹ Back'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The walk would stop here. Show what was set up on this path and ask.
  Widget _buildLeafCard(PlanStep step) {
    final ours = step.fen.split(' ')[1] != 'b'
        ? widget.isWhite
        : !widget.isWhite;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            step.positionName ?? _movesLabel(step.moves),
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _movesLabel(step.moves),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'No more ECO codes from here. ${ours ? 'You' : 'Your opponent'} to '
            'move · ${(step.reachProb * 100).toStringAsFixed(step.reachProb >= 0.1 ? 0 : 1)}% '
            'of games reach this.',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => unawaited(_plan.confirmLeaf()),
                icon: const Icon(Icons.keyboard_return, size: 16),
                label: const Text('Generate from here  (Enter)'),
              ),
              OutlinedButton(
                onPressed: () => unawaited(_plan.continueSetup()),
                child: const Text('Keep setting up this line'),
              ),
              OutlinedButton(
                onPressed: _plan.canGoBack
                    ? () => unawaited(_plan.back())
                    : null,
                child: const Text('‹ Back'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Right: review card ─────────────────────────────────────────────────

  Widget _buildReviewCard() {
    final plan = _finished;
    if (plan == null) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '${plan.chapters.length} chapter${plan.chapters.length == 1 ? '' : 's'} to create',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'A chapter is an opening system; the lines you set up inside '
                'it are the engine\'s starting points. Rename or drop any '
                'before anything runs.',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
              ),
              const SizedBox(height: 12),
              for (final group in _groupChapters(plan.chapters).entries)
                _ChapterGroup(
                  family: group.key,
                  chapters: group.value,
                  initiallyExpanded: group.value.length <= 4,
                  row: (c) => _ChapterEditRow(
                    chapter: c,
                    onRename: (name) => setState(() => c.name = name),
                    onRemove: () => setState(() => plan.chapters.remove(c)),
                  ),
                ),
              const SizedBox(height: 20),
              const _SectionTitle('Engine'),
              GenerationConfigForm(
                key: _configKey,
                initialConfig: _reviewConfig ?? widget.baseConfig,
                isGenerating: false,
                playAsWhite: widget.isWhite,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: _plan.canGoBack
                    ? () {
                        setState(() {
                          _finished = null;
                          _reviewing = false;
                        });
                        unawaited(_plan.back());
                      }
                    : null,
                child: const Text('‹ Back to choices'),
              ),
              OutlinedButton(
                onPressed: plan.chapters.isEmpty
                    ? null
                    : () => _commit(generate: false),
                child: const Text('Create chapters only'),
              ),
              FilledButton.icon(
                onPressed: plan.chapters.isEmpty
                    ? null
                    : () => _commit(generate: true),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: Text('Create ${plan.chapters.length} & generate'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Pieces ─────────────────────────────────────────────────────────────────

/// Group chapters by opening family — the book name before its first ':' or
/// ' · ' — so twenty-five Benko chapters read as one line that expands.
Map<String, List<PlanChapter>> _groupChapters(List<PlanChapter> chapters) {
  final out = <String, List<PlanChapter>>{};
  for (final c in chapters) {
    out.putIfAbsent(_familyOf(c.name), () => []).add(c);
  }
  return out;
}

String _familyOf(String name) {
  var f = name;
  final colon = f.indexOf(':');
  if (colon > 0) f = f.substring(0, colon);
  final dot = f.indexOf(' · ');
  if (dot > 0) f = f.substring(0, dot);
  return f.trim();
}

/// A chapter's name without the family prefix, for use under a group header.
String _shortName(PlanChapter c, String family) {
  var n = c.name;
  if (n.startsWith(family)) {
    n = n.substring(family.length).trim();
    if (n.startsWith(':') || n.startsWith('·')) n = n.substring(1).trim();
  }
  return n.isEmpty ? c.name : n;
}

class _ChapterGroup extends StatelessWidget {
  final String family;
  final List<PlanChapter> chapters;
  final bool initiallyExpanded;
  final Widget Function(PlanChapter) row;
  const _ChapterGroup({
    required this.family,
    required this.chapters,
    required this.initiallyExpanded,
    required this.row,
  });

  @override
  Widget build(BuildContext context) {
    if (chapters.length == 1) return row(chapters.single);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey('plan-group-$family'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 8),
        dense: true,
        initiallyExpanded: initiallyExpanded,
        title: Text(
          '$family  ·  ${chapters.length}',
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        children: [for (final c in chapters) row(c)],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  final PlanPhase phase;
  final bool hasPlan;
  const _Steps({required this.phase, required this.hasPlan});

  @override
  Widget build(BuildContext context) {
    final labels = ['Start', 'Choices', 'Plan'];
    final on = switch (phase) {
      PlanPhase.start => 0,
      PlanPhase.walking => 1,
      PlanPhase.review => 2,
    };
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: i == on ? AppColors.accent.withValues(alpha: 0.18) : null,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: i == on ? FontWeight.w700 : FontWeight.w400,
                color: i == on ? AppColors.accent : AppColors.onSurfaceMuted,
              ),
            ),
          ),
          if (i < labels.length - 1)
            const Icon(
              Icons.chevron_right,
              size: 14,
              color: AppColors.onSurfaceDim,
            ),
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 10,
        letterSpacing: 0.6,
        fontWeight: FontWeight.w700,
        color: AppColors.onSurfaceMuted,
      ),
    ),
  );
}

class _ChapterEditRow extends StatelessWidget {
  final PlanChapter chapter;
  final ValueChanged<String> onRename;
  final VoidCallback onRemove;
  const _ChapterEditRow({
    required this.chapter,
    required this.onRename,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.article_outlined,
            size: 16,
            color: AppColors.onSurfaceMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: chapter.name,
                  onChanged: onRename,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: UnderlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                  ),
                ),
                const SizedBox(height: 2),
                for (final pt in chapter.points)
                  Text(
                    '⚙ ${pt.moves.isEmpty ? 'start position' : pt.moves.join(' ')}'
                    '${pt.excludeReplies.isEmpty ? '' : ' · everything played here except ${pt.excludeReplies.join(', ')} (those have their own lines)'}',
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.onSurfaceDim,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Drop this chapter',
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
