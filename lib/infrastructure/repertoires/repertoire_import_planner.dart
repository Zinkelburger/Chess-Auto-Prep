import '../../features/repertoires/models/repertoire_creation.dart';
import '../../features/repertoires/models/repertoire_publication.dart';
import '../../features/repertoire/services/course_chapter_partition.dart';
import '../../features/repertoire/services/chapter_store.dart';
import '../../services/repertoire_service.dart';
import '../../services/repertoire_file_editor.dart';
import '../../services/repertoire_line_expansion.dart';
import '../../services/repertoire_pgn_text.dart';
import '../../utils/safe_file_name.dart';

/// Reuses the existing parser and pinning semantics without mutating a live file.
RepertoirePublication planRepertoireImport(
  CreateRepertoire request,
  DateTime createdAt,
) {
  requireSafeFileName(request.name);
  final chapter = requireSafeFileName(request.chapterName);
  if (request.color != 'White' && request.color != 'Black') {
    throw ArgumentError.value(request.color, 'color');
  }
  final header = ChapterStore.chapterHeader(
    name: chapter,
    isWhite: request.color == 'White',
    createdAt: createdAt,
  );
  final source = request.pgnContent;
  if (source == null) {
    return RepertoirePublication(
      name: request.name,
      chapters: {'$chapter.pgn': header},
      gameCount: 0,
    );
  }
  final expanded = expandVariationsIntoLines(source);
  final imported = '$header${expanded.pgn}\n';
  final chapters = <String, String>{'$chapter.pgn': imported};
  if (request.splitChapters) {
    final document = splitRepertoireDocument(imported);
    final partition = CourseChapterPartition(
      document.games,
      RepertoireService().parseRepertoirePgn(imported),
    );
    if (partition.chapters.length >= 2) {
      chapters.clear();
      final names = CourseChapterPartition.fileNamesFor(
        partition.chapters.keys.toList(),
        [chapter],
      );
      for (final entry in partition.chapters.entries) {
        final name = names[entry.key]!;
        chapters['$name.pgn'] = reassemblePgnDocument(
          ChapterStore.chapterHeader(
            name: name,
            isWhite: request.color == 'White',
            createdAt: createdAt,
            courseChapter: entry.key,
          ).trimRight(),
          entry.value,
        );
      }
      if (partition.remaining.isNotEmpty) {
        chapters['$chapter.pgn'] = reassemblePgnDocument(
          document.preamble,
          partition.remaining,
        );
      }
    }
  }
  return RepertoirePublication(
    name: request.name,
    chapters: chapters,
    gameCount: expanded.gameCount > 0 ? expanded.gameCount : request.gameCount,
    sourceContent: source,
  );
}
