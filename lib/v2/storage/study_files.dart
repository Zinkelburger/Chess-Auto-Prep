import 'dart:io';

import 'package:path/path.dart' as p;

import 'chapter_files.dart';

/// The study files under `Documents/studies/`: one `.pgn` per study, one
/// game in it per chapter.
///
/// A study is named by its file, exactly as a repertoire chapter is, so it
/// is a [ChapterRef] too — the folder label it carries is `studies`. The
/// filesystem is a real boundary, so listing is an interface: [StudyDirectory]
/// in the app, a scripted one in tests. A study's text is read and written
/// through the document store like every other PGN.
abstract interface class StudyFiles {
  Future<StudyListing> list();
}

sealed class StudyListing {
  const StudyListing();
}

final class StudiesListed extends StudyListing {
  const StudiesListed(this.studies);

  /// In name order, so the list does not rearrange itself after a save.
  final List<ChapterRef> studies;
}

/// The studies folder is there but could not be read, which is different
/// from there being no studies in it.
final class StudiesUnreadable extends StudyListing {
  const StudiesUnreadable(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// One flat folder of `.pgn` files.
final class StudyDirectory implements StudyFiles {
  StudyDirectory(this.root);

  /// The `studies` directory itself.
  final Directory root;

  @override
  Future<StudyListing> list() async {
    if (!await root.exists()) return const StudiesListed([]);
    try {
      final studies = <ChapterRef>[];
      await for (final file in root.list()) {
        if (file is! File || p.extension(file.path) != '.pgn') continue;
        if (p.basename(file.path).startsWith('.')) continue;
        studies.add(ChapterRef.at(file.path));
      }
      studies.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return StudiesListed(List.unmodifiable(studies));
    } on FileSystemException catch (error) {
      return StudiesUnreadable(error.osError?.message ?? error.message);
    }
  }
}
