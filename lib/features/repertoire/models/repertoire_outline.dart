/// The outline of a repertoire: what is in it and how it is organised.
///
/// A repertoire is a folder. Inside it, chapters are `.pgn` files, and folders
/// nest to group chapters however the user likes — that nesting is the whole
/// "sub-chapter" model, so the outline is literally the file structure. Each
/// game in a chapter file is one line. A chapter written by the course
/// composer additionally titles games with a `[White]` chapter header; the
/// outline shows those as sections inside the chapter so a generated course
/// reads as structure without becoming separate files.
///
/// Nodes are immutable snapshots. Mutations go through the outline service,
/// which edits the disk and rebuilds.
library;

import '../../../utils/movetext_builder.dart';

import 'package:path/path.dart' as p;

/// Anything that appears in the outline: a folder, a chapter, or a line.
sealed class OutlineNode {
  const OutlineNode();

  /// Absolute path of the folder or chapter file; for a line, its chapter's
  /// path.
  String get path;

  String get name;
}

/// A folder — the repertoire itself, or a group of chapters inside it.
class OutlineFolder extends OutlineNode {
  @override
  final String path;
  @override
  final String name;

  /// Sub-folders first, then chapters, each sorted by name.
  final List<OutlineNode> children;

  const OutlineFolder({
    required this.path,
    required this.name,
    required this.children,
  });

  List<OutlineFolder> get folders =>
      children.whereType<OutlineFolder>().toList();
  List<OutlineChapter> get chapters =>
      children.whereType<OutlineChapter>().toList();

  /// Every chapter below this folder, depth-first.
  Iterable<OutlineChapter> get allChapters sync* {
    for (final c in children) {
      if (c is OutlineChapter) yield c;
      if (c is OutlineFolder) yield* c.allChapters;
    }
  }

  /// Every folder below this one (not itself), depth-first.
  Iterable<OutlineFolder> get allFolders sync* {
    for (final c in children) {
      if (c is OutlineFolder) {
        yield c;
        yield* c.allFolders;
      }
    }
  }

  int get lineCount => allChapters.fold<int>(0, (n, c) => n + c.lineCount);

  /// The chapter at [chapterPath] anywhere below this folder, or null.
  OutlineChapter? findChapter(String chapterPath) {
    for (final c in allChapters) {
      if (p.equals(c.path, chapterPath)) return c;
    }
    return null;
  }

  /// The folder at [folderPath] — this one or any below it — or null.
  OutlineFolder? findFolder(String folderPath) {
    if (p.equals(path, folderPath)) return this;
    for (final f in allFolders) {
      if (p.equals(f.path, folderPath)) return f;
    }
    return null;
  }

  /// Whether [other] is this folder or nested anywhere inside it — the check
  /// that stops a folder from being dropped into its own descendant.
  bool contains(String other) =>
      p.equals(path, other) || p.isWithin(path, other);
}

/// One `.pgn` file: a chapter holding lines.
class OutlineChapter extends OutlineNode {
  @override
  final String path;
  @override
  final String name;

  /// Lines in file order. Null until loaded (the outline can list a chapter
  /// from its file name alone; parsing every game happens lazily).
  final List<OutlineLine>? lines;

  /// Line count when [lines] is not loaded — from the chapter listing.
  final int knownLineCount;

  const OutlineChapter({
    required this.path,
    required this.name,
    this.lines,
    this.knownLineCount = 0,
  });

  bool get isLoaded => lines != null;
  int get lineCount => lines?.length ?? knownLineCount;

  /// Section titles in first-seen order (from `[White]` chapter headers),
  /// with `null` for untitled lines. Empty when the file has no sections.
  List<String?> get sections {
    final seen = <String?>[];
    var titled = false;
    for (final l in lines ?? const <OutlineLine>[]) {
      if (l.section != null) titled = true;
      if (!seen.contains(l.section)) seen.add(l.section);
    }
    return titled ? seen : const [];
  }

  List<OutlineLine> linesIn(String? section) =>
      (lines ?? const []).where((l) => l.section == section).toList();

  OutlineChapter copyWith({List<OutlineLine>? lines, int? knownLineCount}) =>
      OutlineChapter(
        path: path,
        name: name,
        lines: lines ?? this.lines,
        knownLineCount: knownLineCount ?? this.knownLineCount,
      );
}

/// One game in a chapter file.
class OutlineLine extends OutlineNode {
  /// The chapter file this line lives in.
  @override
  final String path;

  /// The line id the rest of the app uses (see
  /// `RepertoireService.lineIdFromHeaders`). Not unique for lines sharing a
  /// long prefix, so file edits address [gameIndex] instead.
  final String id;

  /// 0-based position of the game in the chapter file.
  final int gameIndex;
  @override
  final String name;
  final List<String> moves;

  /// Course-composer section (`[White]` chapter header), if any.
  final String? section;

  /// A database game kept as illustration, not a line to know.
  final bool isModelGame;

  const OutlineLine({
    required this.path,
    required this.id,
    required this.gameIndex,
    required this.name,
    required this.moves,
    this.section,
    this.isModelGame = false,
  });

  /// Whether this line passes through the position reached by [prefix]
  /// (SAN sequence from the start). The empty prefix matches everything.
  bool passesThrough(List<String> prefix) {
    if (prefix.length > moves.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (moves[i] != prefix[i]) return false;
    }
    return true;
  }

  /// A short preview of the moves — the first [maxPlies] as `1.e4 e5 2.Nf3`.
  String preview({int maxPlies = 8}) {
    final n = moves.length < maxPlies ? moves.length : maxPlies;
    final text = buildNumberedMovetext(moves.take(n).toList(), compact: true);
    return moves.length > n ? '$text …' : text;
  }
}
