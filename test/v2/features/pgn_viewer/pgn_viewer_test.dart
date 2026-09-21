import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

void main() {
  late ViewerFixture fixture;

  tearDown(() => fixture.dispose());

  test(
    'an opened file lists its games and is at the top of the recents',
    () async {
      fixture = await viewerOver(
        threeGameFile,
        recent: const RecentFilesListed(['/Documents/pgn_collections/old.pgn']),
      );
      await fixture.viewer.loadRecent();
      await fixture.open();
      final viewer = fixture.viewer;
      expect(viewer.file, fixture.ref);
      expect(viewer.current, 0);
      expect(viewer.games.map((game) => game.title), [
        'Carlsen, Magnus – Nakamura, Hikaru',
        'Ding, Liren – Giri, Anish',
        'Club night',
      ]);
      expect(viewer.recent, [
        fixture.ref.path,
        '/Documents/pgn_collections/old.pgn',
      ]);
      expect(fixture.recent.saved.single, viewer.recent);
    },
  );

  test('a file opened again moves to the top rather than in twice', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    await fixture.viewer.opened(fixture.ref);
    expect(fixture.viewer.recent, [fixture.ref.path]);
  });

  test('the recent list keeps ten files', () async {
    fixture = await viewerOver(
      threeGameFile,
      recent: RecentFilesListed([for (var i = 0; i < 10; i++) '/r/$i.pgn']),
    );
    await fixture.viewer.loadRecent();
    await fixture.open();
    expect(fixture.viewer.recent.length, 10);
    expect(fixture.viewer.recent.first, fixture.ref.path);
    expect(fixture.viewer.recent, isNot(contains('/r/9.pgn')));
  });

  test('next and previous walk the games without reading the file', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    final viewer = fixture.viewer;
    viewer.nextGame();
    expect(viewer.current, 1);
    expect(fixture.session.cursor.isRoot, isTrue);
    expect(fixture.session.tree?.children.single.san, 'd4');
    viewer.nextGame();
    viewer.nextGame();
    expect(viewer.current, 2, reason: 'there is no game past the last');
    viewer.previousGame();
    expect(viewer.current, 1);
    expect(fixture.session.source, fixture.ref);
  });

  test('the search narrows the games and keeps their file positions', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    fixture.viewer.search('giri');
    expect(fixture.viewer.visible.map((row) => row.$1), [1]);
    fixture.viewer.search('tata');
    expect(fixture.viewer.visible.map((row) => row.$1), [0, 1]);
    fixture.viewer.search('');
    expect(fixture.viewer.visible.length, 3);
  });

  test(
    'the viewer lets go of a file the workspace has moved on from',
    () async {
      fixture = await viewerOver(threeGameFile);
      await fixture.open();
      final other = ChapterRef.at('/Documents/repertoires/KID/Main.pgn');
      fixture.store.documents[other] = fixture.store.documents[fixture.ref]!;
      await fixture.session.open(other);
      expect(fixture.viewer.file, isNull);
      expect(fixture.viewer.games, isEmpty);
      expect(fixture.viewer.current, isNull);
    },
  );

  test('closing the file empties the list', () async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    fixture.session.closed();
    fixture.viewer.closed();
    expect(fixture.viewer.file, isNull);
    expect(fixture.viewer.games, isEmpty);
  });

  test('the recent list that could not be read or kept says so', () async {
    fixture = await viewerOver(
      threeGameFile,
      recent: const RecentFilesUnreadable('no preferences'),
    );
    await fixture.viewer.loadRecent();
    expect(fixture.viewer.recentProblem, 'The recent files could not be read.');
    fixture.recent.listing = const RecentFilesListed([]);
    await fixture.viewer.loadRecent();
    expect(fixture.viewer.recentProblem, isNull);
    fixture.recent.accepting = false;
    await fixture.open();
    expect(
      fixture.viewer.recentProblem,
      'The recent files list was not saved.',
    );
    expect(fixture.viewer.recent, [fixture.ref.path], reason: 'still shown');
  });

  test('the file dialog starts beside the open file, else the last one, '
      'else in the collections folder', () async {
    fixture = await viewerOver(
      threeGameFile,
      recent: const RecentFilesListed(['/home/me/Downloads/twic.pgn']),
    );
    await fixture.viewer.browse();
    await fixture.viewer.loadRecent();
    await fixture.viewer.browse();
    await fixture.open();
    await fixture.viewer.browse();
    expect(fixture.picker.startedIn, [
      collectionsRoot,
      '/home/me/Downloads',
      collectionsRoot,
    ]);
  });

  test(
    'an edit to one game keeps the list and the game on the board',
    () async {
      fixture = await viewerOver(threeGameFile);
      await fixture.open();
      fixture.viewer.showGame(2);
      fixture.session.forward();
      fixture.session.playMove('e7e5');
      await fixture.saver.flush();
      expect(fixture.onDisk, contains('1. c4 e5 *'));
      expect(fixture.viewer.current, 2);
      expect(fixture.viewer.games.length, 3);
    },
  );

  test('a file outside Documents is opened as its copy inside', () async {
    fixture = await viewerOver(threeGameFile);
    fixture.import.copyTo = '/Documents/pgn_collections/course.pgn';
    final ref = await fixture.viewer.fileFor('/home/me/Downloads/course.pgn');
    expect(ref?.path, '/Documents/pgn_collections/course.pgn');
    expect(fixture.import.asked, ['/home/me/Downloads/course.pgn']);
    expect(fixture.viewer.recentProblem, isNull);
  });

  test('a file already inside Documents is opened where it is', () async {
    fixture = await viewerOver(threeGameFile);
    final ref = await fixture.viewer.fileFor(fixture.ref.path);
    expect(ref, fixture.ref);
  });

  test('a copy that could not be made opens nothing and says why', () async {
    fixture = await viewerOver(threeGameFile);
    final ref = await fixture.viewer.fileFor('/home/me/Downloads/course.pgn');
    expect(ref, isNull);
    expect(
      fixture.viewer.recentProblem,
      'Could not copy course.pgn into your Documents: no room',
    );
  });

  test('the dialog answers the file to open, through the same door', () async {
    fixture = await viewerOver(threeGameFile);
    fixture.picker.answer = '/home/me/Downloads/new.pgn';
    fixture.import.copyTo = '/Documents/pgn_collections/new.pgn';
    final ref = await fixture.viewer.browse();
    expect(ref?.path, '/Documents/pgn_collections/new.pgn');
    fixture.picker.answer = null;
    expect(await fixture.viewer.browse(), isNull);
  });

  test('a folder is named from home down when it is under it', () async {
    fixture = await viewerOver(threeGameFile);
    // These fixtures put Documents at the root, which is not a home, so
    // the folder is left whole; a viewer over a real home shortens it.
    expect(
      fixture.viewer.folderShown('/Documents/pgn_collections/a.pgn'),
      '/Documents/pgn_collections',
    );
    final homed = PgnViewer(
      recent: fixture.recent,
      picker: fixture.picker,
      import: fixture.import,
      session: fixture.session,
      collections: '/home/me/Documents/pgn_collections',
    );
    addTearDown(homed.dispose);
    expect(
      homed.folderShown('/home/me/Documents/pgn_collections/a.pgn'),
      'Documents/pgn_collections',
    );
    expect(homed.folderShown('/mnt/usb/a.pgn'), '/mnt/usb');
  });
}
