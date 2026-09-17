import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../design_system/theme/app_spacing.dart';
import '../../../design_system/theme/app_typography.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/build_tree_node.dart';
import '../../../utils/chess_utils.dart' show formatPackedEval;
import '../controllers/legacy_analysis_controller.dart';
import '../models/generation_artifacts.dart';
import '../services/generation_artifacts.dart';

/// Recovery inspection is detached from the live chapter, tree and engine.
class LegacyAnalysisDialog extends StatefulWidget {
  const LegacyAnalysisDialog({
    super.key,
    required this.path,
    required this.artifacts,
    required this.chooseExportDestination,
  });
  final String path;
  final GenerationArtifacts artifacts;
  final Future<String?> Function(GenerationArtifactKind)
  chooseExportDestination;

  @override
  State<LegacyAnalysisDialog> createState() => _LegacyAnalysisDialogState();
}

class _LegacyAnalysisDialogState extends State<LegacyAnalysisDialog> {
  late final _controller = LegacyAnalysisController(widget.artifacts);
  LegacyAnalysisItem? _selected;
  BuildTreeNode? _node;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.load(widget.path));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _label(GenerationArtifactKind kind, AppLocalizations l10n) =>
      switch (kind) {
        GenerationArtifactKind.tree => l10n.legacyAnalysisTree,
        GenerationArtifactKind.probes => l10n.legacyAnalysisProbes,
        GenerationArtifactKind.traps => l10n.legacyAnalysisTraps,
        GenerationArtifactKind.partial => l10n.legacyAnalysisPartial,
      };

  void _select(LegacyAnalysisItem item) => setState(() {
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
                      ? Center(child: Text(l10n.legacyAnalysisSelect))
                      : _details(selected, l10n);
                  return PopScope(
                    canPop: !_controller.exporting,
                    child: ListView(
                      primary: false,
                      key: const Key('legacy-analysis-scroll'),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.legacyAnalysisTitle,
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
                          widget.path,
                          style: AppTypography.caption(context),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          l10n.legacyAnalysisProvenance,
                          style: AppTypography.body(context),
                        ),
                        const SizedBox(height: AppSpacing.sm),
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
                                      unawaited(_controller.load(widget.path));
                                    },
                              icon: const Icon(Icons.refresh),
                              label: Text(l10n.refresh),
                            ),
                            if (selected != null &&
                                inspection?.snapshot.originalBytes.containsKey(
                                      selected.kind,
                                    ) ==
                                    true)
                              OutlinedButton.icon(
                                key: const Key('legacy-analysis-export'),
                                onPressed: _controller.exporting
                                    ? null
                                    : () => unawaited(
                                        _controller.export(
                                          selected.kind,
                                          () => widget.chooseExportDestination(
                                            selected.kind,
                                          ),
                                        ),
                                      ),
                                icon: const Icon(Icons.save_alt),
                                label: Text(l10n.legacyAnalysisExport),
                              ),
                            if (_controller.exporting)
                              const CircularProgressIndicator(),
                          ],
                        ),
                        if (_controller.error case final error?)
                          _failure(error, l10n),
                        if (_controller.exportedPath case final path?)
                          SelectableText(l10n.legacyAnalysisExported(path)),
                        const Divider(),
                        if (_controller.loading)
                          const Center(child: CircularProgressIndicator())
                        else if (inspection == null ||
                            (inspection.items.isEmpty &&
                                inspection.snapshot.payloads.isEmpty))
                          Text(l10n.legacyAnalysisEmpty)
                        else if (stacked) ...[
                          ..._choices(inspection, l10n),
                          const Divider(),
                          if (selected != null)
                            ..._detailWidgets(selected, l10n)
                          else
                            Text(l10n.legacyAnalysisSelect),
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

  Widget _chooser(LegacyAnalysisInspection inspection, AppLocalizations l10n) =>
      ListView(
        primary: false,
        key: const Key('legacy-analysis-chooser'),
        children: _choices(inspection, l10n),
      );

  List<Widget> _choices(
    LegacyAnalysisInspection inspection,
    AppLocalizations l10n,
  ) => [
    for (final kind in GenerationArtifactKind.values)
      if (inspection.snapshot.payloads.containsKey(kind) ||
          inspection.snapshot.readFailures.containsKey(kind)) ...[
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Text(
            _label(kind, l10n),
            style: AppTypography.bodyStrong(context),
          ),
        ),
        if (!inspection.items.any((item) => item.kind == kind))
          ListTile(
            title: Text(l10n.legacyAnalysisNoEntries),
            onTap: () => _select(LegacyAnalysisItem(kind: kind)),
          ),
        for (final (index, item)
            in inspection.items.where((item) => item.kind == kind).indexed)
          ListTile(
            key: Key('legacy-${kind.name}-$index'),
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
                        l10n.legacyAnalysisEntry(index + 1),
            ),
            subtitle: item.error == null
                ? null
                : Text(l10n.legacyAnalysisUnreadable),
            onTap: () => _select(item),
          ),
      ],
  ];

  Widget _failure(Object error, AppLocalizations l10n) {
    final message = switch (error) {
      GenerationArtifactFailure(kind: GenerationArtifactFailureKind.read) =>
        l10n.legacyAnalysisReadFailed,
      GenerationArtifactFailure(kind: GenerationArtifactFailureKind.decode) =>
        l10n.legacyAnalysisDecodeFailed,
      GenerationArtifactFailure(
        kind: GenerationArtifactFailureKind.collision,
      ) =>
        l10n.legacyAnalysisCollision,
      GenerationArtifactFailure(kind: GenerationArtifactFailureKind.export) =>
        l10n.legacyAnalysisExportFailed,
      GenerationArtifactFailure(
        kind: GenerationArtifactFailureKind.uncertain,
      ) =>
        l10n.legacyAnalysisExportUncertain,
      _ => l10n.legacyAnalysisLoadFailed,
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
          SelectableText(l10n.legacyAnalysisDestination(path)),
        ExpansionTile(
          title: Text(l10n.legacyAnalysisDiagnostics),
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

  Widget _details(LegacyAnalysisItem item, AppLocalizations l10n) => ListView(
    primary: false,
    key: ValueKey(item),
    padding: const EdgeInsets.all(AppSpacing.sm),
    children: _detailWidgets(item, l10n),
  );

  List<Widget> _detailWidgets(LegacyAnalysisItem item, AppLocalizations l10n) {
    final tree = item.tree;
    final node = _node;
    const json = JsonEncoder.withIndent('  ');
    return [
      if (item.kind == GenerationArtifactKind.partial) ...[
        Text(
          l10n.legacyAnalysisResumeUnavailable,
          style: AppTypography.bodyStrong(context),
        ),
        const SizedBox(height: AppSpacing.md),
      ],
      if (item.error case final error?) _failure(error, l10n),
      if (item.trap case final trap?) ...[
        SelectableText(
          trap.movesSan.join(' '),
          style: AppTypography.bodyStrong(context),
        ),
        _value(l10n.legacyAnalysisPopularMove, trap.popularMove),
        _value(l10n.legacyAnalysisBestMove, trap.bestMove),
        _value(
          l10n.legacyAnalysisProbability,
          NumberFormat.percentPattern(l10n.localeName).format(trap.popularProb),
        ),
        _value(l10n.legacyAnalysisGain, formatPackedEval(trap.evalDiffCp)),
        ExpansionTile(
          title: Text(l10n.legacyAnalysisDiagnostics),
          children: [
            SelectableText(
              json.convert(trap.toJson()),
              style: AppTypography.mono(context),
            ),
          ],
        ),
      ],
      if (tree != null && node != null) ...[
        Text(l10n.legacyAnalysisNodes(tree.totalNodes, tree.maxPlyReached)),
        ExpansionTile(
          title: Text(l10n.legacyAnalysisConfig),
          children: [
            SelectableText(
              json.convert(tree.configSnapshot),
              style: AppTypography.mono(context),
            ),
          ],
        ),
        if (node.parent != null)
          TextButton.icon(
            key: const Key('legacy-analysis-parent'),
            onPressed: () => setState(() => _node = node.parent),
            icon: const Icon(Icons.arrow_upward),
            label: Text(l10n.legacyAnalysisParent),
          ),
        SelectableText(node.fen, style: AppTypography.mono(context)),
        _value(
          l10n.legacyAnalysisEvaluation,
          node.engineEvalCp == null
              ? l10n.legacyAnalysisNotSaved
              : formatPackedEval(node.engineEvalCp!),
        ),
        _value(
          l10n.legacyAnalysisProbability,
          NumberFormat.percentPattern(
            l10n.localeName,
          ).format(node.moveProbability),
        ),
        _value(
          l10n.legacyAnalysisExpectedScore,
          node.hasExpectimax
              ? NumberFormat.percentPattern(
                  l10n.localeName,
                ).format(node.expectimaxValue)
              : l10n.legacyAnalysisNotSaved,
        ),
        if (node.enginePv.isNotEmpty)
          _value(l10n.legacyAnalysisPv, node.enginePv.join(' ')),
        const Divider(),
        for (final child in node.children)
          ListTile(
            key: ValueKey('legacy-node-${child.nodeId}'),
            title: Text(child.moveSan),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _node = child),
          ),
      ],
    ];
  }
}
