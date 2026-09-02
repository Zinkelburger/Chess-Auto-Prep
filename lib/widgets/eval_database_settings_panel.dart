/// Offline eval configuration: download the ChessDB full dump, or point the
/// reader at a copy you already have.
///
/// Shown on Linux when the native reader is available; mounted from
/// [SettingsScreen] under the Database section. The status-and-download half
/// lives in [ChessDbDumpCard], which the repertoire builder's eval-sources
/// pane mounts as well; what stays here is the settings this screen owns.
library;

import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/eval_database_settings.dart';
import '../theme/app_colors.dart';
import '../services/eval/cdb_snapshot_catalog.dart';
import '../services/eval/cdb_snapshot_download.dart';
import '../services/eval/cdbdirect_eval_provider.dart';
import '../services/eval/cdbdirect_parse.dart';
import '../theme/app_text_styles.dart';
import '../utils/open_in_file_manager.dart';
import 'eval_database_download_card.dart';
import 'labeled_toggle.dart';

/// Command for anyone who would rather run the transfer outside the app.
String chessDbRsyncCommand(String snapshotId) =>
    'rsync -av --partial --progress '
    'rsync://ftp.chessdb.cn/ftp/pub/chessdb/$snapshotId/ /path/to/chessdb/';

class EvalDatabaseSettingsPanel extends StatefulWidget {
  const EvalDatabaseSettingsPanel({super.key});

  @override
  State<EvalDatabaseSettingsPanel> createState() =>
      _EvalDatabaseSettingsPanelState();
}

class _EvalDatabaseSettingsPanelState extends State<EvalDatabaseSettingsPanel> {
  final EvalDatabaseSettings _settings = EvalDatabaseSettings.instance;
  final CdbSnapshotDownloadController _download =
      CdbSnapshotDownloadController.instance;
  final TextEditingController _pathCtrl = TextEditingController();

