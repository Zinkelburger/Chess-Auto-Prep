import 'package:path/path.dart' as p;

import '../storage/chapter_files.dart';
import '../storage/pgn_document_store.dart';

sealed class DraftPublication {
  const DraftPublication();
}

final class DraftWritten extends DraftPublication {
  const DraftWritten(this.ref);
  final ChapterRef ref;
}

final class DraftNotWritten extends DraftPublication {
  const DraftNotWritten(this.reason);
  final String reason;
}

/// A search's lines as a new draft chapter beside the one it was run on,
/// under the first free name: "Chapter (draft)", "Chapter (draft 2)", …
/// A draft is only created. An uncertain acknowledgement retains the exact
/// path and bytes; retry acknowledges an equal file and never makes a copy.
final class GeneratedDraft {
  GeneratedDraft({
    required this.documents,
    required this.folder,
    required this.chapter,
    required this.textFor,
  });

  final PgnDocumentStore documents;
  final String folder;
  final String chapter;
  final String Function(String name) textFor;

  static const _names = 20;

  int _number = 1;
  ChapterRef? _target;
  String? _text;
  bool _uncertain = false;
  DraftWritten? _completed;
  Future<DraftPublication>? _writing;

  Future<DraftPublication> write() => _writing ??= _write()
      .catchError((Object error) {
        _uncertain = true;
        return DraftNotWritten('The draft could not be written: $error');
      })
      .whenComplete(() {
        _writing = null;
      });

  Future<DraftPublication> _write() async {
    if (_completed case final done?) return done;
    for (; _number <= _names; _number++) {
      final name = _number == 1
          ? '$chapter (draft)'
          : '$chapter (draft $_number)';
      final ref = _target ??= ChapterRef.at(p.join(folder, '$name.pgn'));
      final text = _text ??= textFor(name);
      if (_uncertain) {
        final verified = await _verify(ref, text);
        if (verified != null) return verified;
      }
      final result = await documents.create(ref, text);
      switch (result) {
        case Created():
          return _completed = DraftWritten(ref);
        case Collision():
          if (_uncertain) {
            return const DraftNotWritten(
              'The draft destination changed. Retry to verify it.',
            );
          }
          _target = null;
          _text = null;
        case IoFailure(:final detail):
          _uncertain = true;
          return DraftNotWritten('The draft could not be written: $detail');
      }
    }
    _number = 1;
    return const DraftNotWritten(
      'Too many drafts of this chapter already; delete some first.',
    );
  }

  Future<DraftPublication?> _verify(ChapterRef ref, String text) async {
    switch (await documents.open(ref)) {
      case Opened(text: final observed):
        return observed == text
            ? _completed = DraftWritten(ref)
            : const DraftNotWritten(
                'The draft destination contains different words. Nothing was replaced.',
              );
      case Unreadable(:final detail):
        return DraftNotWritten('The draft could not be verified: $detail');
      case Absent():
        return null;
    }
  }
}
