import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/v2/app/app.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failCopy in [false, true]) {
    test(
      'shutdown drains an accepted copy and ${failCopy ? 'reports its failure' : 'accepts its commit'}',
      () async {
        final w = WindowFixture();
        addTearDown(w.dispose);
        await w.requests.open(kidMain);
        expect(w.saver.settled, isTrue);
        w.store.hold = true;
        if (failCopy) w.store.creates.add(const IoFailure('copy disk full'));
        final copying = w.session.copyAside('Accepted copy');
        var enginesStopped = false;
        final exit = AppExit(
          guard: w.parts.exit,
          prepare: w.parts.prepareToClose,
          onCancelled: w.parts.resumeAfterClose,
          stopEngines: () async => enginesStopped = true,
          closeLog: () async {},
        );
        addTearDown(exit.closing.dispose);
        AppExitResponse? response;
        final closing = exit.leave().then((value) => response = value);
        await pumpEventQueue();
        expect(enginesStopped, isFalse);
        expect(response, isNull);
        w.store.hold = false;
        w.store.releaseAll();
        expect(await copying, failCopy ? isA<CopyFailed>() : isA<CopySaved>());
        await closing;
        expect(
          response,
          failCopy ? AppExitResponse.cancel : AppExitResponse.exit,
        );
        expect(enginesStopped, !failCopy);
        if (failCopy) {
          expect(w.question.asked.single, contains('copy disk full'));
        } else {
          expect(w.question.asked, isEmpty);
        }
      },
    );
  }

  test('only retrying the exact failed copy clears its obligation', () async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    await w.requests.open(kidMain);
    final pending = w.parts.env.pendingWrites;
    w.store.creates.add(const IoFailure('copy disk full'));
    expect(await w.session.copyAside('Accepted copy'), isA<CopyFailed>());
    expect(await pending.settle(), contains('copy disk full'));
    expect(await w.session.copyAside('Another copy'), isA<CopySaved>());
    expect(await pending.settle(), contains('copy disk full'));
    expect(await w.session.copyAside('Accepted copy'), isA<CopySaved>());
    expect(await pending.settle(), isNull);
  });

  test('an existing target does not prove an unknown copy succeeded', () async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    await w.requests.open(kidMain);
    w.store.creates.addAll([
      const IoFailure('publication outcome unknown'),
      const Collision(),
    ]);
    expect(await w.session.copyAside('Accepted copy'), isA<CopyFailed>());
    expect(await w.session.copyAside('Accepted copy'), isA<CopyNameTaken>());
    expect(await w.parts.env.pendingWrites.settle(), contains('not confirmed'));
  });

  test('an initial name collision leaves no failed copy obligation', () async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    await w.requests.open(kidMain);
    w.store.creates.add(const Collision());
    expect(await w.session.copyAside('Taken name'), isA<CopyNameTaken>());
    expect(await w.parts.env.pendingWrites.settle(), isNull);
    expect(await w.session.copyAside('Available name'), isA<CopySaved>());
    expect(await w.parts.env.pendingWrites.settle(), isNull);
  });

  test('a refused copy name can be tried again when it becomes free', () async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    await w.requests.open(kidMain);
    expect(await w.session.copyAside('Temporary copy'), isA<CopySaved>());
    expect(await w.session.copyAside('Temporary copy'), isA<CopyNameTaken>());
    final target = w.store.documents.keys.singleWhere(
      (ref) => ref.path.endsWith('/Temporary copy.pgn'),
    );
    w.store.documents.remove(DocumentRef(target.path));
    expect(await w.session.copyAside('Temporary copy'), isA<CopySaved>());
    expect(await w.parts.env.pendingWrites.settle(), isNull);
  });
}
