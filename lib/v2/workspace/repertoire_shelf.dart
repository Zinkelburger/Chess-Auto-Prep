import 'package:dartchess/dartchess.dart' show Side;

import '../chess/pgn/chapter.dart';
import '../chess/repertoire_index.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/pgn_document_store.dart';

/// The user's repertoire files on disk, each read and indexed once and
/// again only when its text changes: what the Tree tab and the book check
/// look positions up in.
///
/// Every repertoire is here, White's and Black's; a reader takes the ones
/// of the side it wants. Draft chapters are left out, since a proposal is
/// not a line the user plays.
final class RepertoireShelf {
  RepertoireShelf({
    required ChapterFiles files,
    required PgnDocumentStore documents,
  }) : _files = files,
       _documents = documents;

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// What each file holds, by path, as last read, and the text it was
  /// indexed from.
  final _indexed = <String, ({String text, RepertoireIndex index})>{};

  List<ChapterRef> _refs = const [];
  bool _stale = true;
  Future<void>? _reading;

  /// The repertoire files in folder order, drafts left out, as last listed.
  List<ChapterRef> get refs => _refs;

  /// Whether the files must be read again before they are believed.
  bool get stale => _stale;

  /// [ref]'s index as last read; null when it could not be read.
  RepertoireIndex? indexOf(ChapterRef ref) => _indexed[ref.path]?.index;

  /// Every file for [side] as last read, in folder order, with its index.
  List<(ChapterRef, RepertoireIndex)> of(Side side) => [
    for (final ref in _refs)
      if (indexOf(ref) case final index? when index.side == side) (ref, index),
  ];

  /// The files changed on disk: they are read again the next time someone
  /// reads, and only the ones whose text changed are parsed again.
  void forget() => _stale = true;

  /// Reads until nothing is stale, so a change that lands while the files
  /// are being read is read too. [gone] stops it early.
  Future<void> read({required bool Function() gone}) async {
    while (!gone()) {
      final reading = _reading;
      if (reading != null) {
        await reading;
      } else if (_stale) {
        await (_reading = _readOnce(gone).whenComplete(() => _reading = null));
      } else {
        return;
      }
    }
  }

  Future<void> _readOnce(bool Function() gone) async {
    _stale = false;
    final RepertoireListing listing;
    try {
      listing = await _files.list();
    } on Object catch (error) {
      log.w('list the repertoires', error);
      return;
    }
    if (listing is! Repertoires) {
      _refs = const [];
      return;
    }
    final listed = [
      for (final folder in listing.folders)
        for (final chapter in folder.chapters)
          if (!chapter.heading.draft) chapter,
    ];
    final keep = {for (final ref in listed) ref.path};
    _indexed.removeWhere((path, _) => !keep.contains(path));
    for (final ref in listed) {
      if (gone()) return;
      await _index(ref);
    }
    _refs = listed;
  }

  Future<void> _index(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text):
        if (_indexed[ref.path]?.text == text) return;
        try {
          final chapter = await readChapter(name: ref.name, text: text);
          _indexed[ref.path] = (
            text: text,
            index: RepertoireIndex.of(chapter.tree, chapter.side),
          );
        } on Object catch (error) {
          log.w('index ${ref.path}', error);
          _indexed.remove(ref.path);
        }
      case Absent():
        _indexed.remove(ref.path);
      case Unreadable(:final detail):
        log.w('read ${ref.path} for the index', detail);
        _indexed.remove(ref.path);
    }
  }
}
