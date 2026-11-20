// How a repertoire rename holds off the workspace reading the chapters
// inside it.

import 'dart:async';

import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

void main() {
  test('a chapter read while its repertoire is renamed is not shown at the '
      'name it left', () async {
    final kid = folder('KID', ['Main']);
    final fixture = await openLibrary([kid]);
    addTearDown(fixture.dispose);
    // The read starts before the rename and answers after it, with what
    // the file held at its old name.
    final read = Completer<void>();
    fixture.store.readEarly = read;
    final opening = fixture.session.open(ref('KID', 'Main'));
    await pumpEventQueue();

    expect(
      await fixture.library.renameRepertoire(kid, 'KID2'),
      isA<LibraryDone>(),
    );
    read.complete();
    await opening;

    expect(
      fixture.session.source?.path,
      isNot('/repertoires/KID/Main.pgn'),
      reason: 'nothing is there any more; an autosave would find it gone',
    );
  });
}
