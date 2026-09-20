// The one place both file locks are in the same program. Both apps run on
// one profile, so if they ever stopped excluding each other two writers would
// move one chapter at a time; `test/v2/storage/file_lock_test.dart` writes the
// protocol out again, and this runs the two implementations against each
// other. It lives outside `test/v2/` because nothing in `lib/v2/` may see the
// old app, and its mirror in `test/v2/` may not either.
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/utils/file_operation_lock.dart' as old_app;
import 'package:chess_auto_prep/v2/storage/file_lock.dart' as v2;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory folder;

  setUp(() async => folder = await Directory.systemTemp.createTemp('lock-'));
  tearDown(() => folder.delete(recursive: true));

  test('v2 waits while the old app holds the folder', () async {
    final holding = Completer<void>();
    final release = Completer<void>();
    var ran = false;
    final held = old_app.withFileOperationLock(folder.path, () async {
      holding.complete();
      await release.future;
    });
    await holding.future;

    final waiting = v2.withDirectoryLock(folder, () async => ran = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ran, isFalse, reason: 'the old app still holds the folder');

    release.complete();
    await held;
    await waiting;
    expect(ran, isTrue);
  });

  test('the old app waits while v2 holds the folder', () async {
    final holding = Completer<void>();
    final release = Completer<void>();
    var ran = false;
    final held = v2.withDirectoryLock(folder, () async {
      holding.complete();
      await release.future;
    });
    await holding.future;

    final waiting = old_app.withFileOperationLock(
      folder.path,
      () async => ran = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ran, isFalse, reason: 'v2 still holds the folder');

    release.complete();
    await held;
    await waiting;
    expect(ran, isTrue);
  });

  test('two folders do not wait for each other', () async {
    final other = await Directory.systemTemp.createTemp('lock-');
    addTearDown(() => other.delete(recursive: true));
    final holding = Completer<void>();
    final release = Completer<void>();
    final held = old_app.withFileOperationLock(folder.path, () async {
      holding.complete();
      await release.future;
    });
    await holding.future;

    expect(await v2.withDirectoryLock(other, () async => 'ran'), 'ran');
    release.complete();
    await held;
  });
}
