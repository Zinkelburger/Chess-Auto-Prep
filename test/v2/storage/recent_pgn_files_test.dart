import 'dart:io';

import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('v2-recent-');
  });

  tearDown(() => folder.delete(recursive: true));

  test(
    'the list is read under the old app\'s key, without files that are gone',
    () async {
      final here = p.join(folder.path, 'here.pgn');
      await File(here).writeAsString('*\n');
      final gone = p.join(folder.path, 'gone.pgn');
      SharedPreferences.setMockInitialValues({
        recentPgnFilesKey: [here, gone],
      });
      final read = await PreferencesRecentFiles().load();
      expect((read as RecentFilesListed).paths, [here]);
    },
  );

  test('a saved list is what the next load answers', () async {
    final here = p.join(folder.path, 'here.pgn');
    await File(here).writeAsString('*\n');
    SharedPreferences.setMockInitialValues({});
    final recent = PreferencesRecentFiles();
    expect(await recent.save([here]), isTrue);
    expect((await recent.load() as RecentFilesListed).paths, [here]);
  });

  test(
    'preferences that cannot be opened are a typed failure, not a list',
    () async {
      final recent = PreferencesRecentFiles(
        preferences: () => Future.error(StateError('no backend')),
      );
      expect(await recent.load(), isA<RecentFilesUnreadable>());
      expect(await recent.save(const ['/x.pgn']), isFalse);
    },
  );
}
