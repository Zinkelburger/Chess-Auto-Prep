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
  const DraftNotWritten(this.reason, {this.retryable = true});
  final String reason;
  final bool retryable;
}

/// One accepted derived draft. Clean collisions select the next candidate;
/// an uncertain outcome permanently binds this command to its exact path and
/// bytes. Retrying may acknowledge those bytes, never silently allocate a copy.
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
  int _next = 1;
  ChapterRef? _ref;
  String? _text;
  bool _uncertain = false;
  DraftWritten? _done;

  Future<DraftPublication> write() async {
    if (_done case final done?) return done;
    try {
      while (_next <= 20) {
        final name = _next == 1
            ? '$chapter (draft)'
            : '$chapter (draft $_next)';
        final ref = _ref ??= ChapterRef.at(p.join(folder, '$name.pgn'));
        final text = _text ??= textFor(name);
        final result = await _publish(ref, text);
        if (result != null) return result;
        _next++;
        _ref = null;
        _text = null;
      }
      return const DraftNotWritten(
        'Too many drafts of this chapter already; delete some first.',
        retryable: false,
      );
    } on Object catch (error) {
      return DraftNotWritten('The draft could not be written: $error');
    }
  }

  /// Null means a proven clean collision, so another candidate may be chosen.
  Future<DraftPublication?> _publish(ChapterRef ref, String text) async {
    if (_uncertain) {
      switch (await documents.open(ref)) {
        case Opened(text: final current):
          return current == text
              ? _done = DraftWritten(ref)
              : const DraftNotWritten(
                  'The draft destination changed. Its accepted contents are retained.',
                );
        case Unreadable():
          return const DraftNotWritten(
            'The draft destination could not be checked. Retry when it is available.',
          );
        case Absent():
          break;
      }
    }
    final wasUncertain = _uncertain;
    _uncertain = true;
    switch (await documents.create(ref, text)) {
      case Created():
        return _done = DraftWritten(ref);
      case Collision():
        if (wasUncertain) {
          return const DraftNotWritten(
            'The draft destination appeared during retry. Retry to check its exact contents.',
          );
        }
        _uncertain = false;
        return null;
      case IoFailure(:final detail):
        return DraftNotWritten('The draft could not be written: $detail');
    }
  }
}
