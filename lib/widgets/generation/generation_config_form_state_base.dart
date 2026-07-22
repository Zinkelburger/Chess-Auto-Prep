part of 'generation_config_form.dart';

abstract class _GenerationConfigFormStateBase
    extends State<GenerationConfigForm> {
  final GlobalKey<EvalSourcesSectionState> _evalSourcesKey =
      GlobalKey<EvalSourcesSectionState>();
  final GlobalKey<PgnSourcesPanelState> _pgnSourcesKey =
      GlobalKey<PgnSourcesPanelState>();
  bool _cdbDirectAvailable = false;

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
  SearchAlgorithm _searchAlgorithm = SearchAlgorithm.fast;
  bool _wideOpening = true;
  bool _verifyFinal = true;

  final List<String> _pgnFilePaths = [];
  final TextEditingController _dbMinGamesCtrl = TextEditingController(
    text: '5',
  );
  final TextEditingController _dbMinProbCtrl = TextEditingController(
    text: '0.05',
  );
  final TextEditingController _minEloCtrl = TextEditingController(text: '0');

  LichessDatabase? _lichessDbOverride;
  bool _relativeEval = true;
  bool _preferNovelties = false;

  final TextEditingController _targetLinesCtrl = TextEditingController(
    text: '100',
  );
  bool _rankLinesByImportance = true;
  bool _annotateMoveProbabilities = true;
  bool _annotateMaiaOnly = true;

  final TextEditingController _lichessMinGamesCtrl = TextEditingController(
    text: '10',
  );
  final Set<String> _lichessSpeeds = {'blitz', 'rapid', 'classical'};
  final Set<String> _lichessRatings = {'2000', '2200', '2500'};

  SelectionMode _selectionMode = SelectionMode.expectimax;
  BuildMode _buildMode = BuildMode.stockfishExpectimax;
  bool _showAdvanced = false;
}
