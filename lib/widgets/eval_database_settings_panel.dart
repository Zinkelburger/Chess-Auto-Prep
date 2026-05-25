/// Database download / offline eval configuration (ChessDB full dump).
///
/// Shown on Linux (always visible; native reader required to enable).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/eval_database_settings.dart';
import '../services/eval/cdbdirect_eval_provider.dart';
import '../services/eval/cdbdirect_parse.dart';

/// ChessDB full-dump download command (rsync from chessdb.cn FTP mirror).
const kChessDbRsyncCommand =
    'rsync -av rsync://ftp.chessdb.cn/ftp/pub/chessdb/chess-20251115/ /path/to/chessdb/';

const _huggingFaceDatasetUrl =
    'https://huggingface.co/datasets/robertnurnberg/chessdbcn';

class EvalDatabaseSettingsPanel extends StatefulWidget {
  const EvalDatabaseSettingsPanel({super.key});

  @override
  State<EvalDatabaseSettingsPanel> createState() =>
      _EvalDatabaseSettingsPanelState();
}

class _EvalDatabaseSettingsPanelState extends State<EvalDatabaseSettingsPanel> {
  final EvalDatabaseSettings _settings = EvalDatabaseSettings.instance;
  final TextEditingController _pathCtrl = TextEditingController();

  bool? _featureVisible;
  bool _libraryAvailable = false;
  CdbDirectDirValidation? _dirValidation;
  bool _setupExpanded = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (!Platform.isLinux) {
      if (!mounted) return;
      setState(() => _featureVisible = false);
      return;
    }

    final status = await CdbDirectEvalProvider.libraryStatus();
    await _settings.load();
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
    _pathCtrl.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (_pathCtrl.text != _settings.cdbDirectPath) {
      _pathCtrl.text = _settings.cdbDirectPath;
    }
    if (mounted) setState(() {});
  }

  Future<void> _validatePath(String path) async {
    final result = await validateCdbDirectDataDirDetailed(path);
    if (!mounted) return;
    setState(() => _dirValidation = result);
  }

  Future<void> _pickDirectory() async {
    if (!_libraryAvailable) return;
    final result = await FilePicker.platform.getDirectoryPath(
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_featureVisible != true) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Database Downloads',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.info_outline, size: 18),
              tooltip: 'About offline ChessDB evals',
              onPressed: () => _showInfoDialog(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Download once, point at the data/ folder, and evals use local data '
          'first — then API, then Stockfish.',
          style: TextStyle(fontSize: 12, color: Colors.grey[400]),
        ),
        if (!_libraryAvailable) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: Colors.amber[300]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Native library not found. Run `make setup-cdbdirect` in '
                    'tree_builder/, then launch with `./run_with_cdbdirect.sh`.',
                    style: TextStyle(fontSize: 12, color: Colors.amber[100]),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),

        ExpansionTile(
          initiallyExpanded: _setupExpanded,
          onExpansionChanged: (v) => setState(() => _setupExpanded = v),
          title: const Text('Setup Guide', style: TextStyle(fontSize: 14)),
          children: [
            _setupStep(
              '1',
              'Download (~1 TB, takes hours)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'rsync (resumable):',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  _commandRow(kChessDbRsyncCommand),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Or Hugging Face:', style: TextStyle(fontSize: 12)),
                      TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse(_huggingFaceDatasetUrl)),
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('robertnurnberg/chessdbcn'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _setupStep(
              '2',
              'Point the field below at the data/ directory',
              child: Text(
                'Select the folder that contains CURRENT and .sst files — '
                'often …/chess-20251115/data after download.',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
            ),
            _setupStep(
              '3',
              'Done',
              child: Text(
                'Enable local ChessDB and run repertoire generation. Eval chain: '
                'local dump → SQLite slice → ChessDB API → Stockfish.',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            Switch(
              value: _settings.enableCdbDirect,
              onChanged: _libraryAvailable
                  ? (v) => _settings.setEnableCdbDirect(v)
                  : null,
            ),
            const Expanded(
              child: Text(
                'Local ChessDB (full dump)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
            Tooltip(
              message: 'Download the ChessDB database (~1TB) to use offline '
                  'evals for 50+ billion positions.\n\n'
                  'Run:\n$kChessDbRsyncCommand',
              child: IconButton(
                icon: const Icon(Icons.download_outlined, size: 18),
                onPressed: () => _copyCommand(kChessDbRsyncCommand),
                tooltip: 'Copy download command',
              ),
            ),
          ],
        ),

        Text(
          'Point this at the data/ directory containing .sst files',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                readOnly: true,
                controller: _pathCtrl,
                decoration: InputDecoration(
                  labelText: 'ChessDB data directory',
                  hintText: '/path/to/chessdb/chess-20251115/data',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _buildPathStatusIcon(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Browse for data/ folder',
              child: IconButton(
                onPressed: _libraryAvailable ? _pickDirectory : null,
                icon: const Icon(Icons.folder_open),
              ),
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
            style: TextStyle(fontSize: 11, color: Colors.red[300]),
          ),
        ],

        const SizedBox(height: 8),
        FilterChip(
          label: const Text('HDD read-ahead hint'),
          selected: _settings.cdbDirectReadAhead,
          onSelected: _libraryAvailable && _settings.enableCdbDirect
              ? (v) => _settings.setCdbDirectReadAhead(v)
              : null,
        ),
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
        color: valid ? Colors.green[400] : Colors.red[400],
      ),
    );
  }

  Widget _setupStep(String number, String title, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text(number, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                child,
              ],
            ),
          ),
        ],
      ),
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
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy command',
            onPressed: () => _copyCommand(command),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Offline ChessDB'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The ChessDB dump is ~1 TB of TerarkDB .sst files on disk. '
                'No cloud setup — just files and a native reader bundled with '
                'the app.',
              ),
              const SizedBox(height: 12),
              const Text('Download:', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _commandRow(kChessDbRsyncCommand),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(_huggingFaceDatasetUrl)),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Hugging Face mirror'),
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
    );
  }
}
