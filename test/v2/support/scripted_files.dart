import 'dart:async';

import 'package:chess_auto_prep/v2/storage/chapter_files.dart';

/// Chapter files whose answers the test writes, and whose timing the test
/// controls: every call waits until the test releases it.
final class ScriptedFiles implements ChapterFiles {
  ScriptedFiles({this.listing = const Chapters([]), this.texts = const {}});

  ChapterListing listing;

  /// Text by chapter path; a path not here reads as absent.
  Map<String, ChapterRead> texts;

  final _pending = <Completer<void>>[];

  int get pendingCalls => _pending.length;

  /// Lets the oldest waiting call answer.
  void releaseNext() => _pending.removeAt(0).complete();

  /// Lets the newest waiting call answer, ahead of older ones.
  void releaseLast() => _pending.removeLast().complete();

  void releaseAll() {
    while (_pending.isNotEmpty) {
      releaseNext();
    }
  }

  @override
  Future<ChapterListing> list() async {
    await _wait();
    return listing;
  }

  @override
  Future<ChapterRead> read(ChapterRef ref) async {
    await _wait();
    return texts[ref.path] ?? const ChapterAbsent();
  }

  Future<void> _wait() {
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }
}

ChapterRef ref(String repertoire, String name) => ChapterRef(
  repertoire: repertoire,
  name: name,
  path: '/repertoires/$repertoire/$name.pgn',
);
