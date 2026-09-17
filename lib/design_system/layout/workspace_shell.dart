import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'workspace_navigation_controller.dart';

/// Persistent chrome with a retained nested route stack. Domain/session state
/// stays in its owner; route retention is not restart restoration.
class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({
    super.key,
    required this.navigation,
    required this.appBar,
    required this.destinationAppBar,
    required this.body,
  });
  final WorkspaceNavigationController navigation;
  final PreferredSizeWidget appBar;
  final PreferredSizeWidget destinationAppBar;
  final Widget body;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: navigation,
    builder: (context, _) => Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            navigation.hasDestination) {
          unawaited(navigation.maybePop());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: navigation.hasDestination
              ? destinationAppBar.preferredSize
              : appBar.preferredSize,
          child: Stack(
            children: [
              // Keep view-owned settings registration alive. Hidden commands cannot
              // receive focus, pointer events or semantics while a child is visible.
              Offstage(
                offstage: navigation.hasDestination,
                child: ExcludeFocus(
                  excluding: navigation.hasDestination,
                  child: appBar,
                ),
              ),
              if (navigation.hasDestination) destinationAppBar,
            ],
          ),
        ),
        body: _WorkspaceRootScope(
          body: body,
          child: NavigatorPopHandler(
            onPopWithResult: (result) =>
                navigation.navigatorKey.currentState?.pop(result),
            child: Navigator(
              key: navigation.navigatorKey,
              observers: [navigation.observer],
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const _WorkspaceRoot(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _WorkspaceRootScope extends InheritedWidget {
  const _WorkspaceRootScope({required this.body, required super.child});
  final Widget body;
  @override
  bool updateShouldNotify(_WorkspaceRootScope oldWidget) =>
      body != oldWidget.body;
}

class _WorkspaceRoot extends StatelessWidget {
  const _WorkspaceRoot();
  @override
  Widget build(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WorkspaceRootScope>()!.body;
}
