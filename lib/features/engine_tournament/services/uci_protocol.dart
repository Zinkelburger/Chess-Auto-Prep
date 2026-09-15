/// The vocabulary a tournament shares with a UCI competitor: what a `go`
/// asks for, what a `bestmove` brings back, what the handshake reveals, and
/// the failure that turns a competitor into a forfeit.
///
/// No `dart:io` here. The arbiter ([EngineGameRunner]) only ever needs these
/// types plus the [PlayingEngine] contract, which is what lets it be tested
/// against scripted engines instead of processes.
library;

/// Anything that makes an engine unusable: it would not start, would not
/// speak UCI, went silent, or died.
///
/// Distinct from the shared `EngineInterruptError` family on purpose: those
/// mean "the app told its own Stockfish to stop", a clean unwind; this means
/// "the competitor let the game down", which the arbiter scores as a loss.
class UciFailure implements Exception {
  UciFailure(this.message);
  final String message;
  @override
  String toString() => 'UciFailure: $message';
}

/// One `option name … type …` line from the handshake.
class UciOptionInfo {
  const UciOptionInfo({
    required this.name,
    required this.type,
    this.defaultValue,
    this.min,
    this.max,
    this.values = const [],
  });

  /// Parse `option name Foo Bar type spin default 1 min 0 max 8`, or null
  /// when the line names no option.
  ///
  /// Names contain spaces, so the fields are split on the UCI keywords
  /// rather than on whitespace; every `var` starts a new choice.
  static UciOptionInfo? parse(String line) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.isEmpty || tokens.first != 'option') return null;
    final fields = <String, List<String>>{};
    final choices = <String>[];
    String? key;
    for (final token in tokens.skip(1)) {
      if (_keywords.contains(token)) {
        key = token;
        if (token == 'var') {
          choices.add('');
        } else {
          fields[token] = [];
        }
        continue;
      }
      if (key == null) continue;
      if (key == 'var') {
        choices[choices.length - 1] = '${choices.last} $token'.trim();
      } else {
        fields[key]!.add(token);
      }
    }
    final name = fields['name']?.join(' ').trim();
    if (name == null || name.isEmpty) return null;
    return UciOptionInfo(
      name: name,
      type: fields['type']?.join(' ').trim() ?? 'string',
      defaultValue: fields['default']?.join(' ').trim(),
      min: fields['min']?.join(' ').trim(),
      max: fields['max']?.join(' ').trim(),
      values: choices.where((v) => v.isNotEmpty).toList(),
    );
  }

  static const _keywords = {'name', 'type', 'default', 'min', 'max', 'var'};

  final String name;
  final String type;
  final String? defaultValue;
  final String? min;
  final String? max;
  final List<String> values;
}

/// What an engine says about itself before the first move.
class UciIdentity {
  const UciIdentity({
    required this.name,
    required this.author,
    required this.options,
  });

  final String name;
  final String author;
  final List<UciOptionInfo> options;

  bool supportsOption(String name) =>
      options.any((o) => o.name.toLowerCase() == name.toLowerCase());
}

/// The limits half of a `go` command.
class GoLimits {
  const GoLimits({
    this.whiteTimeMs,
    this.blackTimeMs,
    this.whiteIncrementMs,
    this.blackIncrementMs,
    this.movesToGo,
    this.movetimeMs,
    this.depth,
    this.nodes,
  });

  final int? whiteTimeMs;
  final int? blackTimeMs;
  final int? whiteIncrementMs;
  final int? blackIncrementMs;
  final int? movesToGo;
  final int? movetimeMs;
  final int? depth;
  final int? nodes;

  /// The `go …` line, or `go infinite` when nothing bounds the search.
  String toCommand() {
    final parts = <String>['go'];
    void add(String key, int? value) {
      if (value != null) parts.addAll([key, '$value']);
    }

    add('wtime', whiteTimeMs);
    add('btime', blackTimeMs);
    add('winc', whiteIncrementMs);
    add('binc', blackIncrementMs);
    add('movestogo', movesToGo);
    add('movetime', movetimeMs);
    add('depth', depth);
    add('nodes', nodes);
    if (parts.length == 1) parts.add('infinite');
    return parts.join(' ');
  }
}

/// The engine's answer to one `go`.
class EngineSearch {
  const EngineSearch({
    required this.bestMoveUci,
    required this.elapsedMs,
    this.ponderUci,
    this.scoreCp,
    this.scoreMate,
    this.depth = 0,
    this.nodes,
  });

  /// UCI move string, or `(none)` / `0000` when the engine sees no move.
  final String bestMoveUci;

  final String? ponderUci;

  /// Last reported score, in the **side-to-move** perspective UCI defines.
  final int? scoreCp;
  final int? scoreMate;

  final int depth;
  final int? nodes;
  final int elapsedMs;

  /// The spellings engines use for "no move here".
  static const noMoveTokens = {'', '(none)', '0000', 'null'};

  bool get hasMove => !noMoveTokens.contains(bestMoveUci);

  /// Mate scores collapsed onto the centipawn axis so adjudication can
  /// compare them with ordinary evaluations. A mate in 1 must outrank any
  /// finite advantage, and a longer mate must outrank a shorter one from the
  /// losing side's view.
  int? get comparableCp {
    final mate = scoreMate;
    if (mate == null) return scoreCp;
    // `mate 0` is UCI for "the side to move is mated" — a loss, and
    // emphatically not the level score a plain zero would read as.
    if (mate == 0) return -_mateCeilingCp;
    final magnitude = _mateCeilingCp - mate.abs();
    return mate > 0 ? magnitude : -magnitude;
  }

  /// Where the mate ladder starts on the centipawn axis.
  static const int _mateCeilingCp = 30000;
}

/// What the game runner needs from a competitor.
///
/// Narrower than `UciEngine` on purpose: the arbiter only ever asks for a
/// move, and an interface this small is what lets the game loop be tested
/// against scripted engines instead of real processes.
abstract interface class PlayingEngine {
  bool get isAlive;

  /// Tell the engine a new game is starting and wait for it to be ready.
  Future<void> newGame();

  Future<EngineSearch> search({
    required String startFen,
    required List<String> movesUci,
    required GoLimits limits,
    required Duration hardLimit,
  });

  /// Ask it to exit, then make sure it has.
  Future<void> quit();

  /// Stop it now, without waiting.
  void dispose();
}
