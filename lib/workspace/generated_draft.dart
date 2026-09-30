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

/// What the [number]th draft of [chapter] is called: `Chapter (draft)`,
/// then `Chapter (draft 2)`, `Chapter (draft 3)`…
String draftName(String chapter, int number) =>
    number == 1 ? '$chapter (draft)' : '$chapter (draft $number)';

/// Where a line proposed for a chapter goes: a draft already beside it
/// ([ExistingDraft]) or a new one ([NewDraft]). Its [name] is what the user
/// is asked about, so it is worked out before asking and the draft written
/// is the one named.
sealed class DraftTarget {
  const DraftTarget();

  String get name;
}

final class ExistingDraft extends DraftTarget {
  const ExistingDraft(this.ref);

  final ChapterRef ref;

  @override
  String get name => ref.name;
}

final class NewDraft extends DraftTarget {
  const NewDraft({
    required this.folder,
    required this.chapter,
    required this.number,
  });

  final String folder;
  final String chapter;

  /// Which of [draftName]'s names it is written under.
  final int number;

  @override
  String get name => draftName(chapter, number);
}

/// The draft chapters already beside [source] among [chapters]: those in
/// its folder marked `// Draft` whose name is one of [draftName]'s for it,
/// in listing order.
Iterable<ChapterRef> draftsBeside(
  ChapterRef source,
  Iterable<ChapterRef> chapters,
) {
  final folder = p.dirname(source.path);
  return chapters.where(
    (ref) =>
        ref.heading.draft &&
        p.dirname(ref.path) == folder &&
        ref.name.startsWith('${source.name} (draft'),
  );
}

/// A new draft of [source] under the first [draftName] no file in its
/// folder has, compared without case; null when every one is taken.
NewDraft? newDraftBeside(ChapterRef source, Iterable<ChapterRef> chapters) {
  final folder = p.dirname(source.path);
  final taken = {
    for (final ref in chapters)
      if (p.dirname(ref.path) == folder)
        p.basenameWithoutExtension(ref.path).toLowerCase(),
  };
  for (var number = 1; number <= GeneratedDraft._names; number++) {
    if (!taken.contains(draftName(source.name, number).toLowerCase())) {
      return NewDraft(folder: folder, chapter: source.name, number: number);
    }
  }
  return null;
}

/// [target] ready for a line: an existing draft as it is, a new one made
/// as every draft is made ([GeneratedDraft]) with the text [textFor] gives
/// for its name — under that name only, so a file that took it meanwhile
/// is a [DraftNotWritten], never a draft under another name.
Future<DraftPublication> publishDraft(
  DraftTarget target, {
  required PgnDocumentStore documents,
  required String Function(String name) textFor,
}) async => switch (target) {
  ExistingDraft(:final ref) => DraftWritten(ref),
  NewDraft(:final folder, :final chapter, :final number) => GeneratedDraft(
    documents: documents,
    folder: folder,
    chapter: chapter,
    textFor: textFor,
    only: number,
  ).write(),
};

/// A new draft chapter beside the one it is for — a search's lines, or an
/// empty one for a line to go into — under the first free [draftName], or
/// only under the [only]th when that is given.
/// A draft is only created. An uncertain acknowledgement retains the exact
/// path and bytes; retry acknowledges an equal file and never makes a copy.
final class GeneratedDraft {
  GeneratedDraft({
    required this.documents,
    required this.folder,
    required this.chapter,
    required this.textFor,
    this.only,
  }) : _number = only ?? 1;

  final PgnDocumentStore documents;
  final String folder;
  final String chapter;
  final String Function(String name) textFor;
  final int? only;

  static const _names = 20;

  int _number;
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
    for (; _number <= (only ?? _names); _number++) {
      final name = draftName(chapter, _number);
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
    _number = only ?? 1;
    if (only case final number?) {
      return DraftNotWritten('${draftName(chapter, number)} already exists.');
    }
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
