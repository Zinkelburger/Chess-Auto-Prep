/// What the repertoire picker and storage know about a repertoire file
/// without opening it.  Identity is the [filePath].
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
