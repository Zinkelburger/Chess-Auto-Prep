// A move played a moment before the chapter it was played in is renamed,
// moved or deleted. The words are still on the saver's clock, so no file
// holds them yet, and the change is about to take the file they belong to:
// the draft has to reach the disk before the change does.
import 'dart:async';

import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

void main() {
  final kid = folder('KID', ['Main']);
  final benko = folder('benko', const []);
  final open = ref('KID', 'Main');
  final sicilian = NodePath.of([0]);
  const words = 'the move just played';

  /// The library with [open] in the workspace and one edit of it still
  /// waiting on its second. Everything is made inside [async]'s zone: a
  /// future completed outside it would not run on the fake queue.
  LibraryFixture editing(FakeAsync async) {
    LibraryFixture? opened;
    unawaited(
      openLibrary(
        [kid, benko],
        text: blackChapter,
        open: open,
        delay: const Duration(seconds: 1),
      ).then((fixture) => opened = fixture),
    );
    async.flushMicrotasks();
    final fixture = opened!;
    fixture.session.setComment(sicilian, words);
    async.flushMicrotasks();
    expect(
      fixture.store.requestedSaves,
      isEmpty,
      reason: 'the clock is still running',
    );
    return fixture;
  }

  /// [change] to the open chapter, from the moment it is asked for to the
  /// moment the library has answered.
  LibraryResult made(FakeAsync async, Future<LibraryResult> Function() change) {
    LibraryResult? result;
    unawaited(change().then((answer) => result = answer));
    async.flushMicrotasks();
    return result!;
  }

  test('a delete takes the move played a moment before it', () {
    fakeAsync((async) {
      final fixture = editing(async);
      addTearDown(fixture.dispose);

      final result = made(async, () => fixture.library.deleteChapter(open));

      expect(result, isA<LibraryDone>());
      expect(
        fixture.store.deleted[open],
        contains(words),
        reason: 'the copy the delete can be undone from holds the move',
      );
      expect(fixture.textAt(open.path), isNull);
    });
  });

  test('a rename carries the move played a moment before it', () {
    fakeAsync((async) {
      final fixture = editing(async);
      addTearDown(fixture.dispose);

      final result = made(
        async,
        () => fixture.library.renameChapter(open, 'Mainline'),
      );

      expect(result, isA<LibraryDone>());
      expect(fixture.textAt('/repertoires/KID/Mainline.pgn'), contains(words));
      expect(fixture.session.source?.path, '/repertoires/KID/Mainline.pgn');
    });
  });

  test('a move to another repertoire carries it too', () {
    fakeAsync((async) {
      final fixture = editing(async);
      addTearDown(fixture.dispose);

      final result = made(
        async,
        () => fixture.library.moveChapter(open, benko),
      );

      expect(result, isA<LibraryDone>());
      expect(fixture.textAt('/repertoires/benko/Main.pgn'), contains(words));
      expect(
        fixture.store.requestedSaves,
        hasLength(1),
        reason: 'the draft is written once, before the file moves',
      );
    });
  });
}
