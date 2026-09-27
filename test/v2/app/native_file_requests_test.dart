import 'dart:async';

import 'package:chess_auto_prep/v2/app/native_file_requests.dart';
import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';
import '../support/scripted_store.dart';
import '../support/fixtures.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chess_auto_prep/file_open');
  const codec = StandardMethodCodec();

  Future<void> incoming(List<Object?> paths) async {
    final answer = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('open', paths)),
      (_) => answer.complete(),
    );
    await answer.future;
  }

  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test(
    'startup and later native files use the guarded workspace route',
    () async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      app.store.documents[benkoMain] = Opened(
        blackChapter,
        scriptedRevision(blackChapter),
      );
      await app.settings.update(
        app.settings.value.copyWith(copyFilesIntoDocuments: false),
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'ready');
        return [kidMain.path];
      });
      final files = NativeFileRequests(
        open: (path) async {
          await app.requests.openFile(
            path == kidMain.path ? kidMain : benkoMain,
          );
        },
      );
      addTearDown(files.dispose);
      await files.start();
      expect(app.session.source?.path, kidMain.path);
      app.store.hold = true;
      app.session.setComment(NodePath.of([0]), 'Pending native-open draft');
      app.question.answer = DraftChoice.keepWaiting;
      await incoming([null, '', benkoMain.path]);
      expect(app.session.source?.path, kidMain.path);
      app.store.hold = false;
      app.store.releaseAll();
      await app.saver.flush();
      await incoming([benkoMain.path]);
      expect(app.session.source?.path, benkoMain.path);
    },
  );

  test('disposing before ready answers prevents late navigation', () async {
    final ready = Completer<List<String>>();
    final opened = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) => ready.future,
    );
    final files = NativeFileRequests(open: (path) async => opened.add(path));
    final starting = files.start();
    files.dispose();
    ready.complete(['/late.pgn']);
    await starting;
    expect(opened, isEmpty);
  });
}
