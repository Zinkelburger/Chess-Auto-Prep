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
/// A draft is only ever created, never written over; a failed write leaves
/// at worst a draft the user can delete, and asking again picks a new name.
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

  Future<DraftPublication> write() async {
    try {
      for (var n = 1; n <= _names; n++) {
        final name = n == 1 ? '$chapter (draft)' : '$chapter (draft $n)';
        final ref = ChapterRef.at(p.join(folder, '$name.pgn'));
        switch (await documents.create(ref, textFor(name))) {
          case Created():
            return DraftWritten(ref);
          case Collision():
            continue;
          case IoFailure(:final detail):
            return DraftNotWritten('The draft could not be written: $detail');
        }
      }
      return const DraftNotWritten(
        'Too many drafts of this chapter already; delete some first.',
      );
    } on Object catch (error) {
      return DraftNotWritten('The draft could not be written: $error');
    }
  }
}
