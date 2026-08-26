import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/eval_database_settings.dart';
import '../../services/eval/sqlite_eval_provider.dart';
import '../../theme/app_colors.dart';
import '../labeled_toggle.dart';
import 'eval_sources_controller.dart';

/// Advanced eval-source controls for repertoire tree generation.
///
/// A pure view over [EvalSourcesController]: every value it shows and every
/// edit it makes belongs to the controller, which the form owns. The section
/// may therefore be built only while its expander is open — collapsing it
/// destroys no state.
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
      lockParentWindow: true,
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
    final localFieldsEnabled = controller.enableLocalChessDb && !isGenerating;
    final apiFieldsEnabled = controller.enableChessDbApi && !isGenerating;
    final path = controller.localChessDbPathField.text;
    final valid = controller.localChessDbFileValid;

    // No header of its own: the expander row in the form carries the title
    // and the lookup-chain info tooltip.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cdbDirectAvailable) ...[
          _cdbDirectTile(context),
          _check(
            'Batch eval lookups',
            controller.batchEvalLookups,
            (v) => controller.batchEvalLookups = v,
          ),
          const SizedBox(height: 12),
        ],
        _check(
          'Local ChessDB file',
          controller.enableLocalChessDb,
          (v) => controller.enableLocalChessDb = v,
          tooltip:
              'Use a local ChessDB SQLite slice for eval lookups.\n'
              'Positions missing from the file can trigger subtree skip.',
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
                onPressed: localFieldsEnabled ? _pickLocalChessDbFile : null,
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
        const SizedBox(height: 12),
        _check(
          'ChessDB API',
          controller.enableChessDbApi,
          (v) => controller.enableChessDbApi = v,
          tooltip:
              'Query chessdb.cn for positions not in the local cache — a fast,\n'
              'free cloud eval source, consulted before the engine. On by\n'
              'default; backs off automatically if the server rate-limits.',
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
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _check(
          'Skip external eval for off-book subtrees',
          controller.enableExtEvalSubtreeSkip,
          (v) => controller.enableExtEvalSubtreeSkip = v,
          tooltip:
              'When a position is absent from the local ChessDB file,\n'
              'skip further external lookups for that subtree and use Stockfish.',
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

  /// Read-only status of the cdb-direct full dump, which App settings owns.
  Widget _cdbDirectTile(BuildContext context) {
    final dbSettings = context.watch<EvalDatabaseSettings>();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        dbSettings.enableCdbDirect ? Icons.storage : Icons.storage_outlined,
        color: dbSettings.enableCdbDirect
            ? AppColors.evalPositive
            : AppColors.onSurfaceMuted,
      ),
      title: const Text(
        'Local ChessDB (full dump)',
        style: TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        dbSettings.enableCdbDirect && dbSettings.cdbDirectPath.isNotEmpty
            ? dbSettings.cdbDirectPath
            : 'Not set up — enable it in App settings → Evaluation database',
        style: const TextStyle(fontSize: 11),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      dense: true,
    );
  }
}
