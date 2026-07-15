/// Typed replacement for the `Map<String, dynamic>` used to pass repertoire
/// metadata between screens, controllers, and services.
///
/// Previously every consumer cast `['filePath'] as String`, `['name'] as String`,
/// etc. from an untyped map.  This class makes the shape explicit, immutable,
/// and refactor-safe.
library;

class RepertoireMetadata {
  final String filePath;
  final String name;
  final int gameCount;
  final DateTime lastModified;

  const RepertoireMetadata({
    required this.filePath,
    required this.name,
    this.gameCount = 0,
    required this.lastModified,
  });

  /// Convert to the legacy `Map<String, dynamic>` shape for backward compat
  /// during incremental migration.
  Map<String, dynamic> toMap() => {
    'filePath': filePath,
    'name': name,
    'gameCount': gameCount,
    'lastModified': lastModified,
  };

  /// Create from the legacy `Map<String, dynamic>` shape.
  factory RepertoireMetadata.fromMap(Map<String, dynamic> map) {
    return RepertoireMetadata(
      filePath: map['filePath'] as String,
      name: map['name'] as String,
      gameCount: map['gameCount'] as int? ?? 0,
      lastModified: map['lastModified'] as DateTime? ?? DateTime.now(),
    );
  }

  RepertoireMetadata copyWith({
    String? filePath,
    String? name,
    int? gameCount,
    DateTime? lastModified,
  }) {
    return RepertoireMetadata(
      filePath: filePath ?? this.filePath,
      name: name ?? this.name,
      gameCount: gameCount ?? this.gameCount,
      lastModified: lastModified ?? this.lastModified,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RepertoireMetadata && filePath == other.filePath;

  @override
  int get hashCode => filePath.hashCode;

  @override
  String toString() =>
      'RepertoireMetadata(name: $name, games: $gameCount, path: $filePath)';
}
