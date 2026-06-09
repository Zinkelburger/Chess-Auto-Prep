/// Data model for a PGN source attached to a generation or import session.
///
/// Each source represents one PGN file or pasted blob, optionally sliced.
library;

import 'dart:convert';

import 'pgn_filter_models.dart';

/// Which side this PGN source covers.
enum PgnSourceColor { white, black }

/// A single PGN source (file or paste) with optional slice configuration.
class PgnSource {
  final String id;
  String name;
  String? filePath;
  String? rawPgnContent;
  PgnSourceColor color;
  SliceConfig? sliceConfig;
  List<int>? matchedIndices;
  int totalGames;

  PgnSource({
    required this.id,
    required this.name,
    this.filePath,
    this.rawPgnContent,
    this.color = PgnSourceColor.white,
    this.sliceConfig,
    this.matchedIndices,
    this.totalGames = 0,
  });

  /// Whether a slice is actively filtering (not "All Lines").
  bool get isSliced => sliceConfig != null && !sliceConfig!.isEmpty;

  /// Number of games that pass the slice filter (or total if no slice).
  int get effectiveGameCount =>
      isSliced ? (matchedIndices?.length ?? 0) : totalGames;

  /// Human-readable summary for the source row chip.
  String get sliceLabel =>
      isSliced ? '$effectiveGameCount/$totalGames' : 'All Lines';

  static int _counter = 0;
  static String generateId() {
    _counter++;
    return '${DateTime.now().microsecondsSinceEpoch}_$_counter';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (filePath != null) 'filePath': filePath,
        'color': color.name,
        'totalGames': totalGames,
        if (sliceConfig != null && !sliceConfig!.isEmpty)
          'sliceConfig': sliceConfig!.toJsonString(),
        if (matchedIndices != null) 'matchedIndices': matchedIndices,
      };

  factory PgnSource.fromJson(Map<String, dynamic> json) => PgnSource(
        id: json['id'] as String? ?? generateId(),
        name: json['name'] as String? ?? 'Untitled',
        filePath: json['filePath'] as String?,
        color: PgnSourceColor.values.firstWhere(
          (c) => c.name == (json['color'] as String? ?? 'white'),
          orElse: () => PgnSourceColor.white,
        ),
        totalGames: json['totalGames'] as int? ?? 0,
        sliceConfig: json['sliceConfig'] != null
            ? SliceConfig.fromJsonString(json['sliceConfig'] as String)
            : null,
        matchedIndices: (json['matchedIndices'] as List<dynamic>?)
            ?.cast<int>(),
      );

  String toJsonString() => jsonEncode(toJson());

  factory PgnSource.fromJsonString(String s) =>
      PgnSource.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
