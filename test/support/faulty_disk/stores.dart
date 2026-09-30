// The stores of one profile as the app wires them: the document store, the
// training files, books.json and the repertoire listing, all on the one
// recovery gate. Built inside a FaultyDisk run, so every effect they make is
// traced, and with no wait between recovery passes, so a pass a fault
// stopped runs again on the next access as it would once the wait is over.
//
// A scenario reads through them with the projections below: short strings
// that compare equal exactly when the app would show the same thing, so one
// answer can be carried out of the isolate it was read in and compared with
// the answer on the profile before or after the command.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/book_snapshot.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../profile/profile.dart';
import '../profile/standard_profile.dart';
import 'faulty_disk.dart' show onRealDisk;
import 'scenario.dart';

final class Stores {
  Stores._(this.profile, this.documents, this.training, this.chapters);

  /// The app's wiring (`AppEnvironment`) on [profile]. Call it inside the
  /// run: only entities made there are traced.
  static Stores open(Profile profile) {
    final documents = PgnFileStore(
      documents: Directory(profile.documents),
      support: Directory(profile.support),
      recoveryRetry: Duration.zero,
    );
    return Stores._(
      profile,
      documents,
      TrainingStore(
        Directory(profile.documents),
        support: Directory(profile.support),
        recovery: documents.recovery,
      ),
      ChapterDirectory(
        Directory(profile.repertoires),
        documents: documents,
        recovery: documents.recovery,
      ),
    );
  }

  final Profile profile;
  final PgnFileStore documents;
  final TrainingStore training;
  final ChapterDirectory chapters;
  final _once = <String, Object>{};

  /// The document at [relative] under Documents, written with `/`.
  DocumentRef ref(String relative) => DocumentRef(profile.document(relative));

  /// The value [make] gives the first time this session asks for [name]:
  /// the inputs of a command, so that its retry sends the same operation
  /// (the same id, text and expected revision) rather than a new one.
  T once<T extends Object>(String name, T Function() make) =>
      _once.putIfAbsent(name, make) as T;

  /// What the document at [relative] holds now, read around the trace: a
  /// command's input, which the user already had open, not an effect of the
  /// command itself.
  String textNow(String relative) =>
      onRealDisk(() => File(profile.document(relative)).readAsStringSync());

  /// `absent`, `opened <sha256 of the text>` or `unreadable`.
  Future<String> openedAs(String relative) async =>
      switch (await documents.open(ref(relative))) {
        Absent() => 'absent',
        Opened(:final text) => 'opened ${_sha(text)}',
        Unreadable() => 'unreadable',
      };

  /// The course sections the document at [relative] opens with, in order.
  Future<String> sectionsOf(String relative) async =>
      switch (await documents.open(ref(relative))) {
        Opened(:final text) => chapterSections(
          parseChapter(name: 'course', text: text).lines,
        ).join(', '),
        Absent() => 'absent',
        Unreadable() => 'unreadable',
      };

  /// Every book's chapters and sections, as books.json reads now, or
  /// `unreadable`: `BookStore` throws when the file cannot be read, and the
  /// Books owner (lib/workspace/books.dart) shows that, not the throw.
  Future<String> bookSelectors() async {
    final BookSnapshot books;
    try {
      books = await documents.books.snapshot();
    } on Exception {
      return 'unreadable';
    }
    String selector(BookChapter c) => '${c.path}#${c.section}';
    return [
      for (final book in books.value.books)
        '${book.id}: ${_sorted(book.chapters.map(selector).toList())}',
    ].join('; ');
  }

  /// The repertoires and their chapters, or why they could not be listed.
  Future<String> repertoires() async => switch (await chapters.list()) {
    Repertoires(:final folders, :final unreadable) => [
      for (final folder in folders)
        '${folder.name}: '
            '${_sorted([for (final c in folder.chapters) p.basename(c.path)])}',
      for (final folder in unreadable) '${folder.name}: unreadable',
    ].join('; '),
    RepertoiresUnreadable() => 'unreadable',
  };

  /// How many review, streak and mistake records the chapter at [relative]
  /// has, or why they could not be read.
  Future<String> trainingOf(String relative) async => switch (await training
      .read({profile.document(relative)})) {
    ProgressLoaded(:final reviews, :final streaks, :final mistakes) =>
      '${reviews.length} reviews, ${streaks.length} streaks, '
          '${mistakes.length} mistakes',
    ProgressUnreadable(:final file, :final line) => 'unreadable $file:$line',
    ProgressFailed() => 'failed',
  };

  /// For each chapter at [relatives], read one after the other as the
  /// trainer opens them: the line ids it has reviews and streaks for and how
  /// many wrong answers, or why that read failed. A row repointed to the
  /// wrong line or chapter shows here.
  Future<String> trainedLines(List<String> relatives) async {
    final answers = <String>[];
    for (final relative in relatives) {
      final path = profile.document(relative);
      answers.add('$relative: ${_linesOf(path, await training.read({path}))}');
    }
    return answers.join(' | ');
  }

  /// [trainedLines] of a chapter an operation moves, at the first of
  /// [places] that opens: the trainer finds a chapter where the listing
  /// shows it, and a training read of a path with no chapter fails. A row
  /// left behind at the chapter's other place shows as missing here.
  ///
  /// The first access through the recovery gate is therefore the open, not
  /// the training read: a gap in [TrainingStore.read]'s own gating would not
  /// show in a scenario that reads this way. It cannot find the chapter
  /// around the gate instead, since recovery may move it.
  Future<String> trainingWhereItIs(List<String> places) async {
    for (final relative in places) {
      if (await documents.open(ref(relative)) is Absent) continue;
      return trainedLines([relative]);
    }
    return 'nowhere';
  }
}

String _linesOf(String path, ProgressRead read) {
  if (read is! ProgressLoaded) {
    return switch (read) {
      ProgressUnreadable(:final file, :final line) => 'unreadable $file:$line',
      _ => 'failed',
    };
  }
  final reviewed = [
    for (final key in read.reviews.keys)
      if (key.source == path) key.id,
  ];
  final streaked = [
    for (final key in read.streaks.keys)
      if (key.line.source == path) '${key.line.id}@${key.ply}',
  ];
  final wrong = read.mistakes.where((m) => m.key.source == path).length;
  return 'reviews ${_sorted(reviewed)}; streaks ${_sorted(streaked)}; '
      '$wrong mistakes';
}

/// What the standard profile shows a user that no first scenario changes,
/// and the listing and books, which a command may change only as it says.
const standardProbes = [
  Probe<Stores>('open Benko Accepted', _openAccepted),
  Probe<Stores>('open the study', _openStudy),
  Probe<Stores>('repertoires', _repertoires),
  Probe<Stores>('training of Benko Declined', _declinedTraining),
  Probe<Stores>('books', _books),
];

Future<String> _openAccepted(Stores s) => s.openedAs(benkoAccepted);
Future<String> _openStudy(Stores s) => s.openedAs(endgameStudy);
Future<String> _repertoires(Stores s) => s.repertoires();
Future<String> _declinedTraining(Stores s) => s.trainingOf(benkoDeclined);
Future<String> _books(Stores s) => s.bookSelectors();

String _sorted(List<String> names) => (names..sort()).join(', ');

/// The revision a file holding [text], and nothing else, has.
Revision revisionOf(String text) => Revision(_sha(text));

String _sha(String text) => '${sha256.convert(utf8.encode(text))}';
