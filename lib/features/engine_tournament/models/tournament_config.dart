/// Everything needed to reproduce a tournament, snapshotted at start time.
///
/// The engine list is a *copy* of the registry entries, not a list of ids:
/// renaming an engine or repointing it at a new build must not rewrite the
/// crosstable of a match that already happened.
library;

import '../../../constants/chess_constants.dart';
import 'adjudication_rules.dart';
import 'engine_spec.dart';
import 'time_control.dart';

enum TournamentFormat {
  /// Everyone plays everyone.
  roundRobin,

  /// The first engine plays every other one — cutechess's `gauntlet`.
  gauntlet,
}

extension TournamentFormatLabel on TournamentFormat {
  String get label => switch (this) {
    TournamentFormat.roundRobin => 'Round robin',
    TournamentFormat.gauntlet => 'Gauntlet',
  };
}

class TournamentConfig {
  const TournamentConfig({
    required this.name,
    required this.engines,
    this.startFen = kStandardStartFen,
    this.openingLabel = '',
    this.timeControl = const TimeControl.perMove(2000),
    this.gamesPerPairing = 10,
    this.alternateColors = true,
    this.format = TournamentFormat.roundRobin,
    this.concurrency = 1,
    this.adjudication = const AdjudicationRules(),
    this.annotateMoves = false,
    this.site = 'Chess Auto Prep',
  });

  final String name;

  /// Participants in seeding order. May repeat the same binary twice — an
  /// engine playing itself is the standard way to sanity-check a harness.
  final List<EngineSpec> engines;

  /// Position every game starts from.
  final String startFen;

  /// Free-text description of [startFen] for the PGN `Opening` tag.
  final String openingLabel;

  final TimeControl timeControl;

  /// Games each pairing plays. With [alternateColors] the colours swap every
  /// game, so an even number gives both engines the same number of Whites.
  final int gamesPerPairing;
  final bool alternateColors;

  final TournamentFormat format;

  /// Games run at once. One is the honest default — concurrent games share
  /// the CPU and make every result a little noisier — but a 22-core desktop
  /// running 1-thread engines can afford more.
  final int concurrency;

  final AdjudicationRules adjudication;

  /// Write cutechess-style `{+0.31/24 2.001s}` after every move.
  ///
  /// Off by default: a comment on every ply is what engine-testing tools want
  /// and what makes the PGN unreadable to a human opening the game in the
  /// viewer, and the viewer is what these games are usually opened in.
  final bool annotateMoves;

  final String site;

  bool get startsFromStandardPosition => startFen == kStandardStartFen;

  /// Total games the schedule will produce.
  int get totalGames => pairings.length * gamesPerPairing;

  /// Unordered engine pairs, as index pairs into [engines].
  List<({int a, int b})> get pairings {
    final out = <({int a, int b})>[];
    switch (format) {
      case TournamentFormat.roundRobin:
        for (var i = 0; i < engines.length; i++) {
          for (var j = i + 1; j < engines.length; j++) {
            out.add((a: i, b: j));
          }
        }
      case TournamentFormat.gauntlet:
        for (var j = 1; j < engines.length; j++) {
          out.add((a: 0, b: j));
        }
    }
    return out;
  }

  TournamentConfig copyWith({
    String? name,
    List<EngineSpec>? engines,
    String? startFen,
    String? openingLabel,
    TimeControl? timeControl,
    int? gamesPerPairing,
    bool? alternateColors,
    TournamentFormat? format,
    int? concurrency,
    AdjudicationRules? adjudication,
    bool? annotateMoves,
    String? site,
  }) => TournamentConfig(
    name: name ?? this.name,
    engines: engines ?? this.engines,
    startFen: startFen ?? this.startFen,
    openingLabel: openingLabel ?? this.openingLabel,
    timeControl: timeControl ?? this.timeControl,
    gamesPerPairing: gamesPerPairing ?? this.gamesPerPairing,
    alternateColors: alternateColors ?? this.alternateColors,
    format: format ?? this.format,
    concurrency: concurrency ?? this.concurrency,
    adjudication: adjudication ?? this.adjudication,
    annotateMoves: annotateMoves ?? this.annotateMoves,
    site: site ?? this.site,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'engines': engines.map((e) => e.toJson()).toList(),
    'startFen': startFen,
    'openingLabel': openingLabel,
    'timeControl': timeControl.toJson(),
    'gamesPerPairing': gamesPerPairing,
    'alternateColors': alternateColors,
    'format': format.name,
    'concurrency': concurrency,
    'adjudication': adjudication.toJson(),
    'annotateMoves': annotateMoves,
    'site': site,
  };

  factory TournamentConfig.fromJson(Map<String, dynamic> json) =>
      TournamentConfig(
        name: json['name'] as String? ?? 'Tournament',
        engines:
            (json['engines'] as List?)
                ?.map(
                  (e) =>
                      EngineSpec.fromJson(Map<String, dynamic>.from(e as Map)),
                )
                .toList() ??
            const [],
        startFen: json['startFen'] as String? ?? kStandardStartFen,
        openingLabel: json['openingLabel'] as String? ?? '',
        timeControl: json['timeControl'] == null
            ? const TimeControl.perMove(2000)
            : TimeControl.fromJson(
                Map<String, dynamic>.from(json['timeControl'] as Map),
              ),
        gamesPerPairing: (json['gamesPerPairing'] as num?)?.toInt() ?? 10,
        alternateColors: json['alternateColors'] as bool? ?? true,
        format: TournamentFormat.values.firstWhere(
          (f) => f.name == json['format'],
          orElse: () => TournamentFormat.roundRobin,
        ),
        concurrency: (json['concurrency'] as num?)?.toInt() ?? 1,
        adjudication: json['adjudication'] == null
            ? const AdjudicationRules()
            : AdjudicationRules.fromJson(
                Map<String, dynamic>.from(json['adjudication'] as Map),
              ),
        annotateMoves: json['annotateMoves'] as bool? ?? false,
        site: json['site'] as String? ?? 'Chess Auto Prep',
      );
}
