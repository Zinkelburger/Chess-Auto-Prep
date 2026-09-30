import 'dart:io';

import 'package:chess_auto_prep/storage/audit_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('kept lines come back only when deep and wide enough', () {
    final store = AuditStore.inMemory();
    addTearDown(store.close);
    store.keepLines(
      'fen',
      const [(uci: 'e2e4', cp: 31), (uci: 'd2d4', cp: -5)],
      depth: 14,
      count: 3,
    );
    expect(store.lines('fen', depth: 14, count: 3), [
      (uci: 'e2e4', cp: 31),
      (uci: 'd2d4', cp: -5),
    ]);
    expect(store.lines('fen', depth: 16, count: 3), isNull);
    expect(store.lines('fen', depth: 14, count: 5), isNull);
    expect(store.lines('other', depth: 14, count: 3), isNull);
  });

  test('dismissed findings are kept by what they are, in their own file, '
      'across opening the store again, and restored by key', () async {
    final support = await Directory.systemTemp.createTemp('audit_store');
    addTearDown(() => support.delete(recursive: true));
    final first = AuditStore.open(support);
    first.dismiss('weak|x|e2e4');
    first.dismiss('reply|y|e7e6');
    first.close();
    // The engine lines are derived and may go; the user's choices stay.
    await File('${support.path}/audit.db').delete();
    final again = AuditStore.open(support);
    addTearDown(again.close);
    expect(again.dismissed(), {'weak|x|e2e4', 'reply|y|e7e6'});
    again.restore(['weak|x|e2e4']);
    expect(again.dismissed(), {'reply|y|e7e6'});
  });

  test('dismissals the first audit kept in audit.db, per chapter, are '
      'carried over once and the old table dropped', () async {
    final support = await Directory.systemTemp.createTemp('audit_store');
    addTearDown(() => support.delete(recursive: true));
    final old = sqlite3.open('${support.path}/audit.db');
    old.execute(
      'CREATE TABLE dismissed(chapter TEXT NOT NULL, finding TEXT NOT NULL, '
      'PRIMARY KEY (chapter, finding))',
    );
    old.execute(
      "INSERT INTO dismissed VALUES ('/r/KID/Main.pgn', 'weak|x|e2e4'), "
      "('/r/KID/Sidelines.pgn', 'weak|x|e2e4'), "
      "('/r/KID/Main.pgn', 'reply|y|e7e6')",
    );
    old.close();

    final store = AuditStore.open(support);
    expect(store.dismissed(), {'weak|x|e2e4', 'reply|y|e7e6'});
    store.restore(['weak|x|e2e4']);
    store.close();

    final again = AuditStore.open(support);
    addTearDown(again.close);
    expect(again.dismissed(), {
      'reply|y|e7e6',
    }, reason: 'a restored finding is not carried over a second time');
    final lines = sqlite3.open('${support.path}/audit.db');
    addTearDown(lines.close);
    expect(
      lines.select("SELECT name FROM sqlite_master WHERE name = 'dismissed'"),
      isEmpty,
    );
  });

  test('a file that will not open keeps nothing and never throws', () async {
    final support = await Directory.systemTemp.createTemp('audit_store');
    addTearDown(() => support.delete(recursive: true));
    await Directory('${support.path}/audit.db').create();
    await Directory('${support.path}/audit_dismissed.db').create();
    final store = AuditStore.open(support);
    expect(store.available, isFalse);
    store.dismiss('k');
    expect(store.dismissed(), isEmpty);
    expect(store.lines('fen', depth: 1, count: 1), isNull);
  });

  test('a dismissal the file cannot hold says so', () async {
    final support = await Directory.systemTemp.createTemp('audit_store');
    addTearDown(() => support.delete(recursive: true));
    await File(
      '${support.path}/audit_dismissed.db',
    ).writeAsString('not a database, not even close to one');
    final store = AuditStore.open(support);
    addTearDown(store.close);
    expect(store.dismiss('weak|x|e2e4'), isFalse);
    expect(store.restore(['weak|x|e2e4']), isFalse);
    expect(store.dismissed(), isEmpty);
    final healthy = AuditStore.inMemory();
    addTearDown(healthy.close);
    expect(healthy.dismiss('weak|x|e2e4'), isTrue);
    expect(healthy.restore(['weak|x|e2e4']), isTrue);
  });
}
