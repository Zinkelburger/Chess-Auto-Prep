import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/theme/app_motion.dart';

/// A home page with one button that pushes a second page, under a theme that
/// uses the app's page transitions and reports itself as [platform].
Widget _app(TargetPlatform platform) => MaterialApp(
  theme: ThemeData(
    platform: platform,
    pageTransitionsTheme: AppMotion.pageTransitions,
  ),
  home: Builder(
    builder: (context) => TextButton(
      onPressed: () => Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Second page')),
        ),
      ),
      child: const Text('Push'),
    ),
  ),
);

void main() {
  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('a pushed route is fully in after ${AppMotion.route} on '
        '$platform', (tester) async {
      await tester.pumpWidget(_app(platform));
      await tester.tap(find.text('Push'));
      // One frame inserts the route into the overlay, the next builds it.
      await tester.pump();
      await tester.pump();

      final route = ModalRoute.of(tester.element(find.text('Second page')))!;
      expect(route.transitionDuration, AppMotion.route);
      expect(route.reverseTransitionDuration, AppMotion.route);
      expect(route.animation!.status, AnimationStatus.forward);

      // The ticker only starts on the frame after the push, so give it one
      // extra frame past the full duration to report completion.
      await tester.pump(AppMotion.route);
      await tester.pump(const Duration(milliseconds: 1));
      expect(route.animation!.status, AnimationStatus.completed);
      expect(
        tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: find.text('Second page'),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value,
        1.0,
      );
    });
  }

  testWidgets('the route fades in rather than zooming or sliding', (
    tester,
  ) async {
    await tester.pumpWidget(_app(TargetPlatform.linux));
    await tester.tap(find.text('Push'));
    await tester.pump();
    await tester.pump();
    await tester.pump(AppMotion.route ~/ 2);

    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Second page'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, greaterThan(0.0));
    expect(fade.opacity.value, lessThan(1.0));
    // No transform means nothing is scaled or slid; the page sits where it
    // will end up and only its opacity is still moving.
    expect(
      find.ancestor(
        of: find.text('Second page'),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text('Second page'),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
  });

  test('menus open and close in the same short time', () {
    expect(AppMotion.menuAnimation.duration, AppMotion.menu);
    expect(AppMotion.menuAnimation.reverseDuration, AppMotion.menu);
    expect(AppMotion.menu, lessThan(AppMotion.route));
  });
}
