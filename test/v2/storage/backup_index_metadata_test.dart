import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  for (final marked in [false, true]) {
    test('delete preserves backup index metadata with BOM=$marked', () async {
      final fixture = await StoreFixture.create();
      addTearDown(fixture.dispose);
      final ref = fixture.ref('repertoires/Course/Main.pgn');
      final old = oneGame('1. d4');
      final current = oneGame('1. e4');
      final first = await fixture.put(ref, old);
      final saved = await fixture.edit(ref, current, first) as Saved;
      final index = File(p.join(fixture.backupFolder(ref).path, 'index.json'));
      final raw =
          jsonDecode(await index.readAsString()) as Map<String, Object?>;
      final versions = raw['versions']! as List;
      (versions.single as Map<String, Object?>)['annotation'] = {
        'label': 'Keep this historical context',
        'flags': [true, null, 7],
      };
      raw['extensions'] = {
        'owner': 'User',
        'nested': ['unchanged'],
      };
      final originalVersion = Map<String, Object?>.of(
        versions.single as Map<String, Object?>,
      );
      await index.writeAsString('${marked ? '\ufeff' : ''}${jsonEncode(raw)}');

      final result = await fixture.store.delete(
        ref,
        expected: saved.receipt.committed,
        operationId: '1750000000000000-abc123',
      );
      expect(result, isA<Deleted>());
      final deleted = result as Deleted;
      final destination = DocumentRef(deleted.recoveredTo);
      final after =
          jsonDecode(
                await File(
                  p.join(fixture.backupFolder(destination).path, 'index.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(after['extensions'], raw['extensions']);
      expect((after['versions']! as List).first, originalVersion);
      expect(after['path'], deleted.recoveredTo);
      expect(fixture.keptTexts(destination), [old, current]);

      // The latest-version append still belonged to the original source;
      // the journal's ownership transfer alone changes the index path.
      final receipt =
          jsonDecode(
                await File(
                  p.join(
                    fixture.support.path,
                    'relocation-writes',
                    '1750000000000000-abc123.json',
                  ),
                ).readAsString(),
              )
              as Map<String, Object?>;
      final backup = receipt['backup']! as Map<String, Object?>;
      final source = backup['source']! as Map<String, Object?>;
      final beforeMove =
          jsonDecode(source['index']! as String) as Map<String, Object?>;
      expect(beforeMove['path'], ref.path);
      expect(beforeMove['extensions'], raw['extensions']);
      expect((beforeMove['versions']! as List).first, originalVersion);
      expect(
        fixture
            .backupFolder(destination)
            .listSync()
            .map((entry) => p.basename(entry.path)),
        isNot(contains(startsWith('index.json.corrupt-'))),
      );
    });
  }
}
