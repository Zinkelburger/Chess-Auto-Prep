/// The app-wide Escape contract: "leave what I'm in".
///
/// Flutter pops a route on Escape only when that route is `barrierDismissible`,
/// which covers ordinary dialogs and nothing else — a pushed page (Settings,
/// Select Player) and a `barrierDismissible: false` dialog both leave the key
/// dead. [EscapeToPopScope] catches the [DismissIntent] those routes decline.
///
/// The four things it must get right, one test each: it pops what Flutter
/// won't, it stays out of the way at the root, anything closer to the focus
/// still wins, and a `PopScope` guarding in-flight work still blocks it.
library;

import 'package:chess_auto_prep/widgets/escape_to_pop_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Escape reaches an `Actions` widget through a `Shortcuts` lookup that
  /// starts at the *primary focus*. With nothing focused the lookup starts
  /// above the app's builder instead and never sees [EscapeToPopScope], so
  /// every route here focuses something — as every real screen does.
  Widget focused(Widget child) => Focus(autofocus: true, child: child);

  /// How many Escape presses travelled *past* [EscapeToPopScope] unclaimed.
  /// Non-zero means the key was left for someone else rather than silently
  /// swallowed.
  late int fellThrough;

  /// The real wiring from `main.dart`: mounted above the Navigator through
  /// `MaterialApp.builder`. The outer `Focus` is the test's probe — key events
  /// travel focus-upward, so it is only reached when the scope declines.
  Widget app(Widget home) {
    fellThrough = 0;
    return MaterialApp(
      builder: (context, child) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            fellThrough++;
          }
          return KeyEventResult.ignored;
        },
        child: EscapeToPopScope(child: child!),
      ),
      home: home,
    );
  }

  /// A home screen with one button that pushes [page] as a page route.
  Widget homePushing(Widget page) => Builder(
    builder: (context) => Scaffold(
      body: focused(
        Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => page)),
            child: const Text('Open page'),
          ),
        ),
      ),
    ),
  );

  Future<void> pressEscape(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets('Escape pops a pushed page, which Flutter alone leaves '
      'stranded', (tester) async {
    await tester.pumpWidget(
      app(
        homePushing(
          const Scaffold(body: Focus(autofocus: true, child: Text('Settings'))),
        ),
      ),
    );
    await tester.tap(find.text('Open page'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await pressEscape(tester);

    expect(find.text('Settings'), findsNothing);
    expect(find.text('Open page'), findsOneWidget);
    expect(fellThrough, 0, reason: 'the scope claimed the key');
  });

  testWidgets('Escape closes a dialog opened with barrierDismissible: false', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: focused(
              Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const AlertDialog(
                      content: Focus(
                        autofocus: true,
                        child: Text('Are you sure?'),
                      ),
                    ),
                  ),
                  child: const Text('Ask'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure?'), findsOneWidget);

    await pressEscape(tester);

    expect(find.text('Are you sure?'), findsNothing);
  });

  testWidgets('at the root route Escape is left for someone else, not '
      'swallowed', (tester) async {
    await tester.pumpWidget(
      app(const Scaffold(body: Focus(autofocus: true, child: Text('Home')))),
    );

    await pressEscape(tester);

    // Nothing to pop, so the scope reports the key ignored and it carries on
    // up the chain — the home screen's own Escape meaning survives.
    expect(find.text('Home'), findsOneWidget);
    expect(fellThrough, 1);
  });

  testWidgets('a screen that gives Escape its own meaning still wins', (
    tester,
  ) async {
    var claimed = 0;
    await tester.pumpWidget(
      app(
        homePushing(
          Scaffold(
            // `Focus.onKeyEvent` runs focus-upward *before* any
            // Shortcuts/Actions lookup, which is the whole reason the scope can
            // be a safe app-wide default: a drill screen that means "leave this
            // line" by Escape is not overruled by it.
            body: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent ||
                    event.logicalKey != LogicalKeyboardKey.escape) {
                  return KeyEventResult.ignored;
                }
                claimed++;
                return KeyEventResult.handled;
              },
              child: const Text('Drill'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open page'));
    await tester.pumpAndSettle();

    await pressEscape(tester);

    expect(claimed, 1);
    expect(find.text('Drill'), findsOneWidget, reason: 'the route stayed put');
    expect(fellThrough, 0);
  });

  testWidgets('a PopScope guarding in-flight work still blocks the pop', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        homePushing(
          const PopScope(
            canPop: false,
            child: Scaffold(
              body: Focus(autofocus: true, child: Text('Downloading…')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open page'));
    await tester.pumpAndSettle();

    await pressEscape(tester);

    // The pop goes through NavigatorState.maybePop, so the guard is honoured
    // rather than bypassed — the download dialogs depend on this.
    expect(find.text('Downloading…'), findsOneWidget);
  });
}
