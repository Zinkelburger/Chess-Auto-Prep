import 'dart:async';

import 'package:chess_auto_prep/v2/workspace/document_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'folder admission holds every descendant but not a similar sibling',
    () async {
      final access = DocumentAccess();
      final release = Completer<void>();
      final changing = access.changingFolder(
        '/repertoires/Course',
        () => release.future,
      );
      var descendantReady = false;
      final child = access
          .settled('/repertoires/Course/Nested/Main.pgn')
          .then((_) => descendantReady = true);
      var folderReady = false;
      final folder = access
          .settled('/repertoires/Course')
          .then((_) => folderReady = true);
      await access.settled('/repertoires/Coursework/Main.pgn');
      try {
        expect(descendantReady, isFalse);
        expect(folderReady, isFalse);
      } finally {
        release.complete();
        await changing;
        await child;
        await folder;
      }
    },
  );

  test(
    'exact and folder generations compose without hiding later changes',
    () async {
      final access = DocumentAccess();
      const child = '/repertoires/Course/Nested/Main.pgn';
      var last = access.versionOf(child);
      for (var i = 0; i < 3; i++) {
        await access.changing(child, () async {});
        final next = access.versionOf(child);
        expect(next, greaterThan(last));
        last = next;
      }
      await access.changingFolder('/repertoires/Course', () async {});
      expect(access.versionOf(child), greaterThan(last));
      last = access.versionOf(child);
      await access.changing(child, () async {});
      expect(access.versionOf(child), greaterThan(last));
      expect(
        access.versionOf('/repertoires/Course/Unseen.pgn'),
        greaterThan(0),
      );
      expect(access.versionOf('/repertoires/Coursework/Main.pgn'), 0);
    },
  );

  for (final folderFirst in [false, true]) {
    test(
      'overlapping folder/exact commands refuse when folder first is $folderFirst',
      () async {
        final access = DocumentAccess();
        final release = Completer<void>();
        final active = folderFirst
            ? access.changingFolder('/repertoires/Course', () => release.future)
            : access.changing(
                '/repertoires/Course/Main.pgn',
                () => release.future,
              );
        try {
          final overlap = folderFirst
              ? access.changing('/repertoires/Course/Main.pgn', () async {})
              : access.changingFolder('/repertoires/Course', () async {});
          await expectLater(overlap, throwsStateError);
          await access.changing('/repertoires/Other/Main.pgn', () async {});
        } finally {
          release.complete();
          await active;
        }
      },
    );
  }

  for (final other in [
    '/repertoires',
    '/repertoires/Course/Nested',
    '/repertoires/Course',
  ]) {
    test('folder commands reject overlapping prefix $other', () async {
      final access = DocumentAccess();
      final release = Completer<void>();
      final active = access.changingFolder(
        '/repertoires/Course',
        () => release.future,
      );
      try {
        await expectLater(
          access.changingFolder(other, () async {}),
          throwsStateError,
        );
      } finally {
        release.complete();
        await active;
      }
    });
  }

  test(
    'failed folder work releases admission and retains its invalidation',
    () async {
      final access = DocumentAccess();
      await expectLater(
        access.changingFolder('/repertoires/Course', () async {
          throw StateError('failed');
        }),
        throwsStateError,
      );
      await access.settled('/repertoires/Course/Main.pgn');
      expect(access.versionOf('/repertoires/Course/Main.pgn'), greaterThan(0));
      await access.changing('/repertoires/Course/Main.pgn', () async {});
    },
  );
}
