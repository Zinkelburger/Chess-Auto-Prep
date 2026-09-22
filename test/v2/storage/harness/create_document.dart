// Run by document_failures_test.dart as a second process, standing in for a
// second app: creates one document and prints what the store answered.
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';

Future<void> main(List<String> args) async {
  final store = PgnFileStore(
    documents: Directory(args[0]),
    support: Directory(args[1]),
  );
  final result = await store.create(DocumentRef(args[2]), args[3]);
  stdout.writeln(switch (result) {
    Created() => 'created',
    Collision() => 'collision',
    IoFailure(:final detail) => 'failed: $detail',
  });
  await stdout.flush();
}