  bool? _featureVisible;
  bool _libraryAvailable = false;
  String? _unavailableReason;
  CdbDirectDirValidation? _dirValidation;
  bool _setupExpanded = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _download.addListener(_onDownloadChanged);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!Platform.isLinux) {
      if (!mounted) return;
      setState(() {
        _featureVisible = true;
        _libraryAvailable = false;
        _unavailableReason =
            'The local ChessDB dump reader is only available on Linux.';
      });
      return;
    }

    final status = await CdbDirectEvalProvider.libraryStatus();
    if (!mounted) return;
    _pathCtrl.text = _settings.cdbDirectPath;
    setState(() {
      _featureVisible = status.showFeatureUi;
      _libraryAvailable = status.isAvailable;
    });
    if (_libraryAvailable && _settings.cdbDirectPath.isNotEmpty) {
      await _validatePath(_settings.cdbDirectPath);
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _download.removeListener(_onDownloadChanged);
    _pathCtrl.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (_pathCtrl.text != _settings.cdbDirectPath) {
      _pathCtrl.text = _settings.cdbDirectPath;
      unawaited(_validatePath(_settings.cdbDirectPath));
    }
    if (mounted) setState(() {});
  }

  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _validatePath(String path) async {
    if (path.trim().isEmpty) {
      if (mounted) setState(() => _dirValidation = null);
      return;
    }
    final result = await validateCdbDirectDataDirDetailed(path);
    if (!mounted) return;
    setState(() => _dirValidation = result);
  }

  Future<void> _pickDirectory() async {
    if (!_libraryAvailable) return;
    final result = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select ChessDB data directory',
    );
    if (result == null) return;
    await _settings.setCdbDirectPath(result);
    await _validatePath(result);
    if (_dirValidation?.isValid == true) {
      await _settings.setEnableCdbDirect(true);
    }
  }

  Future<void> _copyCommand(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  Future<void> _reveal(String path) async {
    final opened = await openInFileManager(path);
    if (opened || !mounted) return;
    await _copyCommand(path);
  }

  @override
  Widget build(BuildContext context) {
    if (_featureVisible != true) return const SizedBox.shrink();

    // No heading of its own: the enclosing settings card already names this
    // section, and two titles stacked read as two sections.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.info_outline, size: 16),
            label: const Text(
              'What offline evals are',
              style: AppTextStyles.caption,
            ),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
            onPressed: () => _showInfoDialog(context),
          ),
        ),
        const SizedBox(height: 4),
        if (!_libraryAvailable)
          _banner(
            AppColors.warning,
            Icons.warning_amber_rounded,
            _unavailableReason ??
                'Native library not found. Run `make setup-cdbdirect` in '
                    'tree_builder/, then launch with `./run_with_cdbdirect.sh`.',
          ),
        if (_unavailableReason == null) ...[
          const SizedBox(height: 12),
          ChessDbDumpCard(
            canDownload: _libraryAvailable,
            configured: _dirValidation?.isValid == true,
          ),
          const SizedBox(height: 16),
          AppSwitch(
            label: 'Local ChessDB (full dump)',
            value: _settings.enableCdbDirect,
            onChanged: (v) => _settings.setEnableCdbDirect(v),
            enabled: _libraryAvailable,
            tooltip:
                'Answer eval lookups from the dump on disk before trying the '
                'chessdb.cn API or the engine.',
            disabledReason: 'The native reader is not loaded.',
          ),
          const SizedBox(height: 8),
          _pathField(),
          const SizedBox(height: 8),
          AppSwitch(
            label: 'HDD read-ahead hint',
            value: _settings.cdbDirectReadAhead,
            onChanged: (v) => _settings.setCdbDirectReadAhead(v),
            enabled: _libraryAvailable && _settings.enableCdbDirect,
            tooltip:
                'Reads a larger block around each lookup — worth it on a '
                'spinning disk, wasted work on an SSD.',
            disabledReason: 'Requires Local ChessDB (full dump) to be enabled.',
          ),
          const SizedBox(height: 12),
          _manualSetupTile(),
        ],
      ],
    );
  }

  // ── Path field ────────────────────────────────────────────────────────────

  Widget _pathField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                readOnly: true,
                controller: _pathCtrl,
                decoration: InputDecoration(
                  labelText: 'ChessDB data directory',
                  hintText: 'No folder selected',
                  helperText:
                      'The folder holding CURRENT and the .sst files — '
                      '…/chess-YYYYMMDD/data',
                  helperStyle: const TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurfaceMuted,
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _buildPathStatusIcon(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _libraryAvailable ? _pickDirectory : null,
              icon: const Icon(Icons.folder_open),
              tooltip: 'Browse for the data/ folder',
            ),
            if (_pathCtrl.text.isNotEmpty)
              IconButton(
                onPressed: () => unawaited(_reveal(_pathCtrl.text)),
                icon: const Icon(Icons.open_in_new),
                tooltip: 'Show in file manager',
              ),
            if (_pathCtrl.text.isNotEmpty)
              IconButton(
                onPressed: () async {
                  await _settings.setCdbDirectPath('');
                  setState(() => _dirValidation = null);
                },
                icon: const Icon(Icons.clear),
                tooltip: 'Clear path',
              ),
          ],
        ),
        if (_dirValidation != null && !_dirValidation!.isValid) ...[
          const SizedBox(height: 4),
          Text(
            _dirValidation!.message,
            style: const TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ],
      ],
    );
  }

  Widget? _buildPathStatusIcon() {
    if (_pathCtrl.text.isEmpty || _dirValidation == null) return null;
    final valid = _dirValidation!.isValid;
    return Tooltip(
      message: _dirValidation!.message,
      child: Icon(
        valid ? Icons.check_circle : Icons.cancel,
        size: 18,
        color: valid ? AppColors.evalPositive : AppColors.danger,
      ),
    );
  }

  // ── Manual route ──────────────────────────────────────────────────────────

  Widget _manualSetupTile() {
    final snapshotId = _download.snapshot?.id ?? kChessDbFallbackSnapshotId;
    return ExpansionTile(
      initiallyExpanded: _setupExpanded,
      onExpansionChanged: (v) => setState(() => _setupExpanded = v),
      tilePadding: EdgeInsets.zero,
      title: const Text(
        'Download it yourself instead',
        style: TextStyle(fontSize: 14),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Same files, fetched outside the app — useful on a server, or '
                'over a connection you would rather manage yourself. Point the '
                'path field above at the resulting data/ folder when it ends.',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
              ),
              const SizedBox(height: 8),
              _commandRow(chessDbRsyncCommand(snapshotId)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      unawaited(launchUrl(Uri.parse(kChessDbHfDatasetUrl))),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('Hugging Face mirror'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _commandRow(String command) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'SourceCodePro', fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy command',
            onPressed: () => unawaited(_copyCommand(command)),
          ),
        ],
      ),
    );
  }

  Widget _banner(Color color, IconData icon, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  void _showInfoDialog(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Offline ChessDB'),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'chessdb.cn holds a scored evaluation for tens of billions '
                  'of positions. Online, the app queries it a position at a '
                  'time and lives inside the site\'s rate limits. The full '
                  'dump puts the same data on your disk: every lookup is a '
                  'local read, and a build that would spend hours waiting on '
                  'the API runs at disk speed.',
                ),
                SizedBox(height: 12),
                Text(
                  'It is a directory of TerarkDB .sst files — roughly 1.2 TB, '
                  'read with random 4 KB lookups. An SSD makes the difference '
                  'between instant and unusable.',
                ),
                SizedBox(height: 12),
                Text(
                  'Eval chain: local dump → SQLite slice → ChessDB API → '
                  'Stockfish.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
