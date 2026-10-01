import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart';

/// The files read lately, kept as they were parsed, so that going back to
/// one — its tab, Back, the recent list — does not read every game again.
///
/// A parse depends on nothing but the file's name and its text, so a kept
/// one is used only when both are what was just read from disk: a file
/// changed by anything, here or elsewhere, is parsed again. The games come
/// back as the very list they were ([Chapter.lines]), so whatever was
/// worked out from them — the viewer's rows, `This file`'s index — holds.
///
/// Kept by how lately each was read, up to [budget] characters of text in
/// all. A file larger than that is not kept.
final class ParsedFiles {
  ParsedFiles({this.budget = 4 * 1024 * 1024});

  /// How many characters of file text the kept parses may come from: the
  /// trees read from them take some forty times that in memory.
  final int budget;

  /// Oldest first.
  final _kept = <String, ({String text, Chapter file})>{};

  /// [text], the file at [path], as [readChapter] reads it.
  Future<Chapter> read({
    required String path,
    required String name,
    required String text,
    int? game,
  }) async {
    path = p.normalize(path);
    final kept = _kept.remove(path);
    // Every game merged is another tree than one game's, and is not made
    // from it here: such a read is parsed like a file never seen.
    if (kept != null &&
        kept.file.name == name &&
        (kept.file.game == null) == (game == null) &&
        kept.text == text) {
      _kept[path] = kept;
      return game == null || game == kept.file.game
          ? kept.file
          : withGame(kept.file, game);
    }
    final file = await readChapter(name: name, text: text, game: game);
    _keep(path, text, file);
    return file;
  }

  void _keep(String path, String text, Chapter file) {
    _kept.remove(path);
    if (text.length > budget) return;
    _kept[path] = (text: text, file: file);
    var size = _kept.values.fold(0, (n, kept) => n + kept.text.length);
    while (size > budget) {
      size -= _kept.remove(_kept.keys.first)!.text.length;
    }
  }
}
