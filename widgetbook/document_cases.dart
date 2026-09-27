import 'dart:async';

import 'package:chess_auto_prep/design_system/theme/app_spacing.dart';
import 'package:chess_auto_prep/features/documents/controllers/document_save_session.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_document_store.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_save_panel.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'repertoire_cases.dart' show CatalogCaseHost;

List<WidgetbookNode> documentCases() => [
  WidgetbookFolder(
    name: 'Documents',
    children: [
      WidgetbookComponent(
        name: 'Save',
        useCases: [
          for (final scenario in DocumentSaveScenario.values)
            WidgetbookUseCase(
              name: scenario.name,
              builder: (_) => CatalogCaseHost(
                child: DocumentSaveFixture(
                  key: ValueKey(scenario),
                  scenario: scenario,
                ),
              ),
            ),
        ],
      ),
    ],
  ),
];

enum DocumentSaveScenario {
  clean,
  dirty,
  saving,
  conflict,
  collision,
  failed,
  uncertain,
}

/// Fixture editor only; save state and interaction are production components.
class DocumentSaveFixture extends StatefulWidget {
  const DocumentSaveFixture({super.key, required this.scenario});
  final DocumentSaveScenario scenario;
  @override
  State<DocumentSaveFixture> createState() => _DocumentSaveFixtureState();
}

class _DocumentSaveFixtureState extends State<DocumentSaveFixture> {
  late final store = MemoryDocumentStore(widget.scenario);
  late final session = DocumentSaveSession.opened(
    store,
    store.files.values.first,
  );
  late final editor = TextEditingController(text: session.state.content);
  final focus = FocusNode();
  StreamSubscription<DocumentSaveState>? subscription;
  @override
  void initState() {
    super.initState();
    subscription = session.changes.listen((state) {
      if (editor.text != state.content) editor.text = state.content;
    });
    if (widget.scenario != DocumentSaveScenario.clean) {
      session.edit('[Event "My draft"]\n\n1. d4 d5 *');
      if (widget.scenario == DocumentSaveScenario.collision) {
        unawaited(session.saveCopy('/fixture/Main.pgn'));
      } else if (widget.scenario != DocumentSaveScenario.dirty) {
        unawaited(session.save());
      }
    }
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    unawaited(session.dispose());
    editor.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('document-draft'),
            controller: editor,
            focusNode: focus,
            minLines: 4,
            maxLines: 8,
            onChanged: session.edit,
          ),
          const SizedBox(height: AppSpacing.lg),
          DocumentSavePanel(
            session: session,
            focusEditor: focus.requestFocus,
            chooseCopyDestination: (context) => showDialog<String>(
              context: context,
              useRootNavigator: false,
              builder: (_) => const _CopyDestinationDialog(),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CopyDestinationDialog extends StatefulWidget {
  const _CopyDestinationDialog();
  @override
  State<_CopyDestinationDialog> createState() => _CopyDestinationDialogState();
}

class _CopyDestinationDialogState extends State<_CopyDestinationDialog> {
  final name = TextEditingController(text: '/fixture/Copy.pgn');
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.saveCopy),
      scrollable: true,
      content: TextField(
        controller: name,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.copyDestination),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isNotEmpty) {
              Navigator.of(context).pop(name.text.trim());
            }
          },
          child: Text(l10n.saveChanges),
        ),
      ],
    );
  }
}

/// Memory-only scripted outcomes; never instantiates an external storage owner.
class MemoryDocumentStore implements PgnDocumentStore {
  @override
  bool get supportsQuarantine => false;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) async => PgnQuarantineFailed(UnsupportedError('Unused in this fixture'));

  MemoryDocumentStore(this.scenario) {
    files['/fixture/Main.pgn'] = _snapshot(
      '/fixture/Main.pgn',
      '[Event "On disk"]\n\n1. e4 e5 *',
    );
  }
  final DocumentSaveScenario scenario;
  final files = <String, PgnSnapshot>{};
  int revision = 0;
  bool scripted = false;
  PgnSnapshot _snapshot(String path, String content) => PgnSnapshot(
    path: path,
    content: content,
    revision: PgnRevision(
      documentId: path,
      nativeIdentity: '${++revision}',
      sha256: content,
    ),
  );
  @override
  Future<PgnOpenResult> open(String path) async =>
      files[path] == null ? const PgnMissing() : PgnOpened(files[path]!);
  @override
  Future<PgnWriteResult> create(String path, String content) async {
    if (files.containsKey(path)) return const PgnNameCollision();
    final after = _snapshot(path, content);
    files[path] = after;
    return PgnSaved(before: null, after: after);
  }

  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) async {
    if (!scripted) {
      scripted = true;
      if (scenario == DocumentSaveScenario.saving) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (scenario == DocumentSaveScenario.failed) {
        return PgnWriteFailed(StateError('Scripted disk failure'));
      }
      if (scenario == DocumentSaveScenario.conflict) {
        files[baseline.path] = _snapshot(
          baseline.path,
          '[Event "External edit"]\n\n1. c4 e5 *',
        );
      }
      if (scenario == DocumentSaveScenario.uncertain) {
        final observed = _snapshot(baseline.path, content);
        files[baseline.path] = observed;
        return PgnWriteUncertain(
          error: StateError('Scripted flush failure'),
          before: baseline,
          observed: observed,
        );
      }
    }
    if (files[baseline.path]?.revision != baseline.revision) {
      return PgnConflict(files[baseline.path]);
    }
    final after = _snapshot(baseline.path, content);
    files[baseline.path] = after;
    return PgnSaved(before: baseline, after: after);
  }
}
