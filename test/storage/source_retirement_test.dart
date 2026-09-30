import 'dart:io';

import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/legacy_profile.dart';
import 'store_fixture.dart';

void main() {
  test(
    'retired journals cannot require a deleted executable to save',
    () async {
      final fixture = await StoreFixture.create();
      addTearDown(fixture.dispose);
      await restoreLegacyProfile(fixture.root, 'move-prepared');
      final chapter = fixture.ref('repertoires/Before/Main.pgn');
      final journal = Directory(
        p.join(fixture.support.path, 'repertoire-mutations'),
      );
      final before = {
        await for (final entry in journal.list())
          if (entry is File) entry.path: await entry.readAsString(),
      };
      expect(
        await fixture.replace(
          chapter,
          '1. d4 *',
          await fixture.revisionOf(chapter),
        ),
        isA<Saved>(),
      );
      expect(await File(chapter.path).readAsString(), '1. d4 *');
      for (final entry in before.entries) {
        expect(await File(entry.key).readAsString(), entry.value);
      }
    },
  );
}
