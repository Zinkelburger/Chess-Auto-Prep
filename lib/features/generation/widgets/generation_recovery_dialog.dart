import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../design_system/theme/app_spacing.dart';
import '../../../design_system/theme/app_typography.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../chess_core/generation/build_tree_node.dart';
import '../../../utils/chess_utils.dart' show formatPackedEval;
import '../controllers/generation_recovery_controller.dart';
import '../models/generation_artifacts.dart';
import '../models/generation_recovery.dart';
import '../services/generation_artifacts.dart';

/// Recovery inspection is detached from the live chapter, tree and engine.
class GenerationRecoveryDialog extends StatefulWidget {
  const GenerationRecoveryDialog({
    super.key,
    this.path,
    required this.artifacts,
    required this.chooseExportDestination,
  });
  final String? path;
  final GenerationArtifacts artifacts;
  final Future<String?> Function(GenerationRecoveryFileKind)
  chooseExportDestination;

  @override
  State<GenerationRecoveryDialog> createState() =>
      _GenerationRecoveryDialogState();
}

class _GenerationRecoveryDialogState extends State<GenerationRecoveryDialog> {
  late final _controller = GenerationRecoveryController(widget.artifacts);
  GenerationRecoveryItem? _selected;
  BuildTreeNode? _node;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.path == null
          ? _controller.loadSources()
          : _controller.load(widget.path!),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _label(GenerationRecoveryFileKind kind, AppLocalizations l10n) =>
      switch (kind) {
        GenerationRecoveryFileKind.tree => l10n.generationRecoveryTree,
        GenerationRecoveryFileKind.probes => l10n.generationRecoveryProbes,
        GenerationRecoveryFileKind.traps => l10n.generationRecoveryTraps,
        GenerationRecoveryFileKind.partial => l10n.generationRecoveryPartial,
        GenerationRecoveryFileKind.course => l10n.generationRecoveryCourse,
        GenerationRecoveryFileKind.modelGames =>
          l10n.generationRecoveryModelGames,
        GenerationRecoveryFileKind.manifest => l10n.generationRecoveryManifest,
        GenerationRecoveryFileKind.receipt => l10n.generationRecoveryReceipt,
      };

