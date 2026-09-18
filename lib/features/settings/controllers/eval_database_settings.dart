import '../models/eval_database_configuration.dart';
import '../repositories/settings_section_storage.dart';
import 'section_settings_owner.dart';

/// One application-owned writer for evaluation-source preferences.
class EvalDatabaseSettings
    extends SectionSettingsOwner<EvalDatabaseConfiguration> {
  EvalDatabaseSettings(
    SettingsSectionStorage<EvalDatabaseConfiguration> storage,
  ) : super(storage, EvalDatabaseConfiguration());

  static const defaultExpectimaxProbePlies =
      EvalDatabaseConfiguration.defaultExpectimaxProbePlies;
  static const minExpectimaxProbePlies =
      EvalDatabaseConfiguration.minExpectimaxProbePlies;
  static const maxExpectimaxProbePlies =
      EvalDatabaseConfiguration.maxExpectimaxProbePlies;

  bool get isLoaded => state.committed != null;
  bool get enableCdbDirect => committed.enableCdbDirect;
  String get cdbDirectPath => committed.cdbDirectPath;
  bool get cdbDirectReadAhead => committed.cdbDirectReadAhead;
  bool get enableLichessEvals => committed.enableLichessEvals;
  String get lichessEvalsPath => committed.lichessEvalsPath;
  bool get chessDbApiForExpectimax => committed.chessDbApiForExpectimax;
  int get expectimaxProbePlies => committed.expectimaxProbePlies;

  Future<void> setEnableCdbDirect(bool value) =>
      edit({'eval.cdbdirect.enabled': value});
  Future<void> setCdbDirectPath(String value) =>
      edit({'eval.cdbdirect.path': value});
  Future<void> setCdbDirectReadAhead(bool value) =>
      edit({'eval.cdbdirect.read_ahead': value});
  Future<void> setEnableLichessEvals(bool value) =>
      edit({'eval.lichess.enabled': value});
  Future<void> setLichessEvalsPath(String value) =>
      edit({'eval.lichess.path': value});
  Future<void> setChessDbApiForExpectimax(bool value) =>
      edit({'expectimax.chessdb_api': value});
  Future<void> setExpectimaxProbePlies(int value) =>
      edit({'expectimax.probe_plies': value});

  Future<void> configureCdbDirectory(String path) =>
      edit({'eval.cdbdirect.path': path, 'eval.cdbdirect.enabled': true});
  Future<void> configureLichessDirectory(String path) =>
      edit({'eval.lichess.path': path, 'eval.lichess.enabled': true});
}
