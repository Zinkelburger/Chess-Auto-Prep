/// Which folders of the outline panel are expanded and which chapters have
/// their lines unfolded.
///
/// Fold state is keyed by path, so a structural edit that renames or moves a
/// folder must re-key it ([rekeyFolder]) and one that deletes a folder must
/// forget everything under it ([forgetFolder]); the controller calls these
/// as part of the edit so the panel keeps its shape across the rebuild.
library;

import 'package:path/path.dart' as p;

class OutlineFoldState {
  OutlineFoldState({required this.rootPath});

  /// The repertoire folder, which is always open and cannot be toggled.
  /// A supplier, because the controller re-points it on every open.
  final String? Function() rootPath;

  final Set<String> _expanded = {};
  final Set<String> _openChapters = {};

  bool isExpanded(String folderPath) =>
      _isRoot(folderPath) || _expanded.contains(folderPath);

  bool isChapterOpen(String chapterPath) => _openChapters.contains(chapterPath);

  void clear() {
    _expanded.clear();
    _openChapters.clear();
  }

  void expand(String folderPath) => _expanded.add(folderPath);

  /// Returns false for the root, which stays open.
  bool toggleFolder(String folderPath) {
    if (_isRoot(folderPath)) return false;
    if (!_expanded.remove(folderPath)) _expanded.add(folderPath);
    return true;
  }

  void openChapter(String chapterPath) => _openChapters.add(chapterPath);

  void closeChapter(String chapterPath) => _openChapters.remove(chapterPath);

  void toggleChapter(String chapterPath) {
    if (!_openChapters.remove(chapterPath)) _openChapters.add(chapterPath);
  }

  /// Whether the fold state changed.
  bool setChapterOpen(String chapterPath, bool open) =>
      open ? _openChapters.add(chapterPath) : _openChapters.remove(chapterPath);

  /// Expands every folder between the root and [chapterPath] and unfolds
  /// the chapter, so it is on screen.
  void reveal(String chapterPath) {
    final root = rootPath();
    if (root == null) return;
    var dir = p.dirname(chapterPath);
    while (p.isWithin(root, dir)) {
      _expanded.add(dir);
      dir = p.dirname(dir);
    }
    _openChapters.add(chapterPath);
  }

  /// A chapter file was renamed or moved: an unfolded chapter stays unfolded.
  void rekeyChapter(String oldPath, String newPath) {
    if (_openChapters.remove(oldPath)) _openChapters.add(newPath);
  }

  /// A folder was renamed or moved: everything keyed under it follows.
  void rekeyFolder(String oldFolder, String newFolder) {
    String rekey(String path) => p.equals(path, oldFolder)
        ? newFolder
        : p.isWithin(oldFolder, path)
        ? p.join(newFolder, p.relative(path, from: oldFolder))
        : path;
    _replaceAll(_expanded, rekey);
    _replaceAll(_openChapters, rekey);
  }

  /// A folder was deleted, with everything in it.
  void forgetFolder(String folderPath) {
    _expanded.removeWhere(
      (f) => p.equals(f, folderPath) || p.isWithin(folderPath, f),
    );
    _openChapters.removeWhere((c) => p.isWithin(folderPath, c));
  }

  bool _isRoot(String folderPath) {
    final root = rootPath();
    return root != null && p.equals(folderPath, root);
  }

  static void _replaceAll(Set<String> set, String Function(String) map) {
    final mapped = set.map(map).toList();
    set
      ..clear()
      ..addAll(mapped);
  }
}