  void _select(GenerationRecoveryItem item) => setState(() {
    _selected = item;
    _node = item.tree?.root;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      child: SizedBox(
        width: 1000,
        height: 720,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final inspection = _controller.inspection;
              final selected = _selected;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final stacked =
                      constraints.maxWidth < 700 ||
                      MediaQuery.textScalerOf(context).scale(14) > 21;
                  final details = selected == null
                      ? Center(child: Text(l10n.generationRecoverySelect))
                      : _details(selected, l10n);
                  return PopScope(
                    canPop: !_controller.exporting,
                    child: ListView(
                      primary: false,
                      key: const Key('generation-recovery-scroll'),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.generationRecoveryTitle,
                                style: AppTypography.title(context),
                              ),
                            ),
                            IconButton(
                              tooltip: l10n.closeDocumentInspection,
                              onPressed: _controller.exporting
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        SelectableText(
                          _controller.chapterPath ??
                              l10n.generationRecoveryAllSources,
                          style: AppTypography.caption(context),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          l10n.generationRecoveryReadOnly,
                          style: AppTypography.body(context),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextButton.icon(
                          key: const Key('recovery-all-sources'),
                          onPressed:
                              _controller.loading || _controller.exporting
                              ? null
                              : () {
                                  setState(() {
                                    _selected = null;
                                    _node = null;
                                  });
                                  unawaited(_controller.loadSources());
                                },
                          icon: const Icon(Icons.folder_open),
                          label: Text(l10n.generationRecoveryAllSources),
                        ),
                        if (_controller.chapterPath == null) ...[
                          Text(l10n.generationRecoveryDeletedRepertoire),
                          if (_controller.sources case final sources?) ...[
                            for (final failure in sources.failures.entries) ...[
                              SelectableText(failure.key),
                              _failure(failure.value, l10n),
                            ],
                            if (sources.entries.isEmpty)
                              Text(l10n.generationRecoveryNoSources),
                            for (final source in sources.entries)
                              ListTile(
                                key: ValueKey(
                                  'recovery-source-${source.label}',
                                ),
                                title: Text(source.label),
                                onTap: _controller.exporting
                                    ? null
                                    : () {
                                        setState(() {
                                          _selected = null;
                                          _node = null;
                                        });
                                        unawaited(
                                          _controller.load(source.path),
                                        );
                                      },
                              ),
                          ],
                        ],
                        if (_controller.catalog case final catalog?)
                          ExpansionTile(
                            key: const Key('recovery-catalog'),
                            title: Text(l10n.generationRecoveryChooseOutput),
                            subtitle: Text(
                              _controller.selected?.legacy == true
                                  ? l10n.generationRecoveryLegacyFiles
                                  : _controller.selected?.id ?? '',
                            ),
                            children: [
                              for (final entry in catalog.entries)
                                ListTile(
                                  key: ValueKey('recovery-run-${entry.id}'),
                                  title: Text(
                                    entry.legacy
                                        ? l10n.generationRecoveryLegacyFiles
                                        : entry.id,
                                  ),
                                  subtitle: entry.error == null
                                      ? null
                                      : Text(l10n.generationRecoveryReadFailed),
                                  selected: identical(
                                    entry,
                                    _controller.selected,
                                  ),
                                  onTap: _controller.exporting
                                      ? null
                                      : () {
                                          setState(() {
                                            _selected = null;
                                            _node = null;
                                          });
                                          unawaited(_controller.select(entry));
                                        },
                                ),
                            ],
                          ),
                        if (inspection != null)
                          ..._provenance(inspection.snapshot, l10n),
                        Wrap(
                          spacing: AppSpacing.sm,
                          children: [
                            TextButton.icon(
                              onPressed:
                                  _controller.loading || _controller.exporting
                                  ? null
                                  : () {
                                      setState(() {
                                        _selected = null;
                                        _node = null;
                                      });
                                      unawaited(
                                        _controller.chapterPath == null
                                            ? _controller.loadSources()
                                            : _controller.load(
                                                _controller.chapterPath!,
                                              ),
                                      );
                                    },
                              icon: const Icon(Icons.refresh),
                              label: Text(l10n.refresh),
                            ),
                            if (selected != null && selected.file.bytes != null)
                              OutlinedButton.icon(
                                key: const Key('generation-recovery-export'),
                                onPressed: _controller.exporting
                                    ? null
                                    : () => unawaited(
                                        _controller.export(
                                          selected.file,
                                          () => widget.chooseExportDestination(
                                            selected.kind,
                                          ),
                                        ),
                                      ),
                                icon: const Icon(Icons.save_alt),
                                label: Text(l10n.generationRecoveryExport),
                              ),
                            if (_controller.exporting)
                              const CircularProgressIndicator(),
                          ],
                        ),
                        if (_controller.error case final error?)
                          _failure(error, l10n),
                        if (_controller.exportedPath case final path?)
                          SelectableText(l10n.generationRecoveryExported(path)),
                        const Divider(),
                        if (_controller.loading)
                          const Center(child: CircularProgressIndicator())
                        else if (_controller.chapterPath == null)
                          const SizedBox.shrink()
                        else if (inspection == null ||
                            (inspection.items.isEmpty &&
                                inspection.snapshot.files.isEmpty))
                          Text(l10n.generationRecoveryEmpty)
                        else if (stacked) ...[
                          ..._choices(inspection, l10n),
                          const Divider(),
                          if (selected != null)
                            ..._detailWidgets(selected, l10n)
                          else
                            Text(l10n.generationRecoverySelect),
                        ] else
                          SizedBox(
                            height: math.max(360, constraints.maxHeight - 230),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: 220,
                                  child: _chooser(inspection, l10n),
                                ),
                                const VerticalDivider(),
                                Expanded(child: details),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _chooser(
    GenerationRecoveryInspection inspection,
    AppLocalizations l10n,
  ) => ListView(
    primary: false,
    key: const Key('generation-recovery-chooser'),
    children: _choices(inspection, l10n),
  );

  List<Widget> _choices(
    GenerationRecoveryInspection inspection,
    AppLocalizations l10n,
  ) => [
    for (final file in inspection.snapshot.files) ...[
      Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Text(
          _label(file.kind, l10n),
          style: AppTypography.bodyStrong(context),
        ),
      ),
      for (final (index, item)
          in inspection.items.where((item) => item.kind == file.kind).indexed)
        ListTile(
          key: Key('recovery-${file.kind.name}-$index'),
          selected: identical(_selected, item),
          leading: Icon(
            item.error == null
                ? Icons.description_outlined
                : Icons.error_outline,
          ),
          title: Text(
            item.tree?.startMoves.isNotEmpty == true
                ? item.tree!.startMoves
                : item.trap?.movesSan.join(' ') ??
                      l10n.generationRecoveryEntry(index + 1),
          ),
          subtitle: item.error == null
              ? null
              : Text(l10n.generationRecoveryUnreadable),
          onTap: () => _select(item),
        ),
    ],
  ];

  List<Widget> _provenance(
    GenerationRecoverySnapshot snapshot,
    AppLocalizations l10n,
  ) => [
    if (snapshot.entry.legacy)
      Text(l10n.generationRecoveryProvenance)
    else ...[
      SelectableText(
        snapshot.entry.path,
        style: AppTypography.caption(context),
      ),
      if (snapshot.runId case final id?) _value(l10n.generationRecoveryRun, id),
      if (snapshot.recordedSource case final source?)
        _value(l10n.generationRecoverySource, source),
      Text(switch (snapshot.sourceState) {
        GenerationRecoverySource.unrecorded =>
          l10n.generationRecoverySourceUnknown,
        GenerationRecoverySource.matches =>
          l10n.generationRecoverySourceMatches,
        GenerationRecoverySource.changed =>
          l10n.generationRecoverySourceChanged,
        GenerationRecoverySource.unavailable =>
          l10n.generationRecoverySourceUnavailable,
      }),
      Text(
        snapshot.namedBySelection
            ? l10n.generationRecoverySelectionNames
            : l10n.generationRecoverySelectionUnknown,
      ),
      if (snapshot.files.any(
        (file) => const {
          GenerationRecoveryFileKind.course,
          GenerationRecoveryFileKind.modelGames,
          GenerationRecoveryFileKind.receipt,
        }.contains(file.kind),
      ))
        Text(switch (snapshot.receipt) {
          GenerationRecoveryReceipt.absent =>
            l10n.generationRecoveryReceiptAbsent,
          GenerationRecoveryReceipt.recorded =>
            l10n.generationRecoveryReceiptPresent,
          GenerationRecoveryReceipt.unreadable =>
            l10n.generationRecoveryReceiptUnreadable,
        }),
      if (snapshot.error case final error?) _failure(error, l10n),
      if (snapshot.config.isNotEmpty)
        ExpansionTile(
          title: Text(l10n.generationRecoveryConfig),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(snapshot.config),
              style: AppTypography.mono(context),
            ),
          ],
        ),
    ],
    const SizedBox(height: AppSpacing.sm),
  ];

  Widget _failure(Object error, AppLocalizations l10n) {
    final message = switch (error) {
      GenerationArtifactFailure(
        kind: GenerationArtifactFailureKind.enumerate,
      ) =>
        l10n.generationRecoveryListFailed,
      GenerationArtifactFailure(kind: GenerationArtifactFailureKind.read) =>
        l10n.generationRecoveryReadFailed,
      GenerationArtifactFailure(kind: GenerationArtifactFailureKind.decode) =>
        l10n.generationRecoveryDecodeFailed,
      GenerationArtifactFailure(
        kind: GenerationArtifactFailureKind.collision,
      ) =>
        l10n.generationRecoveryCollision,
      GenerationArtifactFailure(kind: GenerationArtifactFailureKind.export) =>
        l10n.generationRecoveryExportFailed,
      GenerationArtifactFailure(
        kind: GenerationArtifactFailureKind.uncertain,
      ) =>
        l10n.generationRecoveryExportUncertain,
      _ => l10n.generationRecoveryLoadFailed,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        if (error case GenerationArtifactFailure(
          kind: GenerationArtifactFailureKind.uncertain,
          proposalPath: final path?,
        ))
          SelectableText(l10n.generationRecoveryDestination(path)),
        ExpansionTile(
          title: Text(l10n.generationRecoveryDiagnostics),
          children: [
            SizedBox(
              height: 100,
              child: SingleChildScrollView(
                child: SelectableText(
                  '$error',
                  style: AppTypography.mono(context),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _value(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Wrap(
      spacing: AppSpacing.sm,
      children: [
        Text(label, style: AppTypography.secondary(context)),
        SelectableText(value, style: AppTypography.bodyStrong(context)),
      ],
    ),
  );

  Widget _details(GenerationRecoveryItem item, AppLocalizations l10n) =>
      ListView(
        primary: false,
        key: ValueKey(item),
        padding: const EdgeInsets.all(AppSpacing.sm),
        children: _detailWidgets(item, l10n),
      );

  List<Widget> _detailWidgets(
    GenerationRecoveryItem item,
    AppLocalizations l10n,
  ) {
    final tree = item.tree;
    final node = _node;
    const json = JsonEncoder.withIndent('  ');
    return [
      if (item.kind == GenerationRecoveryFileKind.partial) ...[
        Text(
          _controller.selected?.legacy == true
              ? l10n.generationRecoveryResumeUnavailable
              : l10n.generationRecoveryResumeRetained,
          style: AppTypography.bodyStrong(context),
        ),
        const SizedBox(height: AppSpacing.md),
      ],
      SelectableText(item.file.path, style: AppTypography.caption(context)),
      if (item.file.integrity == GenerationRecoveryIntegrity.changed)
        Text(
          l10n.generationRecoveryIntegrityChanged,
          style: AppTypography.bodyStrong(context),
        )
      else if (item.file.integrity == GenerationRecoveryIntegrity.matches)
        Text(l10n.generationRecoveryIntegrityMatches),
      if (item.error case final error?) _failure(error, l10n),
      if (item.kind == GenerationRecoveryFileKind.course ||
          item.kind == GenerationRecoveryFileKind.modelGames)
        SelectableText(
          item.file.text ?? '',
          style: AppTypography.mono(context),
        ),
      if (item.kind == GenerationRecoveryFileKind.manifest ||
          item.kind == GenerationRecoveryFileKind.receipt)
        ExpansionTile(
          title: Text(l10n.generationRecoveryDiagnostics),
          children: [
            SelectableText(
              item.file.text ?? '',
              style: AppTypography.mono(context),
            ),
          ],
        ),
      if (item.trap case final trap?) ...[
        SelectableText(
          trap.movesSan.join(' '),
          style: AppTypography.bodyStrong(context),
        ),
        _value(l10n.generationRecoveryPopularMove, trap.popularMove),
        _value(l10n.generationRecoveryBestMove, trap.bestMove),
        _value(
          l10n.generationRecoveryProbability,
          NumberFormat.percentPattern(l10n.localeName).format(trap.popularProb),
        ),
        _value(l10n.generationRecoveryGain, formatPackedEval(trap.evalDiffCp)),
        ExpansionTile(
          title: Text(l10n.generationRecoveryDiagnostics),
          children: [
            SelectableText(
              json.convert(trap.toJson()),
              style: AppTypography.mono(context),
            ),
          ],
        ),
      ],
      if (tree != null && node != null) ...[
        Text(l10n.generationRecoveryNodes(tree.totalNodes, tree.maxPlyReached)),
        ExpansionTile(
          title: Text(l10n.generationRecoveryConfig),
          children: [
            SelectableText(
              json.convert(tree.configSnapshot),
              style: AppTypography.mono(context),
            ),
          ],
        ),
        if (node.parent != null)
          TextButton.icon(
            key: const Key('generation-recovery-parent'),
            onPressed: () => setState(() => _node = node.parent),
            icon: const Icon(Icons.arrow_upward),
            label: Text(l10n.generationRecoveryParent),
          ),
        SelectableText(node.fen, style: AppTypography.mono(context)),
        _value(
          l10n.generationRecoveryEvaluation,
          node.engineEvalCp == null
              ? l10n.generationRecoveryNotSaved
              : formatPackedEval(node.engineEvalCp!),
        ),
        _value(
          l10n.generationRecoveryProbability,
          NumberFormat.percentPattern(
            l10n.localeName,
          ).format(node.moveProbability),
        ),
        _value(
          l10n.generationRecoveryExpectedScore,
          node.hasExpectimax
              ? NumberFormat.percentPattern(
                  l10n.localeName,
                ).format(node.expectimaxValue)
              : l10n.generationRecoveryNotSaved,
        ),
        if (node.enginePv.isNotEmpty)
          _value(l10n.generationRecoveryPv, node.enginePv.join(' ')),
        const Divider(),
        for (final child in node.children)
          ListTile(
            key: ValueKey('recovery-node-${child.nodeId}'),
            title: Text(child.moveSan),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _node = child),
          ),
      ],
    ];
  }
}
