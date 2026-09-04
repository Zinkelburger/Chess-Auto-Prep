import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/eval_database_settings.dart';
import '../../services/eval/lichess_eval_controller.dart';
import '../../services/eval/sqlite_eval_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../eval_database_download_card.dart';
import '../labeled_toggle.dart';
import '../lichess_eval_download_card.dart';
import 'eval_sources_controller.dart';

/// Eval-source controls for repertoire tree generation: the four databases a
/// build may consult before it falls through to Stockfish, each with what is
/// on this machine and how to get it.
///
/// The sources are laid out in the order [resolveEvalChain] asks them, and
/// numbered, because that order is the whole behaviour: a hit at step 1 means
/// steps 2–4 and the engine are never asked, and a *hard miss* at 1 or 2 can
/// switch the rest of that subtree off external lookups entirely.
///
/// A pure view over [EvalSourcesController] for the per-build knobs — the
/// section may be built only while its expander is open, so nothing editable
/// may live in its [State]. The two big local databases are the exception:
/// they are machine-wide facts owned by [EvalDatabaseSettings] and their
/// shared download controllers, not settings one build can dictate, so the
/// cards read and write those directly and every build on this machine sees
/// the same answer.
class EvalSourcesSection extends StatelessWidget {
  final EvalSourcesController controller;
  final bool isGenerating;
  final bool cdbDirectAvailable;

  const EvalSourcesSection({
    super.key,
    required this.controller,
    required this.isGenerating,
    required this.cdbDirectAvailable,
  });

