import '../../../models/settings_enums.dart';
import '../../../utils/system_info.dart';
import '../models/engine_configuration.dart';
import '../repositories/settings_section_storage.dart';
import 'section_settings_owner.dart';

class EngineSettings extends SectionSettingsOwner<EngineConfiguration> {
  EngineSettings(
    SettingsSectionStorage<EngineConfiguration> storage, {
    int? maxCores,
  }) : super(storage, EngineConfiguration(const {}, maxCores ?? systemCores));
  static final int systemCores = getLogicalCores();
  static const colEval = 'eval',
      colLine = 'line',
      colDb = 'db',
      colMaia = 'maia';
  int get cores => committed.cores;
  set cores(int value) => submit({'engine_settings.cores': value});
  int get hashMb => committed.hashMb;
  set hashMb(int value) => submit({'engine_settings.hash_mb': value});
  int get depth => committed.depth;
  set depth(int value) => submit({'engine_settings.depth': value});

  int get multiPv => committed.multiPv;
  set multiPv(int value) => submit({'engine_settings.multi_pv': value});

  int get maxAnalysisMoves => committed.maxAnalysisMoves;
  set maxAnalysisMoves(int value) =>
      submit({'engine_settings.max_analysis_moves': value});

  bool get showStockfish => committed.showStockfish;
  set showStockfish(bool value) =>
      submit({'engine_settings.show_stockfish': value});
  bool get showMaia => committed.showMaia;
  set showMaia(bool value) => submit({'engine_settings.show_maia': value});
  bool get showProbability => committed.showProbability;
  set showProbability(bool value) =>
      submit({'engine_settings.show_probability': value});
  bool get showEngineDock => committed.showEngineDock;
  set showEngineDock(bool value) =>
      submit({'engine_settings.show_engine_dock': value});
  bool get showExpectimaxDock => committed.showExpectimaxDock;
  set showExpectimaxDock(bool value) =>
      submit({'engine_settings.show_expectimax_dock': value});
  OpponentProbabilityMode get opponentProbabilityMode =>
      committed.opponentProbabilityMode;
  set opponentProbabilityMode(OpponentProbabilityMode value) =>
      submit({'engine_settings.opponent_prob_mode': value.storageKey});
  String get explorerDatabase => committed.explorerDatabase;
  set explorerDatabase(String value) =>
      submit({'engine_settings.explorer_database': value});
  String get explorerSpeeds => committed.explorerSpeeds;
  set explorerSpeeds(String value) =>
      submit({'engine_settings.explorer_speeds': value});
  String get explorerRatings => committed.explorerRatings;
  set explorerRatings(String value) =>
      submit({'engine_settings.explorer_ratings': value});
  String get probabilityStartMoves => committed.probabilityStartMoves;
  set probabilityStartMoves(String value) =>
      submit({'engine_settings.probability_start_moves': value});
  int get maiaElo => committed.maiaElo;
  set maiaElo(int value) => submit({'engine_settings.maia_elo': value});

  CandidateSource get candidateSourceOur => committed.candidateSourceOur;
  set candidateSourceOur(CandidateSource value) =>
      submit({'engine_settings.candidate_source_our': value.storageKey});
  CandidateSource get candidateSourceOpp => committed.candidateSourceOpp;
  set candidateSourceOpp(CandidateSource value) =>
      submit({'engine_settings.candidate_source_opp': value.storageKey});
  int get stockfishTopN => committed.stockfishTopN;
  set stockfishTopN(int value) =>
      submit({'engine_settings.stockfish_top_n': value});

  Set<String> get mutedAnalysisColumns => committed.mutedAnalysisColumns;
  bool get fetchMaiaForOpponent => committed.fetchMaiaForOpponent;
  bool isAnalysisColumnMuted(String id) => committed.isAnalysisColumnMuted(id);
  int get analysisConfigRevision => committed.analysisConfigRevision;
  void toggleAnalysisColumnMuted(String id) {
    final columns = {...editing.mutedAnalysisColumns};
    if (!columns.remove(id)) columns.add(id);
    submit({'engine_settings.muted_columns': columns.join(',')});
  }
}
