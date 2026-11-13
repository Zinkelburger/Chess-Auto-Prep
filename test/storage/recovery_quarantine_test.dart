import 'dart:io';

import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a copy kept before Support exists makes its folders and holds the '
      'bytes, leaving nothing else', () async {
    final root = await Directory.systemTemp.createTemp('quarantine-');
    addTearDown(() => root.delete(recursive: true));
    final support = Directory(p.join(root.path, 'Support'));
    await quarantineCopy(support, 'book.db', [1, 2, 3], 'unreadable');
    final kept = Directory(
      p.join(support.path, quarantineFolder),
    ).listSync(recursive: true).whereType<File>().toList();
    expect(kept.map((f) => p.basename(f.path)), ['book.db']);
    expect(kept.single.readAsBytesSync(), [1, 2, 3]);
  });
}
