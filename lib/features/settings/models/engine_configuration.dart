import '../../../constants/engine_defaults.dart';
import '../../../models/settings_enums.dart';
import 'section_configuration.dart';

class EngineConfiguration extends ImmutableSection<EngineConfiguration> {
  EngineConfiguration([
    Map<String, Object?> input = const {},
    this.maxCores = 1024,
  ]) : super({
         'engine_lifecycle.toggle_on':
             input['engine_lifecycle.toggle_on'] is bool
             ? input['engine_lifecycle.toggle_on'] as bool
             : true,
         'engine_settings.cores':
             (input['engine_settings.cores'] is int
                     ? input['engine_settings.cores'] as int
                     : kDefaultCores)
                 .clamp(1, maxCores),
         'engine_settings.hash_mb':
             (input['engine_settings.hash_mb'] is int
                     ? input['engine_settings.hash_mb'] as int
                     : kDefaultHashMb)
                 .clamp(kMinHashMb, kMaxHashMb),
         'engine_settings.depth':
             (input['engine_settings.depth'] is int
                     ? input['engine_settings.depth'] as int
                     : kDefaultDepth)
                 .clamp(kMinDepth, kMaxDepth),
         'engine_settings.multi_pv':
             (input['engine_settings.multi_pv'] is int
                     ? input['engine_settings.multi_pv'] as int
                     : kDefaultMultiPv)
                 .clamp(kMinMultiPv, kMaxMultiPv),
         'engine_settings.max_analysis_moves':
             (input['engine_settings.max_analysis_moves'] is int
                     ? input['engine_settings.max_analysis_moves'] as int
                     : kDefaultMaxAnalysisMoves)
                 .clamp(kMinMaxAnalysisMoves, kMaxMaxAnalysisMoves),
         'engine_settings.show_stockfish':
             input['engine_settings.show_stockfish'] is bool
             ? input['engine_settings.show_stockfish'] as bool
             : kDefaultShowStockfish,
         'engine_settings.show_maia': input['engine_settings.show_maia'] is bool
             ? input['engine_settings.show_maia'] as bool
             : kDefaultShowMaia,
         'engine_settings.show_probability':
             input['engine_settings.show_probability'] is bool
             ? input['engine_settings.show_probability'] as bool
             : kDefaultShowProbability,
         'engine_settings.show_engine_dock':
             input['engine_settings.show_engine_dock'] is bool
             ? input['engine_settings.show_engine_dock'] as bool
             : kDefaultShowEngineDock,
         'engine_settings.show_expectimax_dock':
             input['engine_settings.show_expectimax_dock'] is bool
             ? input['engine_settings.show_expectimax_dock'] as bool
             : kDefaultShowExpectimaxDock,
         'engine_settings.opponent_prob_mode':
             OpponentProbabilityMode.fromStorageKey(
               input['engine_settings.opponent_prob_mode'] is String
                   ? input['engine_settings.opponent_prob_mode'] as String
                   : 'maia_lichess_fallback',
             ).storageKey,
         'engine_settings.explorer_database':
             input['engine_settings.explorer_database'] == 'masters'
             ? 'masters'
             : kDefaultExplorerDatabase,
         'engine_settings.explorer_speeds':
             input['engine_settings.explorer_speeds'] is String &&
                 (input['engine_settings.explorer_speeds'] as String).isNotEmpty
             ? input['engine_settings.explorer_speeds'] as String
             : kDefaultExplorerSpeeds,
         'engine_settings.explorer_ratings':
             input['engine_settings.explorer_ratings'] is String &&
                 (input['engine_settings.explorer_ratings'] as String)
                     .isNotEmpty
             ? input['engine_settings.explorer_ratings'] as String
             : kDefaultExplorerRatings,
         'engine_settings.probability_start_moves':
             input['engine_settings.probability_start_moves'] is String
             ? input['engine_settings.probability_start_moves'] as String
             : '',
         'engine_settings.maia_elo':
             (input['engine_settings.maia_elo'] is int
                     ? input['engine_settings.maia_elo'] as int
                     : kDefaultMaiaElo)
                 .clamp(kMinMaiaElo, kMaxMaiaElo),
         'engine_settings.candidate_source_our': CandidateSource.fromStorageKey(
           input['engine_settings.candidate_source_our'] is String
               ? input['engine_settings.candidate_source_our'] as String
               : 'maia',
         ).storageKey,
         'engine_settings.candidate_source_opp': CandidateSource.fromStorageKey(
           input['engine_settings.candidate_source_opp'] is String
               ? input['engine_settings.candidate_source_opp'] as String
               : 'maia',
         ).storageKey,
         'engine_settings.stockfish_top_n':
             (input['engine_settings.stockfish_top_n'] is int
                     ? input['engine_settings.stockfish_top_n'] as int
                     : kDefaultStockfishTopN)
                 .clamp(kMinStockfishTopN, kMaxStockfishTopN),
         'engine_settings.muted_columns':
             input['engine_settings.muted_columns'] is String
             ? input['engine_settings.muted_columns'] as String
             : '',
       });
  bool get enabled => values['engine_lifecycle.toggle_on'] as bool;
  final int maxCores;
  @override
  EngineConfiguration withValues(Map<String, Object?> values) =>
      EngineConfiguration(values, maxCores);
  int get cores => values['engine_settings.cores'] as int;
  int get hashMb => values['engine_settings.hash_mb'] as int;
  int get depth => values['engine_settings.depth'] as int;
  int get multiPv => values['engine_settings.multi_pv'] as int;
  int get maxAnalysisMoves =>
      values['engine_settings.max_analysis_moves'] as int;
  bool get showStockfish => values['engine_settings.show_stockfish'] as bool;
  bool get showMaia => values['engine_settings.show_maia'] as bool;
  bool get showProbability =>
      values['engine_settings.show_probability'] as bool;
  bool get showEngineDock => values['engine_settings.show_engine_dock'] as bool;
  bool get showExpectimaxDock =>
      values['engine_settings.show_expectimax_dock'] as bool;
  OpponentProbabilityMode get opponentProbabilityMode =>
      OpponentProbabilityMode.fromStorageKey(
        values['engine_settings.opponent_prob_mode'] as String,
      );
  String get explorerDatabase =>
      values['engine_settings.explorer_database'] as String;
  String get explorerSpeeds =>
      values['engine_settings.explorer_speeds'] as String;
  String get explorerRatings =>
      values['engine_settings.explorer_ratings'] as String;
  String get probabilityStartMoves =>
      values['engine_settings.probability_start_moves'] as String;
  int get maiaElo => values['engine_settings.maia_elo'] as int;
  CandidateSource get candidateSourceOur => CandidateSource.fromStorageKey(
    values['engine_settings.candidate_source_our'] as String,
  );
  CandidateSource get candidateSourceOpp => CandidateSource.fromStorageKey(
    values['engine_settings.candidate_source_opp'] as String,
  );
  int get stockfishTopN => values['engine_settings.stockfish_top_n'] as int;
  Set<String> get mutedAnalysisColumns => Set.unmodifiable(
    (values['engine_settings.muted_columns'] as String)
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty),
  );
  bool get fetchMaiaForOpponent =>
      opponentProbabilityMode == OpponentProbabilityMode.maia ||
      opponentProbabilityMode == OpponentProbabilityMode.maiaLichessFallback;
  bool isAnalysisColumnMuted(String id) => mutedAnalysisColumns.contains(id);
  int get analysisConfigRevision => Object.hashAll(
    values.entries
        .where((entry) => entry.key != 'engine_settings.muted_columns')
        .map((entry) => entry.value),
  );
}
