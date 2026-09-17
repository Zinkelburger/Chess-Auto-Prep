import '../../../constants/engine_defaults.dart';
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
  set cores(int value) => submit({
    'engine_settings.cores': editing.withValues({
      ...editing.values,
      'engine_settings.cores': value,
    }).values['engine_settings.cores']!,
  });
  int get hashMb => committed.hashMb;
  set hashMb(int value) => submit({
    'engine_settings.hash_mb': editing.withValues({
      ...editing.values,
      'engine_settings.hash_mb': value,
    }).values['engine_settings.hash_mb']!,
  });
  int get depth => committed.depth;
  set depth(int value) {
    if (value < kMinDepth || value > kMaxDepth) return;
    submit({
      'engine_settings.depth': editing.withValues({
        ...editing.values,
        'engine_settings.depth': value,
      }).values['engine_settings.depth']!,
    });
  }

  int get multiPv => committed.multiPv;
  set multiPv(int value) {
    if (value < kMinMultiPv || value > kMaxMultiPv) return;
    submit({
      'engine_settings.multi_pv': editing.withValues({
        ...editing.values,
        'engine_settings.multi_pv': value,
      }).values['engine_settings.multi_pv']!,
    });
  }

  int get maxAnalysisMoves => committed.maxAnalysisMoves;
  set maxAnalysisMoves(int value) {
    if (value < kMinMaxAnalysisMoves || value > kMaxMaxAnalysisMoves) return;
    submit({
      'engine_settings.max_analysis_moves': editing.withValues({
        ...editing.values,
        'engine_settings.max_analysis_moves': value,
      }).values['engine_settings.max_analysis_moves']!,
    });
  }

  bool get showStockfish => committed.showStockfish;
  set showStockfish(bool value) => submit({
    'engine_settings.show_stockfish': editing.withValues({
      ...editing.values,
      'engine_settings.show_stockfish': value,
    }).values['engine_settings.show_stockfish']!,
  });
  bool get showMaia => committed.showMaia;
  set showMaia(bool value) => submit({
    'engine_settings.show_maia': editing.withValues({
      ...editing.values,
      'engine_settings.show_maia': value,
    }).values['engine_settings.show_maia']!,
  });
  bool get showProbability => committed.showProbability;
  set showProbability(bool value) => submit({
    'engine_settings.show_probability': editing.withValues({
      ...editing.values,
      'engine_settings.show_probability': value,
    }).values['engine_settings.show_probability']!,
  });
  bool get showEngineDock => committed.showEngineDock;
  set showEngineDock(bool value) => submit({
    'engine_settings.show_engine_dock': editing.withValues({
      ...editing.values,
      'engine_settings.show_engine_dock': value,
    }).values['engine_settings.show_engine_dock']!,
  });
  bool get showExpectimaxDock => committed.showExpectimaxDock;
  set showExpectimaxDock(bool value) => submit({
    'engine_settings.show_expectimax_dock': editing.withValues({
      ...editing.values,
      'engine_settings.show_expectimax_dock': value,
    }).values['engine_settings.show_expectimax_dock']!,
  });
  OpponentProbabilityMode get opponentProbabilityMode =>
      committed.opponentProbabilityMode;
  set opponentProbabilityMode(OpponentProbabilityMode value) => submit({
    'engine_settings.opponent_prob_mode': editing.withValues({
      ...editing.values,
      'engine_settings.opponent_prob_mode': value.storageKey,
    }).values['engine_settings.opponent_prob_mode']!,
  });
  String get explorerDatabase => committed.explorerDatabase;
  set explorerDatabase(String value) => submit({
    'engine_settings.explorer_database': editing.withValues({
      ...editing.values,
      'engine_settings.explorer_database': value,
    }).values['engine_settings.explorer_database']!,
  });
  String get explorerSpeeds => committed.explorerSpeeds;
  set explorerSpeeds(String value) => submit({
    'engine_settings.explorer_speeds': editing.withValues({
      ...editing.values,
      'engine_settings.explorer_speeds': value,
    }).values['engine_settings.explorer_speeds']!,
  });
  String get explorerRatings => committed.explorerRatings;
  set explorerRatings(String value) => submit({
    'engine_settings.explorer_ratings': editing.withValues({
      ...editing.values,
      'engine_settings.explorer_ratings': value,
    }).values['engine_settings.explorer_ratings']!,
  });
  String get probabilityStartMoves => committed.probabilityStartMoves;
  set probabilityStartMoves(String value) => submit({
    'engine_settings.probability_start_moves': editing.withValues({
      ...editing.values,
      'engine_settings.probability_start_moves': value,
    }).values['engine_settings.probability_start_moves']!,
  });
  int get maiaElo => committed.maiaElo;
  set maiaElo(int value) {
    if (value < kMinMaiaElo || value > kMaxMaiaElo) return;
    submit({
      'engine_settings.maia_elo': editing.withValues({
        ...editing.values,
        'engine_settings.maia_elo': value,
      }).values['engine_settings.maia_elo']!,
    });
  }

  CandidateSource get candidateSourceOur => committed.candidateSourceOur;
  set candidateSourceOur(CandidateSource value) => submit({
    'engine_settings.candidate_source_our': editing.withValues({
      ...editing.values,
      'engine_settings.candidate_source_our': value.storageKey,
    }).values['engine_settings.candidate_source_our']!,
  });
  CandidateSource get candidateSourceOpp => committed.candidateSourceOpp;
  set candidateSourceOpp(CandidateSource value) => submit({
    'engine_settings.candidate_source_opp': editing.withValues({
      ...editing.values,
      'engine_settings.candidate_source_opp': value.storageKey,
    }).values['engine_settings.candidate_source_opp']!,
  });
  int get stockfishTopN => committed.stockfishTopN;
  set stockfishTopN(int value) {
    if (value < kMinStockfishTopN || value > kMaxStockfishTopN) return;
    submit({
      'engine_settings.stockfish_top_n': editing.withValues({
        ...editing.values,
        'engine_settings.stockfish_top_n': value,
      }).values['engine_settings.stockfish_top_n']!,
    });
  }

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
