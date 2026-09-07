/// How fast the app moves between screens and opens menus.
///
/// Material's defaults are tuned for a phone: a pushed route zooms in over
/// 300 ms and a popup menu grows over 300 ms. On a desktop, where the click
/// came from a mouse and the new screen is the whole window, that is a
/// noticeable wait before anything happens — the App settings route was the
/// slowest-feeling click in the app while doing no real work at all. Every
/// route and every `⋮` menu reads its timing from here, so it is decided once.
library;

import 'package:flutter/material.dart';

class AppMotion {
  AppMotion._();

  /// A pushed route fades in over this long, both ways.
  static const Duration route = Duration(milliseconds: 150);

  /// A popup menu opens and closes in this long.
  static const Duration menu = Duration(milliseconds: 100);

  /// [ThemeData.pageTransitionsTheme] for the desktop targets we ship.
  /// Mobile keeps Material's defaults, which nothing here runs on.
  static const PageTransitionsTheme pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.linux: QuickFadePageTransitionsBuilder(),
      TargetPlatform.windows: QuickFadePageTransitionsBuilder(),
      TargetPlatform.macOS: QuickFadePageTransitionsBuilder(),
    },
  );

  /// `PopupMenuButton.popUpAnimationStyle` for every menu in the app.
  static const AnimationStyle menuAnimation = AnimationStyle(
    duration: menu,
    reverseDuration: menu,
    curve: Curves.easeOut,
  );
}

/// The new route fades in on top of the old one; nothing scales, slides or
/// snapshots. Cheap to draw and over in [AppMotion.route].
class QuickFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const QuickFadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.route;

  @override
  Duration get reverseTransitionDuration => AppMotion.route;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}
