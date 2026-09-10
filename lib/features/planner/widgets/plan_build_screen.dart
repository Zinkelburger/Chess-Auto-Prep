/// "Plan the lines": the full-width planning mode.
///
/// Three columns — the plan so far, the board (with engine and database
/// under it so the user can look around), and the current question — over
/// four phases: Start (where does this begin, and is the walk of the book or
/// of the user's own games), Choices (the walk), Plan (review the chapters),
/// then hand-off to [PlanRunner], which creates the chapters and builds them
/// while the user is back in the builder watching the outline fill in.
///
/// "My games" is the planner's answer to *turn my games into a repertoire*:
/// the same questions, asked at the positions the user actually reached,
/// with what they played pre-ticked — so the repertoire is theirs, decision
/// by decision, rather than a dump of every line they ever played.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../utils/app_shortcuts.dart';
import '../../../utils/keyboard_shortcut_utils.dart';
import '../../../constants/chess_constants.dart';
import '../../../models/board_annotation.dart';
import '../../../services/analysis_games_service.dart';
import '../../../services/generation/generation_config.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/chess_utils.dart';
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/engine/inline_engine_bar.dart';
import '../../../widgets/generation/generation_config_form.dart';
import '../../repertoire/models/repertoire_outline.dart';
import '../../repertoire/widgets/repertoire_database_pane.dart';
import '../controllers/plan_controller.dart';
import '../models/plan_models.dart';
import '../models/plan_starting_line.dart';
import '../../../services/generation/generation_presets.dart';
import '../../../utils/app_messages.dart';
import '../services/plan_data_source.dart';
import '../services/plan_knowledge.dart';
import 'plan_candidate_table.dart';
import '../../../utils/fen_utils.dart';
import '../../../utils/movetext_builder.dart';

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

  // Each row is a complete move path; the board edits the selected row.
  late List<PlanStartingLine> _startingLines = [
    PlanStartingLine(moves: widget.initialMoves),
  ];
  int _selectedStart = 0;
  String? _startError;
  bool _startTextValid = true;
  bool _guided = true;

  // Start-phase inputs.
  late List<String> _startMoves = List.of(widget.initialMoves);
  late final TextEditingController _movesText = TextEditingController(
    text: _movesLabel(widget.initialMoves),
  );
  final FocusNode _keys = FocusNode(debugLabel: 'planner-keys');
  PlanBasis _basis = PlanBasis.book;
  bool _preparing = false;

  /// The user's games as this colour, read once when the screen opens so the
  /// start card can say how many there are before anything is chosen. Null
  /// until read; the counts are empty when there are no accounts or games.
  late final Future<PlanKnowledge> _ownGames = _readOwnGames();
  int? _ownGamesCount;
  String? _ownGamesNote;

  // Walk-phase state.
  final Set<String> _selected = {};

  List<String>? _previewMoves;

  /// Arrow for the explorer row under the pointer. Its own notifier so a
  /// hover repaints the board, not the whole screen.
  final ValueNotifier<BoardAnnotation?> _hoverArrow = ValueNotifier(null);

  // Review-phase state.
  final GlobalKey<GenerationConfigFormState> _configKey = GlobalKey();
  TreeBuildConfig? _reviewConfig;
  RepertoirePlan? _finished;

  @override
  void initState() {
    super.initState();
    _plan.addListener(_onPlanChanged);
    // The read starts now; the start card repaints when it lands (always a
    // later microtask, so never from inside initState).
    unawaited(
      _ownGames.then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _plan.removeListener(_onPlanChanged);
    _plan.dispose();
    _movesText.dispose();
    _keys.dispose();
    _hoverArrow.dispose();
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
    if (!_canBegin) return;
    setState(() => _preparing = true);
    _plan.elo = widget.defaultElo;
    _plan.minShare = kPlanMinShare;
    _plan.basis = _basis;
    if (_guided) _plan.knowledge = await _buildKnowledge();
    if (!mounted) return;
    try {
      if (!_guided) {
        _reviewConfig ??= chessDbRepertoirePreset(playAsWhite: widget.isWhite);
      }
      await _plan.startMany(_startingLines, askQuestions: _guided);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Could not prepare the plan: $e',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<PlanKnowledge> _buildKnowledge() async {
    final lines = <List<String>>[
      for (final c in widget.outline?.allChapters ?? const <OutlineChapter>[])
        for (final l in c.lines ?? const <OutlineLine>[]) l.moves,
    ];
    final own = await _ownGames;
    return own.copyWith(
      chapterMoves: PlanKnowledge.countOurMovesInLines(
        lines,
        isWhite: widget.isWhite,
      ),
    );
  }

  /// Count the user's moves and their opponents' replies across every
  /// account in Settings. Fills [_ownGamesCount] and [_ownGamesNote] for the
  /// start card; the caller repaints.
  Future<PlanKnowledge> _readOwnGames() async {
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
    final colour = widget.isWhite ? 'White' : 'Black';
    final note = accounts.isEmpty
        ? 'No accounts in Settings, so there are no games to walk.'
        : totalGames == 0
        ? 'No games of yours as $colour in Player Analysis yet.'
        : '$totalGames of your games as $colour. Every position you reached '
              'often enough is a question, with what you played pre-ticked.';
    _ownGamesCount = totalGames;
    _ownGamesNote = note;
    return PlanKnowledge(ownMoves: moves, ownReplies: replies);
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
    if (generate) {
      final error = formState?.validateBeforeStart();
      if (error != null) {
        showAppSnackBar(context, error, isError: true);
        return;
      }
    }
    final config = formState == null
        ? _reviewConfig ?? widget.baseConfig
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

  void _onStartBoardMove(CompletedMove move) =>
      _replaceStartMoves([..._startMoves, move.san]);

  void _replaceStartMoves(List<String> moves) {
    if (!mounted || _preparing || !_startTextValid) return;
    setState(() {
      final current = _startingLines[_selectedStart];
      _startingLines[_selectedStart] = PlanStartingLine(
        name: current.name,
        moves: moves,
      );
      _startMoves = List.of(moves);
      _movesText.text = _startingLines
          .map((line) => line.text.isEmpty ? 'Start position |' : line.text)
          .join('\n');
      _validateStarts();
    });
  }

  void _addStart() {
    if (!mounted || _preparing || !_startTextValid) return;
    setState(() {
      _startingLines.add(
        PlanStartingLine(
          name: 'Line ${_startingLines.length + 1}',
          moves: const [],
        ),
      );
      _selectedStart = _startingLines.length - 1;
      _startMoves = [];
      _movesText.text = _startingLines
          .map((line) => line.text.isEmpty ? 'Start position |' : line.text)
          .join('\n');
      _validateStarts();
    });
  }

  void _removeStart() {
    if (!mounted ||
        _preparing ||
        !_startTextValid ||
        _startingLines.length < 2) {
      return;
    }
    setState(() {
      _startingLines.removeAt(_selectedStart);
      _selectedStart = _selectedStart.clamp(0, _startingLines.length - 1);
      _startMoves = List.of(_startingLines[_selectedStart].moves);
      _movesText.text = _startingLines
          .map((line) => line.text.isEmpty ? 'Start position |' : line.text)
          .join('\n');
      _validateStarts();
    });
  }

  void _validateStarts() {
    try {
      PlanStartingLine.validate(_startingLines);
      _startError = null;
    } on FormatException catch (e) {
      _startError = e.message;
    }
  }

  void _editStarts() {
    if (!mounted) return;
    _reviewConfig =
        _configKey.currentState?.toConfig(
          startFen: kStandardStartFen,
          playAsWhite: widget.isWhite,
        ) ??
        _reviewConfig;
    setState(() {
      _finished = null;
      _reviewing = false;
      _previewMoves = null;
      _lastStepMoves = null;
    });
    _plan.reset();
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
    if (!mounted) return;
    setState(() {
      try {
        _startingLines = PlanStartingLine.parse(text);
        _startTextValid = true;
        _selectedStart = _selectedStart.clamp(0, _startingLines.length - 1);
        _startMoves = List.of(_startingLines[_selectedStart].moves);
        _validateStarts();
      } on FormatException catch (e) {
        _startTextValid = false;
        _startError = e.message;
      }
    });
  }

  static String _movesLabel(List<String> moves) =>
      buildNumberedMovetext(moves, compact: true);

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
              '${widget.repertoireName} ▸ Plan the lines',
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
        onKeyEvent: (node, event) => handleKeyBindings(
          [
            ...KeyBinding.forShortcut(
              AppShortcut.toggleEngine,
              'Toggle engine',
              InlineEngineBar.toggleEngine,
            ),
          ],
          event,
          node: node,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;
            final left = _buildPlanSoFar();
            final board = _buildBoardColumn(
              interactive:
                  phase == PlanPhase.start && !_preparing && _startTextValid,
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
                  fontSize: 12,
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
                    style: AppTextStyles.caption,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final start in _startingLines)
                Text(
                  start.text.isEmpty ? 'Initial position' : start.text,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: AppTextStyles.monoFamily,
                  ),
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
                      style: const TextStyle(fontSize: 12),
                    ),
                    children: [
                      for (final d in _plan.decisions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text('• $d', style: AppTextStyles.caption),
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
                    fontSize: 12,
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
        // The largest square that fits the column's width *and* its share of
        // the height — a narrow or short window (split screen) must never
        // push the moves and engine off the bottom.
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ValueListenableBuilder<BoardAnnotation?>(
                  valueListenable: _hoverArrow,
                  builder: (context, arrow, _) => ChessBoardWidget(
                    position: pos,
                    flipped: !widget.isWhite,
                    annotations: arrow == null ? const [] : [arrow],
                    // Start: the board sets the root. Walk: a move played
                    // at the question position becomes a candidate and is
                    // selected — Maia's list is a suggestion, not a fence.
                    enableUserMoves: interactive || _boardAcceptsMoves,
                    onMove: interactive
                        ? _onStartBoardMove
                        : (_boardAcceptsMoves ? _onWalkBoardMove : null),
                  ),
                ),
              ),
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
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: AppTextStyles.monoFamily,
                  ),
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
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              if (interactive && _startMoves.isNotEmpty)
                IconButton(
                  tooltip: 'Undo move',
                  icon: const Icon(Icons.undo, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _replaceStartMoves(
                    _startMoves.sublist(0, _startMoves.length - 1),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          flex: 2,
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
                        child: InlineEngineBar(
                          fen: fen,
                          isActive: true,
                          previewFlipped: !widget.isWhite,
                        ),
                      ),
                      RepertoireDatabasePane(
                        fen: fen,
                        currentMoveSequence: _boardMoves,
                        repertoireMovesAtPosition: () => const {},
                        onPlayMove: (san) {
                          if (_plan.phase == PlanPhase.start) {
                            _replaceStartMoves([..._startMoves, san]);
                          } else {
                            setState(() {
                              _previewMoves = [..._boardMoves, san];
                            });
                          }
                        },
                        onHoverMove: (move) => _hoverArrow.value = move == null
                            ? null
                            : BoardAnnotation.arrowFromUci(move.uci),
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
        const Row(
          children: [
            Text(
              'Where should this start?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            SizedBox(width: 6),
            Tooltip(
              waitDuration: Duration(milliseconds: 300),
              message:
                  'Enter one move sequence per line, starting at move one. Select a line to preview or extend it on the board.',
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
                onSelected: _preparing || !_startTextValid
                    ? null
                    : (_) => _replaceStartMoves(start),
              ),
            ChoiceChip(
              label: const Text(
                'Start position',
                style: TextStyle(fontSize: 12),
              ),
              selected: _startMoves.isEmpty,
              onSelected: _preparing || !_startTextValid
                  ? null
                  : (_) => _replaceStartMoves([]),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('plan-starting-lines'),
          enabled: !_preparing,
          minLines: 3,
          maxLines: 7,
          controller: _movesText,
          onChanged: _parseTypedMoves,
          style: const TextStyle(
            fontSize: 13,
            fontFamily: AppTextStyles.monoFamily,
          ),
          decoration: InputDecoration(
            labelText: 'Starting lines — one per row',
            helperText:
                'Optional name: Main KID | 1.d4 Nf6 2.c4 g6\nEach row starts at move one. Starting moves are included in the PGN.',
            helperMaxLines: 3,
            errorText: _startError,
            errorMaxLines: 4,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              key: const ValueKey('plan-add-start'),
              onPressed: _preparing || !_startTextValid ? null : _addStart,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add starting position'),
            ),
            if (_startingLines.length > 1)
              TextButton(
                key: const ValueKey('plan-remove-start'),
                onPressed: _preparing || !_startTextValid ? null : _removeStart,
                child: const Text('Remove selected position'),
              ),
          ],
        ),
        if (_startingLines.length > 1) ...[
          const SizedBox(height: 8),
          const Text('Preview a starting line', style: AppTextStyles.caption),
          Wrap(
            spacing: 6,
            children: [
              for (final (index, line) in _startingLines.indexed)
                ChoiceChip(
                  key: ValueKey('plan-preview-$index'),
                  label: Text(
                    line.name.isEmpty ? 'Line ${index + 1}' : line.name,
                  ),
                  selected: _selectedStart == index,
                  onSelected: _preparing
                      ? null
                      : (_) {
                          if (!mounted) return;
                          setState(() {
                            _selectedStart = index;
                            _startMoves = List.of(line.moves);
                            _previewMoves = null;
                          });
                        },
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Guided choices')),
            ButtonSegment(value: false, label: Text('Use these positions')),
          ],
          selected: {_guided},
          showSelectedIcon: false,
          onSelectionChanged: _preparing
              ? null
              : (values) {
                  if (!mounted) return;
                  setState(() => _guided = values.first);
                },
        ),
        const SizedBox(height: 8),
        Text(
          _guided
              ? 'Ask setup questions for each starting line, then review the whole plan.'
              : 'Create one chapter per starting line using ChessDB compact repertoire settings. Review and edit the build settings before starting.',
          style: AppTextStyles.caption,
        ),
        if (_guided) ...[
          const SizedBox(height: 20),
          const Text(
            'What should the questions walk?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          // Two walks, not a preference: the book asks at its tabiyas; your
          // games ask at every position you actually reached, so answering
          // them all turns your games into a repertoire.
          SegmentedButton<PlanBasis>(
            segments: const [
              ButtonSegment(
                value: PlanBasis.book,
                label: Text('Opening book', style: TextStyle(fontSize: 12)),
              ),
              ButtonSegment(
                value: PlanBasis.ownGames,
                label: Text('My games', style: TextStyle(fontSize: 12)),
              ),
            ],
            selected: {_basis},
            showSelectedIcon: false,
            onSelectionChanged: _preparing
                ? null
                : (sel) => setState(() => _basis = sel.first),
          ),
          const SizedBox(height: 6),
          Text(switch (_basis) {
            PlanBasis.book =>
              'Asks where the opening book forks: which of the main systems '
                  'you play, and which of the opponent\'s moves get a line.',
            PlanBasis.ownGames => _ownGamesNote ?? 'Reading your games…',
          }, style: AppTextStyles.caption),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Spacer(),
            FilledButton.icon(
              onPressed: _preparing || !_canBegin
                  ? null
                  : () => unawaited(_begin()),
              icon: _preparing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward, size: 18),
              label: Text(
                _preparing
                    ? 'Preparing…'
                    : _guided
                    ? 'Next'
                    : 'Review & build',
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Walking the book needs nothing; walking your games needs some.
  bool get _canBegin =>
      _startError == null &&
      (!_guided || _basis == PlanBasis.book || (_ownGamesCount ?? 0) > 0);

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
    final whiteToMove = isWhiteToMove(step.fen);
    final title = ours
        ? 'How do you play here?'
        : 'Which replies do you want to set up?';
    final manual = _plan.isManual(step.moves);
    final subtitle = manual
        ? 'Setting up by hand — no more prompts on this line. Press '
              '"Generate from here" when it\'s deep enough.'
        : ours
        ? 'Pick your move — click a row or play it on the board.'
        : _plan.basis == PlanBasis.ownGames
        ? 'Ticked replies are set up as their own lines — the ones you met '
              'in ${_plan.ownFloor} games or more come ticked. Play a move on '
              'the board to add a reply.'
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
              // Both sides flex: the games walk adds "N of your games" to the
              // right-hand label, and a long line name on the left, so a Row
              // of two intrinsic Texts overflows a narrow card.
              Row(
                children: [
                  Flexible(
                    child: Text(
                      step.positionName ?? _movesLabel(step.moves),
                      style: AppTextStyles.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Expanded, not Flexible: it takes the rest of the row so
                  // the label stays hard right, as the Spacer used to keep it.
                  Expanded(
                    child: Text(
                      [
                        if (_plan.basis == PlanBasis.ownGames)
                          '${step.ownGames} of your games',
                        ours
                            ? '${whiteToMove ? 'White' : 'Black'} (you) to move'
                            : 'Opponent to move',
                      ].join(' · '),
                      style: AppTextStyles.caption,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
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
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),
          )
        else
          // About ten rows tall; the rest scrolls. The buttons sit right
          // under the table, not at the bottom of the screen. Flexible so a
          // short window shrinks the table instead of overflowing.
          Flexible(
            child: ConstrainedBox(
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
                label: const Text('Continue'),
              ),
              OutlinedButton(
                onPressed: _editStarts,
                child: const Text('Edit starting lines'),
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
                  child: const Text('Generate from here'),
                )
              else
                OutlinedButton(
                  onPressed: () => unawaited(_plan.stopHere()),
                  child: const Text('Generate from here'),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _movesLabel(step.moves),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFamily: AppTextStyles.monoFamily,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Same position as ${_movesLabel(step.transposesTo ?? const [])}, '
            'which is already set up.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => unawaited(_plan.skipTransposition()),
                icon: const Icon(Icons.keyboard_return, size: 16),
                label: const Text('Use that line'),
              ),
              OutlinedButton(
                onPressed: () => unawaited(_plan.setUpSeparately()),
                child: const Text('Set up this move order separately'),
              ),
              OutlinedButton(
                onPressed: _editStarts,
                child: const Text('Edit starting lines'),
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
    final ours = isWhiteToMove(step.fen) ? widget.isWhite : !widget.isWhite;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            step.positionName ?? _movesLabel(step.moves),
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 2),
          Text(
            _movesLabel(step.moves),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFamily: AppTextStyles.monoFamily,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _plan.basis == PlanBasis.ownGames
                ? 'Your games thin out here: ${step.ownGames} of them '
                      '${step.ownGames == 1 ? 'reaches' : 'reach'} this, '
                      'fewer than the ${_plan.ownFloor} a question needs. '
                      '${ours ? 'You' : 'Your opponent'} to move.'
                : 'No more ECO codes from here. '
                      '${ours ? 'You' : 'Your opponent'} to move · '
                      '${(step.reachProb * 100).toStringAsFixed(step.reachProb >= 0.1 ? 0 : 1)}% '
                      'of games reach this.',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => unawaited(_plan.confirmLeaf()),
                icon: const Icon(Icons.keyboard_return, size: 16),
                label: const Text('Generate from here'),
              ),
              OutlinedButton(
                onPressed: () => unawaited(_plan.continueSetup()),
                child: const Text('Keep setting up this line'),
              ),
              OutlinedButton(
                onPressed: _editStarts,
                child: const Text('Edit starting lines'),
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
                'it are the build’s starting points. Rename or drop any '
                'before anything runs. Builds run in order; the limits below '
                'apply to each starting position.',
                style: AppTextStyles.caption,
              ),
              const SizedBox(height: 12),
              for (final group in _groupChapters(plan.chapters).entries)
                _ChapterGroup(
                  family: group.key,
                  chapters: group.value,
                  initiallyExpanded: group.value.length <= 4,
                  row: (c) => _ChapterEditRow(
                    key: ObjectKey(c),
                    chapter: c,
                    onRename: (name) {
                      if (mounted) setState(() => c.name = name);
                    },
                    onRemove: () {
                      if (mounted) setState(() => plan.chapters.remove(c));
                    },
                  ),
                ),
              const SizedBox(height: 20),
              const _SectionTitle('Build settings for every chapter'),
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
                onPressed: _editStarts,
                child: const Text('Edit starting lines'),
              ),
              OutlinedButton(
                onPressed: _plan.canGoBack
                    ? () {
                        if (!mounted) return;
                        _reviewConfig =
                            _configKey.currentState?.toConfig(
                              startFen: kStandardStartFen,
                              playAsWhite: widget.isWhite,
                            ) ??
                            _reviewConfig;
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
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
                fontSize: 12,
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
        fontSize: 12,
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
    super.key,
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
                    style: AppTextStyles.caption,
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
