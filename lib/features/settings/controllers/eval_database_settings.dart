import '../models/eval_database_configuration.dart';
import '../repositories/settings_section_storage.dart';
import 'section_settings_owner.dart';

/// One application-owned writer for evaluation-source preferences.
class EvalDatabaseSettings
    extends SectionSettingsOwner<EvalDatabaseConfiguration> {
  EvalDatabaseSettings(
    SettingsSectionStorage<EvalDatabaseConfiguration> storage,
  ) : super(storage, EvalDatabaseConfiguration());

  Future<void> setEnableCdbDirect(bool value) => setSelectionEnabled(
    pathKey: 'eval.cdbdirect.path',
    enabledKey: 'eval.cdbdirect.enabled',
    enabled: value,
  );
  Future<void> setCdbDirectReadAhead(bool value) =>
      edit({'eval.cdbdirect.read_ahead': value});
  Future<void> setEnableLichessEvals(bool value) => setSelectionEnabled(
    pathKey: 'eval.lichess.path',
    enabledKey: 'eval.lichess.enabled',
    enabled: value,
  );
  Future<void> setChessDbApiForExpectimax(bool value) =>
      edit({'expectimax.chessdb_api': value});
  Future<void> setExpectimaxProbePlies(int value) =>
      edit({'expectimax.probe_plies': value});

  Future<void> clearCdbDirectory(String expectedDirectory) => clearSelection(
    pathKey: 'eval.cdbdirect.path',
    expectedPath: expectedDirectory,
    enabledKey: 'eval.cdbdirect.enabled',
  );
  Future<void> clearLichessDirectory(String expectedDirectory) =>
      clearSelection(
        pathKey: 'eval.lichess.path',
        expectedPath: expectedDirectory,
        enabledKey: 'eval.lichess.enabled',
      );
  Future<void> clearCdbSelection() =>
      edit({'eval.cdbdirect.enabled': false, 'eval.cdbdirect.path': ''});

  Future<void> configureCdbDirectory(String path) =>
      edit({'eval.cdbdirect.path': path, 'eval.cdbdirect.enabled': true});
  Future<void> configureLichessDirectory(String path) =>
      edit({'eval.lichess.path': path, 'eval.lichess.enabled': true});
}
