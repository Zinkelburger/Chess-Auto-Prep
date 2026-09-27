/// Game counts for the list and picker screens, remembered per file.
///
/// Reading and counting every PGN on every navigation is what made the
/// pickers feel slow. A count is cached against the file's `(size, modified)`
/// stat, so a re-entry skips the read entirely while any change to the file
/// (including writes made outside the app) forces a fresh count.
library;

import 'dart:io';
import 'dart:isolate';

import '../../utils/atomic_file.dart' show readTextFileSafely;
import '../../utils/lru_map.dart';
import '../../chess_core/pgn/pgn_text.dart' show countPgnGamesFast;

class PgnGameCountCache {
  PgnGameCountCache({
    int maxEntries = 2048,
    this.isolateThresholdBytes = 256 * 1024,
    Future<String?> Function(File file)? readFile,
  }) : _counts = LruMap(maxEntries: maxEntries),
       _readFile = readFile ?? readTextFileSafely;

  /// Files at least this large are counted off the UI isolate.
  final int isolateThresholdBytes;

  final LruMap<String, ({int size, int modifiedMs, int count})> _counts;
  final Future<String?> Function(File file) _readFile;

  /// Tail of the count queue. Whole-file reads are serialised across
  /// simultaneous listings, including listings of different directories,
  /// so a burst of pickers cannot read every file at once. The tail never
  /// retains a failed operation.
  Future<void> _queue = Future.value();

  /// The game count for [file], whose current stat is [stat].
  ///
  /// Served from the cache when the size and modified time are unchanged
  /// since the file was last counted. Throws [FileSystemException] when the
  /// file disappears between the stat and the read.
  Future<int> countFor(File file, FileStat stat) {
    final result = _queue.then((_) => _count(file, stat));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<int> _count(File file, FileStat stat) async {
    final modifiedMs = stat.modified.millisecondsSinceEpoch;
    final cached = _counts[file.path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modifiedMs == modifiedMs) {
      return cached.count;
    }

    final content = await _readFile(file);
    if (content == null) {
      throw FileSystemException('File disappeared while listing', file.path);
    }
    final count = content.length < isolateThresholdBytes
        ? countPgnGamesFast(content)
        : await Isolate.run(() => countPgnGamesFast(content));
    _counts[file.path] = (
      size: stat.size,
      modifiedMs: modifiedMs,
      count: count,
    );
    return count;
  }
}
