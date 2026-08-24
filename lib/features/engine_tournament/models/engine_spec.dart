/// One competitor: a UCI engine binary plus the options it plays under.
///
/// The rest of the app only ever talks to the bundled Stockfish. This is the
/// one place a *user-supplied* binary enters — pointed at from the engine
/// manager, verified before it is allowed to compete (see
/// `services/engine_verification.dart`), and stored here.
library;

class EngineSpec {
  const EngineSpec({
    required this.id,
    required this.name,
    this.executablePath,
    this.arguments = const [],
    this.options = const {},
    this.hashMb = 128,
    this.threads = 1,
    this.ponder = false,
  });

  /// Stable identity used by the registry and by tournament configs.
  final String id;

  /// Display name. Seeded from the engine's own `id name` at verification
  /// time, but the user can rename (two builds of the same engine in one
  /// match need telling apart).
  final String name;

  /// Absolute path to the UCI binary, or null for the app's bundled
  /// Stockfish — whose path is only known at runtime, so it is never stored.
  final String? executablePath;

  final List<String> arguments;

  /// Extra `setoption name X value Y` pairs applied after the handshake.
  final Map<String, String> options;

  final int hashMb;
  final int threads;

  /// Permanent brain. Off by default: pondering only makes sense when the
  /// opponent is thinking on its own clock, and it makes results noisier on
  /// a shared machine.
  final bool ponder;

  bool get isBundled => executablePath == null;

  /// Id of the always-present bundled-Stockfish participant.
  static const String bundledId = 'bundled-stockfish';

  static const EngineSpec bundledStockfish = EngineSpec(
    id: bundledId,
    name: 'Stockfish (bundled)',
  );

  EngineSpec copyWith({
    String? id,
    String? name,
    Object? executablePath = _unset,
    List<String>? arguments,
    Map<String, String>? options,
    int? hashMb,
    int? threads,
    bool? ponder,
  }) => EngineSpec(
    id: id ?? this.id,
    name: name ?? this.name,
    executablePath: executablePath == _unset
        ? this.executablePath
        : executablePath as String?,
    arguments: arguments ?? this.arguments,
    options: options ?? this.options,
    hashMb: hashMb ?? this.hashMb,
    threads: threads ?? this.threads,
    ponder: ponder ?? this.ponder,
  );

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (executablePath != null) 'executablePath': executablePath,
    if (arguments.isNotEmpty) 'arguments': arguments,
    if (options.isNotEmpty) 'options': options,
    'hashMb': hashMb,
    'threads': threads,
    'ponder': ponder,
  };

  factory EngineSpec.fromJson(Map<String, dynamic> json) => EngineSpec(
    id: json['id'] as String? ?? bundledId,
    name: json['name'] as String? ?? 'Engine',
    executablePath: json['executablePath'] as String?,
    arguments: (json['arguments'] as List?)?.cast<String>() ?? const [],
    options:
        (json['options'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {},
    hashMb: (json['hashMb'] as num?)?.toInt() ?? 128,
    threads: (json['threads'] as num?)?.toInt() ?? 1,
    ponder: json['ponder'] as bool? ?? false,
  );

  @override
  String toString() => 'EngineSpec($name, ${executablePath ?? "bundled"})';
}
