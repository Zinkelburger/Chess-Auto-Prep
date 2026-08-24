part of 'generation_config_form.dart';

abstract class _GenerationConfigFormStateBase
    extends State<GenerationConfigForm> {
  final GlobalKey<EvalSourcesSectionState> _evalSourcesKey =
      GlobalKey<EvalSourcesSectionState>();
  final GlobalKey<SkeletonPlanCardState> _skeletonKey =
      GlobalKey<SkeletonPlanCardState>();
  final GlobalKey<PgnSourcesPanelState> _pgnSourcesKey =
      GlobalKey<PgnSourcesPanelState>();
  bool _cdbDirectAvailable = false;

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

  final TextEditingController _cutoffCtrl = TextEditingController(text: '0.01');
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '20');
  final TextEditingController _engineDepthCtrl = TextEditingController(
    text: '$kDefaultGenerationEvalDepth',
  );
  late final TextEditingController _engineThreadsCtrl;
  final TextEditingController _evalGuardCtrl = TextEditingController(
    text: '30',
  );
  late final TextEditingController _minEvalCtrl;
  late final TextEditingController _maxEvalCtrl;
  final TextEditingController _maiaEloCtrl = TextEditingController(
    text: '2200',
  );
  final TextEditingController _oppPolicyTempCtrl = TextEditingController(
    text: '1.0',
  );

  final TextEditingController _multipvCtrl = TextEditingController(text: '4');
  final TextEditingController _oppMaxChildrenCtrl = TextEditingController(
    text: '4',
  );
  final TextEditingController _oppMassTargetCtrl = TextEditingController(
    text: '0.80',
  );
  final TextEditingController _leafConfidenceCtrl = TextEditingController(
    text: '1.0',
  );
  final TextEditingController _ourAltDiscountCtrl = TextEditingController(
    text: '0.25',
  );
  final TextEditingController _fastAltGapCtrl = TextEditingController(
    text: '30',
  );
  final TextEditingController _maiaPriorGamesCtrl = TextEditingController(
    text: '30',
  );
  final TextEditingController _coverMinProbCtrl = TextEditingController(
    text: '0.05',
  );
  final TextEditingController _verifyDepthCtrl = TextEditingController(
    text: '0',
  );
  final TextEditingController _setupMovesCtrl = TextEditingController();
  final TextEditingController _setupToleranceCtrl = TextEditingController(
    text: '30',
  );
  final TextEditingController _memorabilityToleranceCtrl =
      TextEditingController(text: '0');
  final TextEditingController _timeBudgetCtrl = TextEditingController(
    text: '0',
  );
  SearchAlgorithm _searchAlgorithm = SearchAlgorithm.fast;
  bool _wideOpening = true;
  bool _verifyFinal = true;
  bool _trapsOnly = false;

  final List<String> _pgnFilePaths = [];
  final TextEditingController _dbMinGamesCtrl = TextEditingController(
    text: '5',
  );
  final TextEditingController _dbMinProbCtrl = TextEditingController(
    text: '0.05',
  );
  final TextEditingController _minEloCtrl = TextEditingController(text: '0');

  bool _relativeEval = true;
  bool _preferNovelties = false;

  final TextEditingController _engineTailCtrl = TextEditingController(
    text: '6',
  );

  /// Coverage target as a percentage, which is how it is shown and typed.
  /// [TreeBuildConfig.lineCoverageTarget] holds the 0..1 fraction.
  final TextEditingController _lineCoverageCtrl = TextEditingController(
    text: '92',
  );
  final TextEditingController _targetLinesCtrl = TextEditingController(
    text: '0',
  );
  bool _rankLinesByImportance = true;
  MoveAnnotationDetail _annotationDetail = MoveAnnotationDetail.full;

  bool _organizeIntoChapters = true;
  final TextEditingController _maxLinesPerChapterCtrl = TextEditingController(
    text: '40',
  );
  final TextEditingController _minLinesPerChapterCtrl = TextEditingController(
    text: '5',
  );
  final TextEditingController _modelGameCountCtrl = TextEditingController(
    text: '6',
  );
  final TextEditingController _modelGameMinEloCtrl = TextEditingController(
    text: '2200',
  );
  bool _refutationLines = true;
  bool _alternativeLines = true;
  bool _useMasterGames = true;
  bool _downloadMasterGamesIfMissing = true;
  final TextEditingController _masterDepthBonusCtrl = TextEditingController(
    text: '10',
  );
  final TextEditingController _masterPriorityWeightCtrl = TextEditingController(
    text: '0.35',
  );
  final TextEditingController _offBookOppMaxChildrenCtrl =
      TextEditingController(text: '2');

  SelectionMode _selectionMode = SelectionMode.expectimax;
  BuildMode _buildMode = BuildMode.stockfishExpectimax;

  /// Evaluation databases expander.  The section stays MOUNTED while
  /// collapsed (Offstage, not conditional build): `toConfig`,
  /// `validateBeforeStart` and mid-build quota updates all reach it through
  /// [_evalSourcesKey], which must never be null.
  bool _showEvalSources = false;
  bool _showSkeleton = false;

  /// Named saved profiles (name → config JSON), cached from
  /// [GenerationPresetStore] for the presets menu.
  final GenerationPresetStore _presetStore = GenerationPresetStore();
  Map<String, Map<String, dynamic>> _savedPresets = {};
}
