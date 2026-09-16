import '../../../utils/safe_file_name.dart';

/// Complete, immutable contents of a new repertoire before it becomes visible.
class RepertoirePublication {
  RepertoirePublication({
    required String name,
    required Map<String, String> chapters,
    required this.gameCount,
    this.sourceContent,
  }) : name = requireSafeFileName(name),
       chapters = Map.unmodifiable(chapters) {
    if (chapters.isEmpty) throw ArgumentError('A repertoire needs a chapter');
    final names = <String>{};
    for (final name in chapters.keys) {
      if (!name.endsWith('.pgn')) throw ArgumentError('Expected a PGN chapter');
      requireSafeFileName(name.substring(0, name.length - 4));
      if (!names.add(name.toLowerCase())) {
        throw ArgumentError('Duplicate chapter name');
      }
    }
  }
  final String name;
  final Map<String, String> chapters;
  final int gameCount;
  final String? sourceContent;
}
