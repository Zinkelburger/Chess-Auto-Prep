import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

/// The list shows what is on the disk, so a chapter the workspace opened
/// that it does not hold means the disk changed under it.
void main() {
  final kid = folder('KID', ['Classical', 'Main']);
  late LibraryFixture fixture;

  tearDown(() => fixture.dispose());

  test(
    'a copy the workspace opened appears in the list and is selected',
    () async {
      // Saving a copy of a document that can take no more words hands the
      // session to the copy. That file was written a moment ago, so the list
      // does not hold it yet: it has to be read again or the user has nothing
      // to click.
      fixture = await openLibrary([kid], open: kid.chapters.last);
      const copy = ChapterRef(
        repertoire: 'KID',
        name: 'Main copy',
        path: '/repertoires/KID/Main copy.pgn',
      );
      fixture.files.listing = Repertoires([
        folder('KID', ['Classical', 'Main', 'Main copy']),
      ]);
      const text = '// Main copy\n// Color: White\n\n';
      fixture.store.documents[copy] = Opened(text, scriptedRevision(text));

      await fixture.session.open(copy);
      await pumpEventQueue();

      expect(
        fixture.library.repertoires.single.chapters.map((c) => c.name),
        contains('Main copy'),
      );
      expect(fixture.session.source, copy);
    },
  );

  test(
    'opening a chapter the list already holds reads nothing again',
    () async {
      fixture = await openLibrary([kid]);
      final listings = fixture.files.listings;
      await fixture.session.open(kid.chapters.first);
      await pumpEventQueue();
      expect(fixture.files.listings, listings);
    },
  );
}
