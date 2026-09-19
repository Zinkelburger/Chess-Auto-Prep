import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../storage/chapter_files.dart';

sealed class LibraryState {
  const LibraryState();
}

final class LibraryLoading extends LibraryState {
  const LibraryLoading();
}

final class LibraryReady extends LibraryState {
  const LibraryReady(this.chapters);

  final List<ChapterRef> chapters;
}

final class LibraryFailed extends LibraryState {
  const LibraryFailed(this.reason);

  final String reason;
}

sealed class OpenResult {
  const OpenResult();
}

final class Opened extends OpenResult {
  const Opened(this.chapter);

  final Chapter chapter;
}

final class OpenFailed extends OpenResult {
  const OpenFailed(this.reason);

  final String reason;
}

/// The list of chapters on disk and the way to open one.
///
/// A refresh that is overtaken by a newer refresh discards its result, so the
/// list never goes back in time.
final class Library extends ChangeNotifier {
  Library(this._files);

  final ChapterFiles _files;
  LibraryState _state = const LibraryLoading();
  int _refreshes = 0;
  bool _disposed = false;

  LibraryState get state => _state;

  Future<void> refresh() async {
    final ticket = ++_refreshes;
    _set(const LibraryLoading());
    LibraryState next;
    try {
      next = LibraryReady(await _files.list());
    } on Exception catch (e) {
      next = LibraryFailed('$e');
    }
    if (ticket != _refreshes || _disposed) return;
    _set(next);
  }

  /// Reads and parses [ref]. Parsing is pure, so the caller may do what it
  /// likes with the chapter; this owner keeps no reference to it.
  Future<OpenResult> open(ChapterRef ref) async {
    try {
      final text = await _files.read(ref);
      return Opened(parseChapter(name: ref.name, text: text));
    } on Exception catch (e) {
      return OpenFailed('$e');
    }
  }

  void _set(LibraryState state) {
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
