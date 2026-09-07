/// Making a repertoire on disk: a folder, and the "Main" chapter inside it.
///
/// A repertoire is a directory of chapter `.pgn` files, and a brand new one is
/// not empty — it holds one chapter with the header that records which colour
/// it is for. That header is what every later reader keys off (the deviation
/// check, the trainer, the audit), so the two places that create repertoires —
/// the repertoire list's Create dialog and the My-repertoires designation
/// panel, which now creates one rather than sending you away to make it — must
/// write exactly the same thing. Hence one function instead of two copies.
library;

import 'dart:io';

import '../features/repertoire/services/chapter_splitter.dart';
import 'pgn_parsing_service.dart' as pgn;
import 'repertoire_line_expansion.dart';
import 'storage/storage_factory.dart';
import 'storage/storage_service.dart';

/// Where a newly created repertoire landed.
class RepertoireCreationResult {
  const RepertoireCreationResult({
    required this.directoryPath,
    required this.chapterPath,
    required this.gameCount,
    List<String>? chapterPaths,
  }) : chapterPaths = chapterPaths ?? const [];

  /// The repertoire folder — what [MyRepertoireSettings] designates.
  final String directoryPath;

  /// Its first chapter — what an editor opens. A course export is split
  /// into one file per course chapter (see [createRepertoire]); this is then
  /// the first of them, in the course's order.
  final String chapterPath;

  /// Every chapter file written, in order; one entry unless the import was
  /// a course export with chapters of its own.
  final List<String> chapterPaths;

  /// Lines the chapter holds after import, every variation counted as its
  /// own line; 0 for an empty repertoire.
  final int gameCount;
}

/// A repertoire could not be created because its first chapter is already on
/// disk. Thrown rather than silently overwriting it.
class RepertoireExistsException implements Exception {
  const RepertoireExistsException(this.name);

  final String name;

  @override
  String toString() => 'A repertoire named "$name" already exists.';
}

/// Create the folder for [name] with one chapter marked for [color]
/// ('White' or 'Black'), optionally seeded with [pgnContent].
///
/// The PGN is written one game per line: a game with bracketed variations
/// becomes one game per variation ([expandVariationsIntoLines]), because
/// every reader of a chapter walks mainlines only. The result reports the
/// count after expansion; [gameCount] is the caller's own count, used only
/// when the content holds no game this app can count.
///
/// The chapter is called "Main" unless [chapterName] says otherwise — an
/// imported file is better off with a chapter named after itself, since that
/// name is what every book verdict on the games list then shows.
///
/// A course export names its chapters in a player header of every game.
/// Left as one file it is a 16,000-line chapter nobody can navigate, and
/// every verdict names the file; so when the games group by such a title
/// and [splitChapters] is on, the file is split into one chapter per title
/// (see [ChapterSplitter]) the moment it is written.
///
/// The caller checks for a name clash first — it has the list on screen and
/// can say so in the form, which is better than a thrown error. This function
/// checks the *path* as well and throws [RepertoireExistsException] rather
/// than writing, because the two checks are not the same one: a name is
/// sanitised on its way to a folder (`Sicilian: Najdorf` and `Sicilian_
/// Najdorf` land in the same place), so a name the caller found free can
/// still name a chapter that already exists — and this write would replace
/// it with a three-line header, deleting the lines in it.
Future<RepertoireCreationResult> createRepertoire({
  required String name,
  required String color,
  String? pgnContent,
  int gameCount = 0,
  String chapterName = 'Main',
  DateTime? createdAt,
  StorageService? storage,
  bool splitChapters = true,
}) async {
  final store = storage ?? StorageFactory.instance;
  final dirPath = await store.repertoireDirectoryPath(name);
  final chapterPath = store.chapterFilePath(dirPath, chapterName);
  final stamp = (createdAt ?? DateTime.now()).toString().split('.')[0];
  final header =
      '// $chapterName\n'
      '// Color: $color\n'
      '// Created on $stamp\n\n';

  if (pgnContent == null) {
    await _createChapter(store, chapterPath, header, name);
    return RepertoireCreationResult(
      directoryPath: dirPath,
      chapterPath: chapterPath,
      gameCount: 0,
    );
  }

  // On this isolate: the expansion only tokenizes (no game is replayed), and
  // the widget tests that drive an import pump fake time, which an isolate's
  // result would never arrive under.
  final expanded = expandVariationsIntoLines(pgnContent);
  await _createChapter(store, chapterPath, '$header${expanded.pgn}\n', name);
  final count = expanded.gameCount > 0 ? expanded.gameCount : gameCount;

  final isCourse =
      splitChapters &&
      courseChapterHeaderKey(
            pgn.splitPgnIntoGames(pgn.stripBom(expanded.pgn)),
          ) !=
          null;
  if (isCourse) {
    try {
      final split = await ChapterSplitter(
        storage: store,
      ).split(chapterPath, isWhite: color.toLowerCase() == 'white');
      final paths = [
        ...split.createdPaths,
        if (!split.sourceRemoved) chapterPath,
      ];
      return RepertoireCreationResult(
        directoryPath: dirPath,
        chapterPath: paths.first,
        gameCount: count,
        chapterPaths: paths,
      );
    } on ChapterSplitException {
      // Fewer than two chapters after all: one file it is.
    }
  }
  return RepertoireCreationResult(
    directoryPath: dirPath,
    chapterPath: chapterPath,
    gameCount: count,
    chapterPaths: [chapterPath],
  );
}

/// Write a repertoire's first chapter, refusing to overwrite one that is
/// already there.
///
/// The refusal is `createOnly`, not a prior existence check: two names can
/// sanitise to one folder ("Sicilian: Najdorf" and "Sicilian_ Najdorf"), so a
/// caller's own name check can pass for a chapter that exists — and a check
/// here would still race the write. The storage error is translated so
/// callers can say "that name is taken" rather than surface a file path.
Future<void> _createChapter(
  StorageService store,
  String chapterPath,
  String content,
  String name,
) async {
  try {
    await store.writeFile(chapterPath, content, createOnly: true);
  } on FileSystemException {
    throw RepertoireExistsException(name);
  }
}
