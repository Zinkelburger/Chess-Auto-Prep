part of 'generation_config_form.dart';

/// What one numeric knob accepts: the name the error message uses, whether
/// it must be a whole number, and the range the build can work with.
class _NumSpec {
  const _NumSpec(
    this.label, {
    required this.isInt,
    required this.min,
    required this.max,
  });

  final String label;
  final bool isInt;
  final num min;
  final num max;

  String get rangeText => '$min–$max';

  String? rangeProblem(num value) =>
      value < min || value > max ? 'Must be $rangeText' : null;
}

abstract class _GenerationConfigFormStateBase
    extends State<GenerationConfigForm> {
  /// The three sub-editors' state, owned here rather than reached into
  /// through the widgets' [GlobalKey]s.
  ///
  /// Each of their widgets lives behind an expander or a build-source switch,
  /// so none of them is guaranteed to be mounted when the form seeds it or
  /// reads it back at Start — which is exactly what a `currentState` read
  /// cannot express. Owning the state makes the widgets pure views: they may
  /// be built conditionally, and `toConfig` needs no null fallbacks for
  /// values the user did set.
  final EvalSourcesController _evalSources = EvalSourcesController();
  final SkeletonPlanController _skeleton = SkeletonPlanController();
  final PgnSourcesController _pgnSources = PgnSourcesController();

  bool _cdbDirectAvailable = false;

  /// Every text controller the form owns, in creation order.
  ///
  /// Controllers are made by [_ctrl] and disposed together, so adding a knob
  /// cannot leak one — the previous hand-written dispose list had already
  /// missed two.
  final List<TextEditingController> _ownedControllers = [];

  /// Creates a controller owned — and therefore disposed — by this form.
  TextEditingController _ctrl([String text = '']) {
    final controller = TextEditingController(text: text);
    _ownedControllers.add(controller);
    return controller;
  }

  @override
  void dispose() {
    for (final controller in _ownedControllers) {
      controller.dispose();
    }
    _evalSources.dispose();
    _skeleton.dispose();
    _pgnSources.dispose();
    super.dispose();
  }

  /// The config this form was last seeded from, and the base every
  /// [toConfig] result is built on top of.
  ///
  /// The form owns fewer knobs than [TreeBuildConfig] has fields, and used to
  /// construct its result from scratch — so every field without a control
  /// silently reverted to a constructor default the moment a config passed
  /// through the form. Building on the seed instead makes the round trip
  /// lossless *by construction*: a field the form does not edit is carried,
  /// and a knob added to the config without a control cannot be dropped.
  ///
  /// Null until the form is seeded, which is the "brand new config" case.
  TreeBuildConfig? _seedConfig;

  TreeBuildConfig get _configSeed =>
      _seedConfig ??
      TreeBuildConfig.formDefaults(
        startFen: '',
        playAsWhite: widget.playAsWhite,
      );

  late final TextEditingController _maxPlyCtrl = _ctrl('4');
  late final TextEditingController _evalGuardCtrl = _ctrl('30');
  late final TextEditingController _maiaEloCtrl = _ctrl('2200');

  late final TextEditingController _oppMaxChildrenCtrl = _ctrl('4');
  late final TextEditingController _oppMassTargetCtrl = _ctrl('0.80');
  late final TextEditingController _timeBudgetCtrl = _ctrl('0');
  bool _verifyFinal = true;
  bool _trapsOnly = false;

  late final TextEditingController _dbMinGamesCtrl = _ctrl('5');
  late final TextEditingController _dbMinProbCtrl = _ctrl('0.05');
  late final TextEditingController _minEloCtrl = _ctrl('0');

  late final TextEditingController _engineTailCtrl = _ctrl('6');

  bool _rankLinesByImportance = true;
  MoveAnnotationDetail _annotationDetail = MoveAnnotationDetail.none;

  bool _organizeIntoChapters = true;
  bool _chaptersByEco = false;
  bool _bookEngineFallback = false;
  late final TextEditingController _maxLinesPerChapterCtrl = _ctrl('40');
  late final TextEditingController _minLinesPerChapterCtrl = _ctrl('5');
  late final TextEditingController _modelGameCountCtrl = _ctrl('6');
  late final TextEditingController _modelGameMinEloCtrl = _ctrl('2200');
  bool _refutationLines = true;
  bool _alternativeLines = true;
  bool _useMasterGames = true;
  bool _downloadMasterGamesIfMissing = true;

  late final TextEditingController _bookTailMaxPlyCtrl = _ctrl('40');
  late final TextEditingController _bookTieBreakCtrl = _ctrl('0');

  SelectionMode _selectionMode = SelectionMode.expectimax;
  SearchAlgorithm _searchAlgorithm = SearchAlgorithm.pure;
  BuildMode _buildMode = BuildMode.stockfishExpectimax;

  /// Build sources whose selection has nothing for the deep verification
  /// pass to re-check: the move came from a database, not from a search this
  /// app can second-guess at greater depth.
  bool get _noVerifyMode =>
      _buildMode == BuildMode.maiaDbExplore ||
      _buildMode == BuildMode.chessDbBook;

  /// Whether this build source runs Stockfish at all, so Engine depth means
  /// something.  The ChessDB book only does when its engine fallback is on.
  bool get _usesEngineDepth => switch (_buildMode) {
    BuildMode.maiaDbExplore => false,
    BuildMode.chessDbBook => _bookEngineFallback,
    _ => true,
  };

  /// Evaluation databases expander. The section is built only while open —
  /// its values live in [_evalSources], not in the widget.
  bool _showEvalSources = false;
  bool _showSkeleton = false;

  /// Named saved profiles (name → config JSON), cached from
  /// [GenerationPresetStore] for the presets menu.
  final GenerationPresetStore _presetStore = GenerationPresetStore();
  Map<String, Map<String, dynamic>> _savedPresets = {};

  /// Every numeric knob with what it accepts.  [toConfig] used to fall back
  /// to a default whenever a field failed to parse, so "20.5" in Max line
  /// length silently built to 20; now Start refuses and names the field, and
  /// the field itself shows the problem while it is being typed.
  late final Map<TextEditingController, _NumSpec> _numSpecs = {
    _maxPlyCtrl: const _NumSpec(
      'Max line length',
      isInt: true,
      min: 1,
      max: 200,
    ),
    _evalGuardCtrl: const _NumSpec(
      'Max eval loss vs best',
      isInt: true,
      min: 0,
      max: 2000,
    ),
    _maiaEloCtrl: const _NumSpec(
      'Opponent rating',
      isInt: true,
      min: 500,
      max: 3500,
    ),
    _oppMaxChildrenCtrl: const _NumSpec(
      'Opponent replies per position',
      isInt: true,
      min: 1,
      max: 50,
    ),
    _oppMassTargetCtrl: const _NumSpec(
      'Reply coverage target',
      isInt: false,
      min: 0,
      max: 1,
    ),
    _timeBudgetCtrl: const _NumSpec(
      'Stop after',
      isInt: true,
      min: 0,
      max: 24 * 60,
    ),
    _dbMinGamesCtrl: const _NumSpec(
      'Min games per move',
      isInt: true,
      min: 1,
      max: 1000000,
    ),
    _dbMinProbCtrl: const _NumSpec(
      'Min move probability',
      isInt: false,
      min: 0,
      max: 1,
    ),
    _minEloCtrl: const _NumSpec(
      'Min player Elo',
      isInt: true,
      min: 0,
      max: 4000,
    ),
    _engineTailCtrl: const _NumSpec(
      'Engine continuation plies',
      isInt: true,
      min: 0,
      max: 40,
    ),
    _maxLinesPerChapterCtrl: const _NumSpec(
      'Max lines per chapter',
      isInt: true,
      min: 1,
      max: 100000,
    ),
    _minLinesPerChapterCtrl: const _NumSpec(
      'Min lines per chapter',
      isInt: true,
      min: 1,
      max: 100000,
    ),
    _modelGameCountCtrl: const _NumSpec(
      'Model games',
      isInt: true,
      min: 0,
      max: 100,
    ),
    _modelGameMinEloCtrl: const _NumSpec(
      'Model game minimum rating',
      isInt: true,
      min: 0,
      max: 4000,
    ),
    _bookTailMaxPlyCtrl: const _NumSpec(
      'Book tail depth',
      isInt: true,
      min: 0,
      max: 200,
    ),
    _bookTieBreakCtrl: const _NumSpec(
      'Book tie-break window',
      isInt: true,
      min: 0,
      max: 200,
    ),
  };

  /// Why [controller]'s text cannot be used, or null when it can.  Short
  /// enough to sit under the field.
  String? _numFieldProblem(TextEditingController controller) {
    if (_buildMode == BuildMode.stockfishExpectimax) {
      final retired = {
        _oppMaxChildrenCtrl,
        _oppMassTargetCtrl,
        _engineTailCtrl,
      };
      if (retired.contains(controller)) return null;
      if (identical(controller, _maxPlyCtrl) &&
          (int.tryParse(controller.text) ?? 0) > 64) {
        return 'Pure supports at most 64 half-moves';
      }
    }
    final spec = _numSpecs[controller];
    if (spec == null) return null;
    final text = controller.text.trim().replaceAll('%', '');
    if (text.isEmpty) return 'Enter a number';
    final num? value = spec.isInt ? int.tryParse(text) : double.tryParse(text);
    if (value == null) {
      return spec.isInt
          ? 'Whole number, ${spec.rangeText}'
          : 'Number, ${spec.rangeText}';
    }
    return spec.rangeProblem(value);
  }

  /// These options have no editable controls. Validate their saved values
  /// directly; Pure ignores the same retired tuning options as before.
  Map<_NumSpec, num> get _inheritedNumValues {
    final seed = _configSeed;
    return {
      if (_buildMode != BuildMode.stockfishExpectimax) ...{
        const _NumSpec(
          'Ignore lines rarer than',
          isInt: false,
          min: 0,
          max: 100,
        ): seed.minProbability * 100,
        const _NumSpec('Eval floor', isInt: true, min: -10000, max: 10000):
            seed.minEvalCp,
        const _NumSpec('Eval ceiling', isInt: true, min: -10000, max: 10000):
            seed.maxEvalCp,
        const _NumSpec('Opponent temperature', isInt: false, min: 0.1, max: 10):
            seed.oppPolicyTemperature,
        const _NumSpec(
          'Your candidate moves per position',
          isInt: true,
          min: 1,
          max: TreeBuildConfig.maxOurCandidates,
        ): seed.ourMultipv,
        const _NumSpec('Leaf eval confidence', isInt: false, min: 0, max: 1):
            seed.leafConfidence,
        const _NumSpec(
          'Alternative budget share',
          isInt: false,
          min: 0,
          max: 1,
        ): seed.ourAltDiscount,
        const _NumSpec(
          'Skip alternatives behind by',
          isInt: true,
          min: 0,
          max: 500,
        ): seed.fastAltGapCp,
        const _NumSpec('Blend with Maia', isInt: false, min: 0, max: 100000):
            seed.maiaPriorGames,
        const _NumSpec(
          'Always answer replies above',
          isInt: false,
          min: 0,
          max: 1,
        ): seed.coverMinProb,
        const _NumSpec('Verification depth', isInt: true, min: 0, max: 40):
            seed.verifyDepth,
        const _NumSpec('Setup tolerance', isInt: true, min: 0, max: 500):
            seed.setupToleranceCp,
        const _NumSpec('Natural-move tolerance', isInt: true, min: 0, max: 500):
            seed.memorabilityToleranceCp,
      },
      const _NumSpec(
        'Extra depth in master lines',
        isInt: true,
        min: 0,
        max: 40,
      ): seed.masterDepthBonusPlies,
      const _NumSpec(
        'Master search-order weight',
        isInt: false,
        min: 0,
        max: 3,
      ): seed.masterPriorityWeight,
      const _NumSpec('Opponent replies off-book', isInt: true, min: 0, max: 20):
          seed.offBookOppMaxChildren,
      const _NumSpec('Reply window', isInt: true, min: 0, max: 200):
          seed.replyWindowCp,
    };
  }

  /// The first numeric knob Start cannot use, as a message naming it.
  String? _firstNumFieldError() {
    for (final entry in _numSpecs.entries) {
      final problem = _numFieldProblem(entry.key);
      if (problem != null) {
        return '${entry.value.label}: ${problem.toLowerCase()}.';
      }
    }
    for (final entry in _inheritedNumValues.entries) {
      final problem = entry.key.rangeProblem(entry.value);
      if (problem != null) {
        return '${entry.key.label}: ${problem.toLowerCase()}.';
      }
    }
    return null;
  }
}
