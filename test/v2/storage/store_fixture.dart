// A throwaway Documents and Support pair for the store tests. Nothing here
// touches the profile the app really uses.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
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

  /// Replaces [ref] with [text], the whole document at a time, which is what
  /// a test that is not about the scope of an edit is doing.
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
        gzip.decode(
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
