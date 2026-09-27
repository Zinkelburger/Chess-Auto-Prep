import 'dart:async';
import 'package:chess_auto_prep/design_system/layout/workspace_branch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/design_system/layout/workspace_navigation_controller.dart';
import 'package:chess_auto_prep/design_system/layout/workspace_shell.dart';
import 'package:chess_auto_prep/widgets/escape_to_pop_scope.dart';

class _Editor extends StatefulWidget {
  const _Editor({required this.navigation});
  final WorkspaceNavigationController navigation;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final text = TextEditingController();
  String result = 'none';
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(key: const ValueKey('draft'), controller: text),
      Text('Result: $result'),
      TextButton(
        onPressed: () async {
          final value = await Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const TextField(key: ValueKey('filter')),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop('selected'),
                      child: const Text('Select'),
                    ),
                  ],
                ),
              ),
            ),
          );
          if (mounted) setState(() => result = value ?? 'cancelled');
        },
        child: const Text('Open picker'),
      ),
    ],
  );
}

Widget _shell(
  WorkspaceNavigationController navigation, {
  FocusNode? toolbarFocus,
}) => WorkspaceShell(
  navigation: navigation,
  appBar: AppBar(title: const Text('Editor commands')),
  destinationAppBar: AppBar(
    title: const Text('Picker commands'),
    actions: [
      TextButton(
        focusNode: toolbarFocus,
        onPressed: navigation.maybePop,
        child: const Text('Back'),
      ),
    ],
  ),
  body: _Editor(navigation: navigation),
);

void main() {
  testWidgets('returning to a workspace restores draft focus and Escape', (
    tester,
  ) async {
    final navigation = WorkspaceNavigationController();
    addTearDown(navigation.dispose);
    var active = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return IndexedStack(
              index: active ? 0 : 1,
              children: [
                WorkspaceBranch(active: active, child: _shell(navigation)),
                WorkspaceBranch(
                  active: !active,
                  child: const Material(
                    child: TextField(key: ValueKey('other')),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('filter')),
      'retained search',
    );
    final focus = FocusManager.instance.primaryFocus;
    rebuild(() => active = false);
    await tester.pumpAndSettle();
    expect(focus!.hasFocus, isFalse);
    expect(focus.canRequestFocus, isFalse);
    await tester.enterText(find.byKey(const ValueKey('other')), 'other draft');
    rebuild(() => active = true);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(find.text('retained search'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Result: cancelled'), findsOneWidget);
    expect(navigation.hasDestination, isFalse);
  });

  testWidgets(
    'nested routes retain draft and typed result; observer sees descendant pushes',
    (tester) async {
      final navigation = WorkspaceNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(MaterialApp(home: _shell(navigation)));
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'unsaved board note',
      );
      final before = tester.state(find.byType(_Editor));
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.text('Picker commands'), findsOneWidget);
      expect(find.text('Editor commands'), findsNothing);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.text('Result: selected'), findsOneWidget);
      expect(tester.state(find.byType(_Editor)), same(before));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('draft')))
            .controller!
            .text,
        'unsaved board note',
      );
    },
  );

  testWidgets(
    'Escape from toolbar unwinds nested route and preserves root navigator',
    (tester) async {
      final navigation = WorkspaceNavigationController();
      final focus = FocusNode();
      addTearDown(navigation.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => EscapeToPopScope(child: child!),
          home: _shell(navigation, toolbarFocus: focus),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Result: cancelled'), findsOneWidget);
      expect(navigation.hasDestination, isFalse);
    },
  );

  testWidgets('Back honors a busy destination PopScope', (tester) async {
    final navigation = WorkspaceNavigationController();
    addTearDown(navigation.dispose);
    await tester.pumpWidget(MaterialApp(home: _shell(navigation)));
    unawaited(
      navigation.push(
        MaterialPageRoute<void>(
          builder: (_) => const PopScope(
            canPop: false,
            child: Scaffold(body: Text('Busy destination')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Busy destination'), findsOneWidget);
    expect(navigation.hasDestination, isTrue);
  });

  testWidgets(
    'root rebuilds do not reset a retained nested route or its filter',
    (tester) async {
      final navigation = WorkspaceNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(MaterialApp(home: _shell(navigation)));
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('filter')), 'Sicilian');
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.light(), home: _shell(navigation)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sicilian'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Result: cancelled'), findsOneWidget);
    },
  );

  testWidgets('popup routes do not replace workspace commands', (tester) async {
    final navigation = WorkspaceNavigationController();
    addTearDown(navigation.dispose);
    await tester.pumpWidget(MaterialApp(home: _shell(navigation)));
    final context = tester.element(find.byKey(const ValueKey('draft')));
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (_) => const AlertDialog(title: Text('Nested popup')),
      ),
    );
    await tester.pumpAndSettle();
    expect(navigation.hasDestination, isFalse);
    expect(find.text('Editor commands'), findsOneWidget);
    expect(find.text('Picker commands'), findsNothing);
  });

  testWidgets(
    'nested back does not pop a root modal or invoke hidden editor callbacks',
    (tester) async {
      final navigation = WorkspaceNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(MaterialApp(home: _shell(navigation)));
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byKey(const ValueKey('filter')));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Modal'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter')), findsOneWidget);
      expect(navigation.hasDestination, isTrue);
    },
  );
}
