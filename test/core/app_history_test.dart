import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The breadcrumb trail records navigation by intercepting [AppState]'s two
/// choke points: handOff (→ push) and setMode (→ reset). These tests pin the
/// stack semantics: crumbs re-deliver their handoff, mode switches erase the
/// trail, and re-delivery never re-records itself.
void main() {
  (AppState, AppHistory) build() {
    final state = AppState();
    return (state, AppHistory(state));
  }

  group('recording', () {
    test('starts with the current mode as the root crumb', () {
      final (_, history) = build();
      expect(history.entries, hasLength(1));
      expect(history.entries.single.mode, AppMode.tactics);
      expect(history.entries.single.label, 'Tactics');
      expect(history.canGoBack, isFalse);
    });

    test('a handoff pushes a labeled crumb', () {
      final (state, history) = build();
      state.switchToBuilder(
        repertoirePath: '/r/main.pgn',
        historyLabel: 'Repertoire: Main',
      );
      expect(history.entries, hasLength(2));
      expect(history.entries.last.label, 'Repertoire: Main');
      expect(history.entries.last.mode, AppMode.repertoire);
      expect(history.canGoBack, isTrue);
    });

    test(
      'a handoff without an explicit label derives one from the payload',
      () {
        final (state, history) = build();
        state.switchToBuilder(
          repertoirePath: '/repertoires/Dynamic d4/Main.pgn',
        );
        expect(history.entries.last.label, 'Repertoire: Main');
      },
    );

    test('setMode erases the trail down to the new root', () {
      final (state, history) = build();
      state.switchToPgnViewer(path: '/g.pgn');
      state.switchToBuilder(repertoirePath: '/r.pgn');
      expect(history.entries, hasLength(3));

      state.setMode(AppMode.study);
      expect(history.entries, hasLength(1));
      expect(history.entries.single.label, 'Study');
      expect(history.canGoBack, isFalse);
    });

    test('pushMode pushes a payload-free crumb instead of resetting', () {
      final (state, history) = build();
      state.pushMode(AppMode.study, historyLabel: 'Study: Endgames');
      expect(history.entries, hasLength(2));
      expect(history.entries.last.handoff, isNull);
      expect(state.currentMode, AppMode.study);
    });

    test('re-pushing the same destination replaces the top crumb', () {
      final (state, history) = build();
      state.switchToBuilder(repertoirePath: '/r.pgn', historyLabel: 'R');
      state.switchToBuilder(repertoirePath: '/r.pgn', historyLabel: 'R');
      expect(history.entries, hasLength(2));
    });

    test('the trail is capped and drops the oldest crumb', () {
      final (state, history) = build();
      for (var i = 0; i < AppHistory.maxEntries + 3; i++) {
        state.switchToPgnViewer(path: '/g$i.pgn', historyLabel: 'G$i');
      }
      expect(history.entries, hasLength(AppHistory.maxEntries));
      expect(history.entries.first.label, isNot('Tactics'));
    });
  });

  group('popTo', () {
    test('re-delivers the crumb\'s handoff and truncates after it', () {
      final (state, history) = build();
      state.switchToPgnViewer(path: '/g.pgn', historyLabel: 'Game A vs B');
      state.switchToBuilder(repertoirePath: '/r.pgn', historyLabel: 'R');

      history.popTo(1);
      expect(history.entries, hasLength(2));
      expect(history.entries.last.label, 'Game A vs B');
      expect(state.currentMode, AppMode.pgnViewer);
      // The re-delivered handoff is waiting for the viewer, exactly as if
      // the producer had fired it.
      expect(state.takeHandoff<OpenPgnViewer>()?.pgnPath, '/g.pgn');
    });

    test('re-delivery does not re-record itself as a new crumb', () {
      final (state, history) = build();
      state.switchToPgnViewer(path: '/g.pgn', historyLabel: 'G');
      history.popTo(0);
      expect(history.entries, hasLength(1));
      expect(history.entries.single.label, 'Tactics');
    });

    test('popping to a payload-free root is a bare mode switch', () {
      final (state, history) = build();
      state.switchToBuilder(repertoirePath: '/r.pgn');
      history.popTo(0);
      expect(state.currentMode, AppMode.tactics);
      expect(state.hasPending<OpenBuilder>(), isFalse);
    });

    test('clicking the current crumb or an invalid index is a no-op', () {
      final (state, history) = build();
      state.switchToBuilder(repertoirePath: '/r.pgn');
      final before = history.entries;
      history.popTo(1); // current
      history.popTo(5); // out of range
      history.popTo(-1);
      expect(history.entries, before);
      expect(state.currentMode, AppMode.repertoire);
    });

    test('back() pops one crumb', () {
      final (state, history) = build();
      state.switchToPgnViewer(path: '/g.pgn');
      state.switchToBuilder(repertoirePath: '/r.pgn');
      history.back();
      expect(history.entries, hasLength(2));
      expect(state.currentMode, AppMode.pgnViewer);
      history.back();
      expect(state.currentMode, AppMode.tactics);
      history.back(); // at root: no-op
      expect(history.entries, hasLength(1));
    });
  });
}
