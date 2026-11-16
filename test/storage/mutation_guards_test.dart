import 'dart:io';

import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/mutation_guards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('guards-'));
  tearDown(() => root.delete(recursive: true));

  test('no folders to lock runs the action at once', () async {
    expect(await lockedForFolders(const [], () async => 7, held: const []), 7);
  });

  test('a folder the caller holds is not locked again', () async {
    final a = await Directory(p.join(root.path, 'a')).create();
    final b = await Directory(p.join(root.path, 'b')).create();
    final ran = await withDirectoryLock(
      a,
      () => lockedForFolders([a, b], () async => 'ran', held: [a]),
    ).timeout(const Duration(seconds: 10));
    expect(ran, 'ran');
  });
}
