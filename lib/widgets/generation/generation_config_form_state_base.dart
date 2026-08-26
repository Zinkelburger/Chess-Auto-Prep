part of 'generation_config_form.dart';

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

  late final TextEditingController _cutoffCtrl = _ctrl('0.01');
  late final TextEditingController _maxPlyCtrl = _ctrl('20');
  late final TextEditingController _engineDepthCtrl = _ctrl(
    '$kDefaultGenerationEvalDepth',
  );
  late final TextEditingController _engineThreadsCtrl = _ctrl(
    defaultEngineThreads().toString(),
  );
  late final TextEditingController _evalGuardCtrl = _ctrl('30');
  late final TextEditingController _minEvalCtrl = _ctrl(
    widget.playAsWhite ? '0' : '-100',
  );
  late final TextEditingController _maxEvalCtrl = _ctrl(
    widget.playAsWhite ? '200' : '100',
  );
  late final TextEditingController _maiaEloCtrl = _ctrl('2200');
  late final TextEditingController _oppPolicyTempCtrl = _ctrl('1.0');

  late final TextEditingController _multipvCtrl = _ctrl('4');
  late final TextEditingController _oppMaxChildrenCtrl = _ctrl('4');
  late final TextEditingController _oppMassTargetCtrl = _ctrl('0.80');
  late final TextEditingController _leafConfidenceCtrl = _ctrl('1.0');
  late final TextEditingController _ourAltDiscountCtrl = _ctrl('0.25');
  late final TextEditingController _fastAltGapCtrl = _ctrl('30');
  late final TextEditingController _maiaPriorGamesCtrl = _ctrl('30');
  late final TextEditingController _coverMinProbCtrl = _ctrl('0.05');
  late final TextEditingController _verifyDepthCtrl = _ctrl('0');
  late final TextEditingController _setupMovesCtrl = _ctrl();
  late final TextEditingController _setupToleranceCtrl = _ctrl('30');
  late final TextEditingController _memorabilityToleranceCtrl = _ctrl('0');
  late final TextEditingController _timeBudgetCtrl = _ctrl('0');
  SearchAlgorithm _searchAlgorithm = SearchAlgorithm.fast;
  bool _wideOpening = true;
  bool _verifyFinal = true;
  bool _trapsOnly = false;

  late final TextEditingController _dbMinGamesCtrl = _ctrl('5');
  late final TextEditingController _dbMinProbCtrl = _ctrl('0.05');
  late final TextEditingController _minEloCtrl = _ctrl('0');

  bool _relativeEval = true;
  bool _preferNovelties = false;

  late final TextEditingController _engineTailCtrl = _ctrl('6');

  /// Coverage target as a percentage, which is how it is shown and typed.
  /// [TreeBuildConfig.lineCoverageTarget] holds the 0..1 fraction.
  late final TextEditingController _lineCoverageCtrl = _ctrl('92');
  late final TextEditingController _targetLinesCtrl = _ctrl('0');
  bool _rankLinesByImportance = true;
  MoveAnnotationDetail _annotationDetail = MoveAnnotationDetail.full;

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
  late final TextEditingController _masterDepthBonusCtrl = _ctrl('10');
  late final TextEditingController _masterPriorityWeightCtrl = _ctrl('0.35');
  late final TextEditingController _offBookOppMaxChildrenCtrl = _ctrl('2');

  late final TextEditingController _bookTailMaxPlyCtrl = _ctrl('40');
  late final TextEditingController _bookTieBreakCtrl = _ctrl('0');

  SelectionMode _selectionMode = SelectionMode.expectimax;
  BuildMode _buildMode = BuildMode.stockfishExpectimax;

  /// Build sources whose selection has nothing for the deep verification
  /// pass to re-check: the move came from a database, not from a search this
  /// app can second-guess at greater depth.
  bool get _noVerifyMode =>
      _buildMode == BuildMode.maiaDbExplore ||
      _buildMode == BuildMode.chessDbBook;

  /// Evaluation databases expander. The section is built only while open —
  /// its values live in [_evalSources], not in the widget.
  bool _showEvalSources = false;
  bool _showSkeleton = false;

  /// Named saved profiles (name → config JSON), cached from
  /// [GenerationPresetStore] for the presets menu.
  final GenerationPresetStore _presetStore = GenerationPresetStore();
  Map<String, Map<String, dynamic>> _savedPresets = {};
}
