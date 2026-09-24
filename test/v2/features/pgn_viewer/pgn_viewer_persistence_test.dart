import 'dart:async';

import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

final class _Recent implements RecentFiles {
  List<String> paths = ['/old.pgn'];
  Completer<void>? reading;
  bool accepting = true;
  int writes = 0;

  @override
  Future<RecentFilesRead> load() async {
    await reading?.future;
    return RecentFilesListed(List.of(paths));
  }

  @override
  Future<bool> save(List<String> next) async {
    writes++;
    if (!accepting) return false;
    paths = List.of(next);
    return true;
  }
}

void main() {
  late ViewerFixture fixture;
  late _Recent recent;
  late PendingWrites pending;

  setUp(() async {
    fixture = await viewerOver(threeGameFile);
    recent = _Recent();
    pending = PendingWrites();
  });
  tearDown(() => fixture.dispose());

  PgnViewer viewer() => PgnViewer(
    recent: recent,
    pendingWrites: pending,
    picker: fixture.picker,
    import: fixture.import,
    settings: fixture.settings,
    session: fixture.session,
    filter: fixture.filter,
    collections: collectionsRoot,
  );

  test('accepted recent-file save completes after viewer disposal', () async {
    final owner = viewer();
    recent.reading = Completer<void>();
    final opening = owner.opened(fixture.ref);
    await pumpEventQueue();
    owner.dispose();
    recent.reading!.complete();
    await opening;
    expect(await pending.settle(), isNull);
    expect(recent.paths, [fixture.ref.path, '/old.pgn']);
  });

  test(
    'reading recents cannot erase a failed addition; reopening retries it',
    () async {
      final owner = viewer();
      addTearDown(owner.dispose);
      recent.accepting = false;
      await owner.opened(fixture.ref);
      expect(await pending.settle(), isNotNull);
      await owner.loadRecent();
      expect(owner.recent, contains(fixture.ref.path));
      expect(owner.recentProblem, isNotNull);
      expect(await pending.settle(), isNotNull);
      recent.accepting = true;
      await owner.loadRecent();
      expect(recent.paths, [fixture.ref.path, '/old.pgn']);
      expect(owner.recentProblem, isNull);
      expect(await pending.settle(), isNull);
    },
  );

  test(
    'replacement viewer retries accepted additions in their original order',
    () async {
      final owner = viewer();
      recent.accepting = false;
      await owner.opened(fixture.ref);
      final second = collectionRef('second');
      await owner.opened(second);
      owner.dispose();
      final replacement = viewer();
      addTearDown(replacement.dispose);
      recent.accepting = true;
      await replacement.loadRecent();
      expect(recent.paths, [second.path, fixture.ref.path, '/old.pgn']);
      expect(replacement.recent, recent.paths);
      expect(await pending.settle(), isNull);
    },
  );
}
