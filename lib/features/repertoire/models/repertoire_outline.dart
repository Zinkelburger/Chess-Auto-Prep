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
/// which edits the disk and rebuilds.  Because a snapshot never changes,
/// anything derived from it — line counts, section grouping, the lowercase
/// text a search matches against, a line's preview — is computed once and
/// kept on the node; the panel reads these on every rebuild.
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

  OutlineFolder({
    required this.path,
    required this.name,
    required this.children,
  });

  /// Lowercase name, for search.
  late final String nameLower = name.toLowerCase();

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

  late final int lineCount = allChapters.fold<int>(
    0,
    (n, c) => n + c.lineCount,
  );

  /// Chapters below this folder, materialised once (see [allChapters]).
  late final List<OutlineChapter> chapterList = allChapters.toList(
    growable: false,
  );

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

  OutlineChapter({
    required this.path,
    required this.name,
    this.lines,
    this.knownLineCount = 0,
  });

  bool get isLoaded => lines != null;
  int get lineCount => lines?.length ?? knownLineCount;

  /// Lowercase name, for search.
  late final String nameLower = name.toLowerCase();

  /// Lines grouped by section, in first-seen section order.  Empty when the
  /// file has no `[White]` chapter headers at all, so [sections] is empty
  /// for a hand-made chapter and the panel lists its lines flat.
  late final Map<String?, List<OutlineLine>> linesBySection = _groupBySection();

  Map<String?, List<OutlineLine>> _groupBySection() {
    final grouped = <String?, List<OutlineLine>>{};
    var titled = false;
    for (final l in lines ?? const <OutlineLine>[]) {
      if (l.section != null) titled = true;
      (grouped[l.section] ??= []).add(l);
    }
    return titled ? grouped : const {};
  }

  /// Section titles in first-seen order (from `[White]` chapter headers),
  /// with `null` for untitled lines. Empty when the file has no sections.
  List<String?> get sections => linesBySection.keys.toList(growable: false);

  List<OutlineLine> linesIn(String? section) =>
      linesBySection[section] ?? const [];

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

  OutlineLine({
    required this.path,
    required this.id,
    required this.gameIndex,
    required this.name,
    required this.moves,
    this.section,
    this.isModelGame = false,
  });

  /// Lowercase name and moves, what a search term is matched against.
  late final String searchText =
      '${name.toLowerCase()}\n${moves.join(' ').toLowerCase()}';

  /// [preview] with the default length — what every row shows.
  late final String previewLabel = preview();

  /// Whether [searchText] contains [needle] (already lowercase).
  bool matches(String needle) => searchText.contains(needle);

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
