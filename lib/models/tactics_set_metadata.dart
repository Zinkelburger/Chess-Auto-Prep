/// Metadata for a named tactics puzzle set (one CSV file in the
/// `tactics_sets/` documents subdirectory).
///
/// Mirrors [RepertoireMetadata]: an immutable, typed description used by the
/// set picker and set-management UI without loading the full CSV.
library;

class TacticsSetMetadata {
  final String filePath;
  final String name;
  final int positionCount;
  final DateTime lastModified;

  const TacticsSetMetadata({
    required this.filePath,
    required this.name,
    this.positionCount = 0,
    required this.lastModified,
  });

  TacticsSetMetadata copyWith({
    String? filePath,
    String? name,
    int? positionCount,
    DateTime? lastModified,
  }) {
    return TacticsSetMetadata(
      filePath: filePath ?? this.filePath,
      name: name ?? this.name,
      positionCount: positionCount ?? this.positionCount,
      lastModified: lastModified ?? this.lastModified,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TacticsSetMetadata && filePath == other.filePath;

  @override
  int get hashCode => filePath.hashCode;

  @override
  String toString() =>
      'TacticsSetMetadata(name: $name, positions: $positionCount, path: $filePath)';
}
