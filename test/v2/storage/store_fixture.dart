// A throwaway Documents and Support pair for the store tests. Nothing here
// touches the profile the app really uses.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final class StoreFixture {
  StoreFixture._(this.root, this.documents, this.support)
    : store = PgnFileStore(documents: documents, support: support);

  static Future<StoreFixture> create() async {
    final root = await Directory.systemTemp.createTemp('v2-store-');
    final documents = Directory(p.join(root.path, 'Documents'));
    final support = Directory(p.join(root.path, 'Support'));
    await documents.create(recursive: true);
    await support.create(recursive: true);
    return StoreFixture._(root, documents, support);
  }

  final Directory root;
  final Directory documents;
  final Directory support;
  final PgnFileStore store;

  DocumentRef ref(String relative) =>
      DocumentRef(p.join(documents.path, p.joinAll(relative.split('/'))));

  /// Puts [text] on disk through the store and returns its revision.
  Future<Revision> put(DocumentRef ref, String text) async {
    final created = await store.create(ref, text);
    return (created as Created).revision;
  }

  Directory backupFolder(DocumentRef ref) => Directory(
    p.join(
      support.path,
      'backups',
      backupId(p.relative(ref.path, from: documents.path)),
    ),
  );

  /// Replaces [ref] with [text] as an edit to its first game, which is what
  /// a save of a one-game chapter says, so the tests run under the check
  /// that stops a save changing any other game.
  Future<SaveResult> edit(DocumentRef ref, String text, Revision expected) =>
      store.save(
        ref,
        text,
        expected: expected,
        scope: GamesEdited(GamesWritten(rewritten: const {0})),
      );

  /// Puts a version the store recorded back, which is what an undo does.
  Future<SaveResult> restore(DocumentRef ref, String text, Revision expected) =>
      store.save(ref, text, expected: expected, scope: const RestoredVersion());

  /// Replaces [ref] with [text], the whole document at a time, which is what
  /// an import does.
  Future<SaveResult> replace(DocumentRef ref, String text, Revision expected) =>
      store.save(ref, text, expected: expected, scope: const WholeDocument());

  /// What is on disk at [ref] now, for a test that put it there itself.
  Future<Revision> revisionOf(DocumentRef ref) async =>
      (await probeDocument(ref.path) as FileFound).revision;

  /// The versions kept for [ref], oldest first, as the index lists them.
  List<String> keptVersions(DocumentRef ref) {
    final index = File(p.join(backupFolder(ref).path, 'index.json'));
    if (!index.existsSync()) return const [];
    final json = jsonDecode(index.readAsStringSync()) as Map<String, Object?>;
    return [
      for (final version in json['versions']! as List<Object?>)
        (version! as Map<String, Object?>)['file']! as String,
    ];
  }

  /// The text of each kept version, oldest first.
  List<String> keptTexts(DocumentRef ref) => [
    for (final name in keptVersions(ref))
      utf8.decode(
        versionBytes(
          File(p.join(backupFolder(ref).path, name)).readAsBytesSync(),
        ),
      ),
  ];

  Future<void> dispose() async {
    // A test may have taken permissions away to provoke a failure.
    await Process.run('chmod', ['-R', 'u+rwX', root.path]);
    await root.delete(recursive: true);
  }
}

/// Everything the app logs from here until the test ends, so a test can say
/// what a store did and did not report.
List<LogEntry> loggedFromNow() {
  final entries = <LogEntry>[];
  void collect(LogEntry entry) => entries.add(entry);
  log.install(collect);
  addTearDown(() => log.remove(collect));
  return entries;
}

/// A chapter with one game in it, the smallest file a save can name a game
/// of.
String oneGame(String moves) => '[Event "Line"]\n[Result "*"]\n\n$moves *\n';

/// One game of a chapter, numbered so a test can tell them apart.
String gameOf(int number, String moves) =>
    '[Event "Line $number"]\n[Result "*"]\n\n$moves *';

/// A chapter of [games], each on its own with a blank line after it.
String chapterOf(List<String> games) =>
    '$chapterHeading${games.map((game) => '$game\n\n').join()}';

const chapterHeading = '// Main\n// Color: White\n\n';

/// Three games from the initial position, the file the scope tests edit.
final threeGames = chapterOf([
  gameOf(1, '1. d4'),
  gameOf(2, '1. e4'),
  gameOf(3, '1. c4'),
]);

/// [threeGames] with a move added to the first game and the other two left
/// alone: what a save that names game 1 writes.
final firstGameEdited = chapterOf([
  gameOf(1, '1. d4 Nf6'),
  gameOf(2, '1. e4'),
  gameOf(3, '1. c4'),
]);
