// The plan's disk-full test, run by `disk_full_test.dart` inside a mount
// namespace where the folder given as the argument is a tiny tmpfs.
//
// Fills the disk, then asks the store to save a document that no longer
// fits, and reports what came of it as one JSON object on stdout: the
// result of the save, what the document holds afterwards, whether a staged
// copy was left behind, and whether the same save lands once there is room
// again. Pure Dart, so `dart run` can start it; nothing here touches the
// profile the app uses.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:path/path.dart' as p;

const _small = '[Event "Main"]\n\n1. d4 *\n';

/// A comment far larger than the room left on the disk.
final _big = '[Event "Main"]\n\n1. d4 {${'x' * 200 * 1024}} *\n';

Future<void> main(List<String> args) async {
  final root = Directory(args.single);
  final documents = Directory(p.join(root.path, 'Documents'));
  final support = Directory(p.join(root.path, 'Support'));
  await documents.create(recursive: true);
  await support.create(recursive: true);
  final store = PgnFileStore(documents: documents, support: support);
  final ref = DocumentRef(
    p.join(documents.path, 'repertoires', 'KID', 'Main.pgn'),
  );
  await Directory(p.dirname(ref.path)).create(recursive: true);
  final created = await store.create(ref, _small) as Created;

  final filler = await _fillDisk(root, keepFree: 3);
  final report = <String, Object?>{
    'filled': filler.length,
    'save': await _describe(store, ref, created.revision),
    'afterwards': await _document(store, ref),
    'staged copies': await _stagedCopies(Directory(p.dirname(ref.path))),
  };
  for (final file in filler) {
    await file.delete();
  }
  report['retried'] = await _describe(store, ref, created.revision);
  report['finally'] = await _document(store, ref);
  stdout.writeln(jsonEncode(report));
}

/// Writes 4 KiB files beside the documents until the disk refuses one, then
/// gives back [keepFree] of them so a small write — the kept version of the
/// document — still fits and it is the document's own replacement that
/// runs out of room.
Future<List<File>> _fillDisk(Directory root, {required int keepFree}) async {
  final chunk = List<int>.filled(4096, 0x78);
  final written = <File>[];
  for (var i = 0; i < 100000; i++) {
    final file = File(p.join(root.path, 'filler-$i'));
    try {
      await file.writeAsBytes(chunk, flush: true);
      written.add(file);
    } on FileSystemException {
      await _deleteQuietly(file);
      break;
    }
  }
  for (var i = 0; i < keepFree && written.isNotEmpty; i++) {
    await written.removeLast().delete();
  }
  return written;
}

Future<void> _deleteQuietly(File file) async {
  if (await file.exists()) await file.delete();
}

Future<Map<String, Object?>> _describe(
  PgnFileStore store,
  DocumentRef ref,
  Revision expected,
) async {
  final result = await store.save(
    ref,
    _big,
    expected: expected,
    scope: GamesEdited(GamesWritten(rewritten: const {0})),
  );
  return {
    'result': result.runtimeType.toString(),
    if (result is IoFailure) 'detail': result.detail,
  };
}

Future<Map<String, Object?>> _document(
  PgnFileStore store,
  DocumentRef ref,
) async {
  final read = await store.open(ref);
  return switch (read) {
    Opened(:final text) => {'text': text.length == _big.length ? 'big' : text},
    Absent() => {'absent': true},
    Unreadable(:final detail) => {'unreadable': detail},
  };
}

Future<List<String>> _stagedCopies(Directory folder) async {
  final names = <String>[];
  await for (final entry in folder.list()) {
    final name = p.basename(entry.path);
    if (name.startsWith('.')) names.add(name);
  }
  return names;
}
