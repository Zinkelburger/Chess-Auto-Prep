import 'dart:async';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:chess_auto_prep/design_system/layout/workspace_navigation_controller.dart';
import 'package:chess_auto_prep/design_system/layout/workspace_shell.dart';
import 'package:chess_auto_prep/design_system/theme/app_spacing.dart';
import 'repertoire_cases.dart';
import 'package:chess_auto_prep/design_system/layout/workspace_branch.dart';

List<WidgetbookNode> workspaceCases() => [
  WidgetbookFolder(
    name: 'Workspace',
    children: [
      WidgetbookComponent(
        name: 'Navigation',
        useCases: [
          WidgetbookUseCase(
            name: 'retained library',
            builder: (_) => const CatalogCaseHost(child: _WorkspaceFixture()),
          ),
        ],
      ),
    ],
  ),
];

/// Only the surrounding editor/mode selector is illustrative. Navigation and
/// catalog/creation controls are the same implementations used by the app.
class _WorkspaceFixture extends StatefulWidget {
  const _WorkspaceFixture();
  @override
  State<_WorkspaceFixture> createState() => _WorkspaceFixtureState();
}

class _WorkspaceFixtureState extends State<_WorkspaceFixture> {
  final navigation = WorkspaceNavigationController();
  final draft = TextEditingController();
  bool other = false;
  @override
  void dispose() {
    navigation.dispose();
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        onPressed: () => setState(() => other = !other),
        child: Text(other ? 'Return to workspace' : 'Switch workspace'),
      ),
      Expanded(
        child: IndexedStack(
          index: other ? 1 : 0,
          children: [
            WorkspaceBranch(
              active: !other,
              child: WorkspaceShell(
                navigation: navigation,
                appBar: AppBar(title: const Text('Editor workspace')),
                destinationAppBar: AppBar(
                  title: const Text('Library workspace'),
                  actions: [
                    TextButton(
                      onPressed: navigation.maybePop,
                      child: const Text('Back'),
                    ),
                  ],
                ),
                body: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    children: [
                      TextField(
                        controller: draft,
                        decoration: const InputDecoration(
                          labelText: 'Workspace draft',
                        ),
                      ),
                      TextButton(
                        onPressed: () => unawaited(
                          navigation.push(
                            MaterialPageRoute<void>(
                              builder: (_) => const CatalogFixture(
                                scenario: CatalogScenario.populated,
                              ),
                            ),
                          ),
                        ),
                        child: const Text('Open library'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Center(child: Text('Another workspace')),
          ],
        ),
      ),
    ],
  );
}
