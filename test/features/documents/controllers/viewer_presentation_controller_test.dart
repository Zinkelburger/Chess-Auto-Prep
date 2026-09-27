import 'dart:async';

import 'package:chess_auto_prep/features/documents/controllers/viewer_presentation_controller.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_perspective.dart';
import 'package:chess_auto_prep/features/documents/repositories/desktop_fullscreen_port.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:flutter_test/flutter_test.dart';

class _Window implements DesktopFullscreenPort {
  void Function(bool)? listener;
  Completer<bool>? initial;
  bool fullScreen = false;
  int attaches = 0;
  int detaches = 0;
  final calls = <({bool value, Completer<void> done})>[];
  @override
  Future<bool> attach(void Function(bool) onChanged) async {
    attaches++;
    listener = onChanged;
    return initial == null ? fullScreen : initial!.future;
  }

  @override
  Future<void> setFullScreen(bool value) {
    final done = Completer<void>();
    calls.add((value: value, done: done));
    return done.future;
  }

  void emit(bool value) {
    fullScreen = value;
    listener?.call(value);
  }

  @override
  void detach() {
    detaches++;
    listener = null;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _Window window;
  late ViewerPresentationController owner;
  late int notifications;
  late int focus;
  setUp(() {
    window = _Window();
    notifications = 0;
    focus = 0;
    owner = ViewerPresentationController(
      window: window,
      onChanged: () => notifications++,
      onReclaimFocus: () => focus++,
    );
  });
  tearDown(() => owner.dispose());

  test(
    'native initial state and events are observed for the owner lifetime',
    () async {
      window.fullScreen = true;
      await owner.initialize();
      expect(owner.isFullScreen, isTrue);
      window.emit(false);
      expect(owner.isFullScreen, isFalse);
      expect(window.attaches, 1);
      await owner.initialize();
      expect(window.attaches, 1);
    },
  );

  test('an event newer than the initial snapshot wins', () async {
    window.initial = Completer<bool>();
    final pending = owner.initialize();
    window.emit(true);
    window.initial!.complete(false);
    await pending;
    expect(owner.isFullScreen, isTrue);
  });

  test('toggle waits for the actual initial native state', () async {
    window.initial = Completer<bool>();
    final pending = owner.toggleFullScreen();
    expect(window.calls, isEmpty);
    window.initial!.complete(true);
    await settle();
    expect(window.calls.single.value, isFalse);
    window.calls.single.done.complete();
    await pending;
    expect(owner.isFullScreen, isFalse);
  });

  test(
    'rapid toggles serialize the final intent behind an in-flight enter',
    () async {
      final first = owner.toggleFullScreen();
      await settle();
      expect(window.calls.single.value, isTrue);
      final second = owner.toggleFullScreen();
      await settle();
      expect(window.calls, hasLength(1));
      window.calls.first.done.complete();
      await settle();
      expect(window.calls.map((call) => call.value), [true, false]);
      expect(owner.changingWindow, isTrue);
      window.calls.last.done.complete();
      await Future.wait([first, second]);
      expect(owner.isFullScreen, isFalse);
      expect(owner.changingWindow, isFalse);
      expect(focus, 1);
    },
  );

  test(
    'Escape during an in-flight entry exits after the entry acknowledges',
    () async {
      final enter = owner.toggleFullScreen();
      await settle();
      final exit = owner.exitFullScreen();
      await settle();
      window.calls.first.done.complete();
      await settle();
      expect(window.calls.last.value, isFalse);
      window.calls.last.done.complete();
      await Future.wait([enter, exit]);
      expect(owner.isFullScreen, isFalse);
    },
  );

  test(
    'failed native requests retain actual state and can be retried',
    () async {
      final first = owner.toggleFullScreen();
      await settle();
      window.calls.single.done.completeError(StateError('native refused'));
      await first;
      expect(owner.error, isA<StateError>());
      expect(owner.isFullScreen, isFalse);
      expect(owner.changingWindow, isFalse);
      expect(focus, 0);
      final retry = owner.toggleFullScreen();
      await settle();
      window.calls.last.done.complete();
      await retry;
      expect(owner.error, isNull);
      expect(owner.isFullScreen, isTrue);
    },
  );

  test(
    'an obsolete request failure cannot replace a newer exit intent',
    () async {
      final enter = owner.toggleFullScreen();
      await settle();
      final exit = owner.exitFullScreen();
      await settle();
      window.calls.single.done.completeError(StateError('old enter failed'));
      await Future.wait([enter, exit]);
      expect(owner.error, isNull);
      expect(owner.isFullScreen, isFalse);
      expect(owner.changingWindow, isFalse);
    },
  );

  test('a failed initial read detaches, reports failure and retries', () async {
    window.initial = Completer<bool>();
    final first = owner.initialize();
    window.initial!.completeError(StateError('native unavailable'));
    await first;
    expect(owner.error, isA<StateError>());
    expect(window.listener, isNull);
    window.initial = null;
    final retry = owner.toggleFullScreen();
    await settle();
    expect(window.attaches, 2);
    window.calls.single.done.complete();
    await retry;
    expect(owner.isFullScreen, isTrue);
    expect(owner.error, isNull);
  });

  test(
    'disposal silences late initialization and retained native callbacks',
    () async {
      window.initial = Completer<bool>();
      final pending = owner.initialize();
      final lateCallback = window.listener!;
      owner.dispose();
      final before = notifications;
      lateCallback(true);
      window.initial!.complete(true);
      await pending;
      await owner.toggleFullScreen();
      expect(notifications, before);
      expect(owner.isFullScreen, isFalse);
      expect(window.calls, isEmpty);
      expect(window.listener, isNull);
    },
  );

  test('disposal silences pending operations and focus restoration', () async {
    final pending = owner.toggleFullScreen();
    await settle();
    owner.dispose();
    final before = notifications;
    window.calls.single.done.completeError(StateError('late failure'));
    await pending;
    expect(notifications, before);
    expect(focus, 0);
    expect(owner.error, isNull);
    expect(window.listener, isNull);
  });

  test(
    'player orientation follows names, preserving unknown and ambiguous sides',
    () {
      const player = Perspective(
        mode: PerspectiveMode.player,
        playerName: 'Smith, Jane',
      );
      owner.setPerspective(player, {
        'White': 'Other',
        'Black': ' SMITH, JANE ',
      });
      expect(owner.boardFlipped, isTrue);
      owner.orient({'White': 'Smith, J.', 'Black': 'Other'});
      expect(owner.boardFlipped, isFalse);
      owner.orient({'White': 'Smith, Jane', 'Black': 'Smith, Jane'});
      expect(owner.boardFlipped, isFalse);
      owner.orient({'White': 'Smith, X', 'Black': 'Smith, Y'});
      expect(owner.boardFlipped, isFalse);
      owner.orient({'White': 'Other', 'Black': 'Unknown'});
      expect(owner.boardFlipped, isFalse);
      owner.orient({'White': 'Smith, John', 'Black': 'Smith, Jane'});
      expect(owner.boardFlipped, isTrue);
      expect(focus, 1);
    },
  );

  test('empty player names do not match missing headers', () {
    owner.restoreBoard(flipped: true);
    owner.setPerspective(const Perspective(mode: PerspectiveMode.player), {});
    expect(owner.boardFlipped, isTrue);
  });

  test('manual flip becomes the preference for subsequent games', () {
    owner.toggleBoardFlipped();
    expect(owner.perspective.mode, PerspectiveMode.black);
    owner.orient({'White': 'A', 'Black': 'B'});
    expect(owner.boardFlipped, isTrue);
    owner.toggleBoardFlipped();
    expect(owner.perspective.mode, PerspectiveMode.white);
    expect(owner.boardFlipped, isFalse);
  });

  test(
    'collection headers override inference and single games keep preference',
    () {
      PgnGameEntry game(Map<String, String> headers) =>
          PgnGameEntry(headers: headers, pgnText: '*');
      const current = Perspective(mode: PerspectiveMode.black);
      expect(
        Perspective.forCollection([
          game({'White': 'A'}),
        ], current: current),
        current,
      );
      expect(
        Perspective.forCollection([
          game({'StudyPerspective': 'white'}),
        ], current: current).mode,
        PerspectiveMode.white,
      );
      expect(
        Perspective.forCollection([
          game({'White': 'A', 'Black': 'B'}),
          game({'White': 'C', 'Black': 'A'}),
        ], current: current),
        const Perspective(mode: PerspectiveMode.player, playerName: 'A'),
      );
      expect(Perspective.fromHeaderValue('auto').mode, PerspectiveMode.white);
      expect(
        Perspective.fromHeaderValue(' Smith, Jane ').toHeaderValue(),
        'Smith, Jane',
      );
    },
  );
}
