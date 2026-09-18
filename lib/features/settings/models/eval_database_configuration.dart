import 'section_configuration.dart';

/// Machine-local evaluation sources and the defaults for position probes.
class EvalDatabaseConfiguration
    extends ImmutableSection<EvalDatabaseConfiguration> {
  EvalDatabaseConfiguration([Map<String, Object?> input = const {}])
    : super({
        'eval.cdbdirect.enabled': _read<bool>(
          input,
          'eval.cdbdirect.enabled',
          false,
        ),
        'eval.cdbdirect.path': _read<String>(input, 'eval.cdbdirect.path', ''),
        'eval.cdbdirect.read_ahead': _read<bool>(
          input,
          'eval.cdbdirect.read_ahead',
          false,
        ),
        'eval.lichess.enabled': _read<bool>(
          input,
          'eval.lichess.enabled',
          false,
        ),
        'eval.lichess.path': _read<String>(input, 'eval.lichess.path', ''),
        'expectimax.chessdb_api': _read<bool>(
          input,
          'expectimax.chessdb_api',
          false,
        ),
        'expectimax.probe_plies': _read<int>(
          input,
          'expectimax.probe_plies',
          defaultExpectimaxProbePlies,
        ).clamp(minExpectimaxProbePlies, maxExpectimaxProbePlies),
      });

  static const defaultExpectimaxProbePlies = 12;
  static const minExpectimaxProbePlies = 2;
  static const maxExpectimaxProbePlies = 60;

  static T _read<T extends Object>(
    Map<String, Object?> input,
    String key,
    T fallback,
  ) {
    final value = input[key];
    if (value == null) return fallback;
    if (value is! T) throw FormatException('Invalid preference: $key');
    return value;
  }

  @override
  EvalDatabaseConfiguration withValues(Map<String, Object?> values) =>
      EvalDatabaseConfiguration(values);

  bool get enableCdbDirect => values['eval.cdbdirect.enabled'] as bool;
  String get cdbDirectPath => values['eval.cdbdirect.path'] as String;
  bool get cdbDirectReadAhead => values['eval.cdbdirect.read_ahead'] as bool;
  bool get enableLichessEvals => values['eval.lichess.enabled'] as bool;
  String get lichessEvalsPath => values['eval.lichess.path'] as String;
  bool get chessDbApiForExpectimax => values['expectimax.chessdb_api'] as bool;
  int get expectimaxProbePlies => values['expectimax.probe_plies'] as int;
}