  Future<void> _pickLocalChessDbFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Select ChessDB SQLite file',
      type: FileType.custom,
      allowedExtensions: ['db'],
      windowsOptions: const WindowsOptions(lockParentWindow: true),
      linuxOptions: const LinuxOptions(lockParentWindow: true),
    );
    final path = file?.path;
    if (path == null) return;
    controller.setLocalChessDbFile(
      path,
      valid: await validateChessDbEvalFile(path),
    );
  }

  Widget _numField(
    TextEditingController field,
    String label, {
    String? tooltip,
    bool enabled = true,
  }) {
    final input = SizedBox(
      width: 210,
      child: TextField(
        controller: field,
        enabled: enabled && !isGenerating,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    if (tooltip == null) return input;
    return Tooltip(message: tooltip, child: input);
  }

  /// [AppCheckbox] with the isGenerating lock folded in — these are all
  /// options applied when a build starts, hence checkboxes.
  Widget _check(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? tooltip,
  }) {
    return AppCheckbox(
      label: label,
      value: value,
      onChanged: onChanged,
      tooltip: tooltip,
      enabled: !isGenerating,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    // No header of its own: the expander row in the form carries the title
    // and the lookup-chain info tooltip.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Each source is asked in turn; the first hit wins and Stockfish '
          'only runs when they all miss.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 14),
        _chessDbDumpSource(context),
        _sqliteSliceSource(),
        _lichessSource(context),
        _chessDbApiSource(),
        const Divider(height: 28),
        _check(
          'Skip external eval for off-book subtrees',
          controller.enableExtEvalSubtreeSkip,
          (v) => controller.enableExtEvalSubtreeSkip = v,
          tooltip:
              'When a position is absent from a local ChessDB source,\n'
              'skip further external lookups for that subtree and use '
              'Stockfish.\nA Lichess miss never triggers this — that store is '
              'small enough\nthat missing a position says nothing about the '
              'subtree.',
        ),
        const SizedBox(height: 8),
        _numField(
          controller.minEvalDepthField,
          'Min eval depth (0 = engine depth)',
          tooltip:
              'Minimum search depth required from external sources.\n'
              'Shallower hits fall through to the next source.',
          enabled: !isGenerating,
        ),
      ],
    );
  }

  // ── Source 1: the ChessDB full dump ──────────────────────────────────────

  Widget _chessDbDumpSource(BuildContext context) {
    final databases = context.watch<EvalDatabaseSettings>();
    final configured =
        databases.enableCdbDirect && databases.cdbDirectPath.isNotEmpty;

    if (!cdbDirectAvailable) {
      // The native reader is not loaded, so nothing here can be acted on —
      // one line saying where it went, rather than a card of dead controls.
      return _sourceBlock(
        index: 1,
        title: 'Local ChessDB dump (chessdb.cn)',
        blurb:
            'Tens of billions of scored positions on your own disk. The '
            'reader is Linux-only and is not loaded on this machine, so this '
            'source is unavailable.',
        used: false,
        children: const [],
      );
    }

    return _sourceBlock(
      index: 1,
      title: 'Local ChessDB dump (chessdb.cn)',
      blurb:
          'Tens of billions of scored positions on your own disk — the '
          'broadest source there is, and every lookup is a local read.',
      used: configured,
      children: [
        ChessDbDumpCard(canDownload: true, configured: configured),
        const SizedBox(height: 10),
        AppSwitch(
          label: 'Use during builds',
          value: databases.enableCdbDirect,
          onChanged: (v) => unawaited(databases.setEnableCdbDirect(v)),
          enabled: databases.cdbDirectPath.isNotEmpty && !isGenerating,
          tooltip: 'Machine-wide, shared with the Databases page.',
          disabledReason: databases.cdbDirectPath.isEmpty
              ? 'No dump on this machine yet.'
              : 'A build is running.',
        ),
        if (databases.cdbDirectPath.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              databases.cdbDirectPath,
              style: AppTextStyles.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  // ── Source 2: a hand-picked SQLite slice ─────────────────────────────────

  Widget _sqliteSliceSource() {
    final localFieldsEnabled = controller.enableLocalChessDb && !isGenerating;
    final path = controller.localChessDbPathField.text;
    final valid = controller.localChessDbFileValid;

    return _sourceBlock(
      index: 2,
      title: 'ChessDB slice (.db file)',
      blurb:
          'A SQLite export covering one opening or one machine\'s cache — '
          'much smaller than the dump, and it works on any platform.',
      used: controller.enableLocalChessDb && path.isNotEmpty,
      children: [
        _check(
          'Use during builds',
          controller.enableLocalChessDb,
          (v) => controller.enableLocalChessDb = v,
          tooltip:
              'Positions missing from the file can trigger subtree skip, so '
              'point\nthis at a file that actually covers what you are '
              'building.',
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                readOnly: true,
                enabled: !isGenerating,
                controller: controller.localChessDbPathField,
                decoration: InputDecoration(
                  labelText: 'Database path (.db)',
                  hintText: 'No file selected',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: path.isEmpty || valid == null
                      ? null
                      : _pathStatusIcon(valid),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Browse for a ChessDB .db file',
              child: IconButton(
                onPressed: localFieldsEnabled
                    ? () => unawaited(_pickLocalChessDbFile())
                    : null,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            if (path.isNotEmpty)
              Tooltip(
                message: 'Clear path',
                child: IconButton(
                  onPressed: isGenerating
                      ? null
                      : controller.clearLocalChessDbFile,
                  icon: const Icon(Icons.clear),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── Source 3: the Lichess cloud evaluations ──────────────────────────────

  Widget _lichessSource(BuildContext context) {
    final databases = context.watch<EvalDatabaseSettings>();
    final lichess = LichessEvalController.instance;

    return ListenableBuilder(
      listenable: lichess,
      builder: (context, _) => _sourceBlock(
        index: 3,
        title: 'Lichess cloud evaluations',
        blurb:
            'Every position anyone has run through the Lichess analysis '
            'board — far narrower than ChessDB, but deep where it hits, and '
            'it needs no native reader.',
        used: databases.enableLichessEvals && lichess.isReady,
        children: [
          const LichessEvalCard(),
          const SizedBox(height: 10),
          AppSwitch(
            label: 'Use during builds',
            value: databases.enableLichessEvals,
            onChanged: (v) => unawaited(databases.setEnableLichessEvals(v)),
            enabled: lichess.isReady && !isGenerating,
            tooltip: 'Machine-wide, shared with the Databases page.',
            disabledReason: lichess.isReady
                ? 'A build is running.'
                : 'No built store on this machine yet.',
          ),
          if (databases.lichessEvalsPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                databases.lichessEvalsPath,
                style: AppTextStyles.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  // ── Source 4: the chessdb.cn API ─────────────────────────────────────────

  Widget _chessDbApiSource() {
    final apiFieldsEnabled = controller.enableChessDbApi && !isGenerating;
    return _sourceBlock(
      index: 4,
      title: 'ChessDB API (chessdb.cn)',
      blurb:
          'The same database over the network — nothing to download, but one '
          'request per position and a daily ceiling.',
      used: controller.enableChessDbApi,
      last: true,
      children: [
        _check(
          'Use during builds',
          controller.enableChessDbApi,
          (v) => controller.enableChessDbApi = v,
          tooltip:
              'On by default; backs off automatically if the server '
              'rate-limits.',
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _numField(
              controller.dailyQuotaField,
              'Daily quota',
              tooltip: 'Maximum ChessDB API requests per day (1–50000)',
              enabled: apiFieldsEnabled,
            ),
            _numField(
              controller.concurrencyField,
              'Concurrency',
              tooltip: 'Parallel ChessDB API requests during build (1–16)',
              enabled: apiFieldsEnabled,
            ),
            Text(
              '${controller.apiUsedToday} / ${controller.apiQuotaLimit} '
              'requests used today',
              style: AppTextStyles.caption,
            ),
          ],
        ),
      ],
    );
  }

  // ── Shared chrome ────────────────────────────────────────────────────────

  /// One numbered step of the lookup chain.
  ///
  /// [used] drives the only colour in the pane: whether this source will
  /// actually be consulted by the next build. Everything else is ink.
  Widget _sourceBlock({
    required int index,
    required String title,
    required String blurb,
    required bool used,
    required List<Widget> children,
    bool last = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: used
                  ? AppColors.evalPositive.withValues(alpha: 0.15)
                  : AppColors.surfaceContainer,
              border: Border.all(
                color: used ? AppColors.evalPositive : AppColors.divider,
              ),
            ),
            child: Text(
              '$index',
              style: AppTextStyles.caption.copyWith(
                color: used ? AppColors.evalPositive : AppColors.onSurfaceMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.bodyStrong),
                const SizedBox(height: 2),
                Text(blurb, style: AppTextStyles.caption),
                if (children.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...children,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pathStatusIcon(bool valid) {
    return Tooltip(
      message: valid
          ? 'Valid ChessDB database'
          : 'Not a valid ChessDB eval database (missing chessdb_evals table)',
      child: Icon(
        valid ? Icons.check_circle : Icons.warning_amber,
        size: 18,
        color: valid ? AppColors.evalPositive : AppColors.danger,
      ),
    );
  }
}
