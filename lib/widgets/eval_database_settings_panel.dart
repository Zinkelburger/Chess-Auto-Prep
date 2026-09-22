/// The settings half of the offline ChessDB dump: whether to consult it,
/// where it is, and how to read it.
///
/// Mounted by the Databases page inside a database card's disclosure. The
/// card above it owns the *status* half — what is on disk, and the transfer
/// controls — through [ChessDbDumpCard], which the repertoire builder's
/// eval-sources pane mounts as well. This file deliberately holds no card, no
/// banner and no title: it is the knobs, and the knobs only matter once the
/// question of whether you have a dump has been answered somewhere else.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../utils/app_messages.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/settings/controllers/eval_database_settings.dart';
import '../theme/app_colors.dart';
import '../services/eval/cdb_snapshot_catalog.dart';
import '../services/eval/cdb_snapshot_download.dart';
import '../services/eval/cdbdirect_eval_provider.dart';
import '../services/eval/cdbdirect_parse.dart';
import '../services/eval/storage_volumes.dart';
import '../theme/app_text_styles.dart';
import '../utils/open_in_file_manager.dart';
import 'labeled_toggle.dart';

/// Command for anyone who would rather run the transfer outside the app.
String chessDbRsyncCommand(String snapshotId) =>
    'rsync -av --partial --progress '
    'rsync://ftp.chessdb.cn/ftp/pub/chessdb/$snapshotId/ /path/to/chessdb/';

/// Why the local ChessDB reader cannot be used here, in the reader's terms —
/// or null when it can.
///
/// This used to read "Run `make setup-cdbdirect` in tree_builder/, then launch
/// with `./run_with_cdbdirect.sh`". That is a build instruction for this
/// checkout, and it was rendered to every user of a `.deb`, a flatpak or the
/// Windows installer — none of whom have a checkout, a `make`, or any reason
/// to open a terminal. A user-facing string may describe what is missing; it
/// may not hand out someone else's homework.
String? chessDbUnavailableReason(CdbDirectLibraryStatus status) {
  if (status.isAvailable) return null;
  if (!status.showFeatureUi) {
    return 'Reading a local ChessDB dump needs a native component that is '
        'only built for Linux. On ${status.platformName} the app uses the '
        'Lichess evaluations and the engine instead.';
  }
  return 'This build does not include the native ChessDB reader, so a dump '
      'on disk could not be read. The Lichess evaluations above need no '
      'native component and cover the same job for most repertoires.';
}

class EvalDatabaseSettingsPanel extends StatefulWidget {
  const EvalDatabaseSettingsPanel({super.key, required this.libraryAvailable});

  /// Whether the native reader loaded. The controls are visible either way —
  /// a setting you cannot reach is harder to reason about than one that is
  /// visibly off — but nothing here is interactive without it.
  final bool libraryAvailable;

  @override
  State<EvalDatabaseSettingsPanel> createState() =>
      _EvalDatabaseSettingsPanelState();
}

class _EvalDatabaseSettingsPanelState extends State<EvalDatabaseSettingsPanel> {
  late final EvalDatabaseSettings _settings;
  CdbSnapshotDownloadController get _download =>
      context.read<CdbSnapshotDownloadController>();
  final TextEditingController _pathCtrl = TextEditingController();

  CdbDirectDirValidation? _dirValidation;
  StorageMedia? _pathMedia;
  bool _setupExpanded = false;

  @override
  void initState() {
    super.initState();
    _settings = context.read<EvalDatabaseSettings>();
    _settings.addListener(_onSettingsChanged);
    _pathCtrl.text = _settings.editing.cdbDirectPath;
    if (widget.libraryAvailable && _settings.editing.cdbDirectPath.isNotEmpty) {
      unawaited(_validatePath(_settings.editing.cdbDirectPath));
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _pathCtrl.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (_pathCtrl.text != _settings.editing.cdbDirectPath) {
      _pathCtrl.text = _settings.editing.cdbDirectPath;
      unawaited(_validatePath(_settings.editing.cdbDirectPath));
    }
    if (mounted) setState(() {});
  }

  Future<void> _validatePath(String path) async {
    if (path.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _dirValidation = null;
          _pathMedia = null;
        });
      }
      return;
    }
    final result = await validateCdbDirectDataDirDetailed(path);
    final volume = await volumeForPath(path);
    if (!mounted || path != _settings.editing.cdbDirectPath) return;
    setState(() {
      _dirValidation = result;
      _pathMedia = volume?.media;
    });
  }

  Future<void> _pickDirectory() async {
    if (!mounted || !widget.libraryAvailable) return;
    final download = _download;
    final result = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select ChessDB data directory',
    );
    if (!mounted || result == null || !identical(download, _download)) return;
    try {
      await download.activateDirectory(result);
    } catch (error) {
      if (mounted) showAppSnackBar(context, '$error', isError: true);
    }
  }

  Future<void> _copyCommand(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _reveal(String path) async {
    final opened = await openInFileManager(path);
    if (opened || !mounted) return;
    await _copyCommand(path);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<CdbSnapshotDownloadController>();
    if (_settings.state.committed == null) return const SizedBox.shrink();
    final available =
        widget.libraryAvailable &&
        !_settings.state.busy &&
        !_download.isRunning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSwitch(
          label: 'Use offline ChessDB',
          value: _settings.editing.enableCdbDirect,
          onChanged: (v) {
            if (!mounted) return;
            unawaited(
              _settings.setEnableCdbDirect(v).catchError((Object _) {}),
            );
          },
          enabled: available,
          tooltip:
              'Answer eval lookups from the dump on disk before trying the '
              'chessdb.cn API or the engine.',
          disabledReason: 'The native ChessDB reader is not loaded.',
        ),
        const SizedBox(height: 8),
        _pathField(available),
        const SizedBox(height: 8),
        _readAheadSwitch(available),
        const SizedBox(height: 12),
        _manualSetupTile(),
      ],
    );
  }

  // ── Read-ahead ────────────────────────────────────────────────────────────

  /// The switch, plus what we already know about the drive it applies to.
  ///
  /// "HDD read-ahead hint" asked the reader a question the app can answer
  /// itself: [volumeForPath] reports the media, so the advice line says which
  /// way to set it instead of leaving a piece of storage trivia on screen for
  /// someone to look up. It stays a switch rather than becoming automatic
  /// because the detection is a heuristic over `/sys/block`, and being wrong
  /// about it silently is worse than being overridable.
  Widget _readAheadSwitch(bool available) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSwitch(
          label: 'Read in larger blocks',
          value: _settings.editing.cdbDirectReadAhead,
          onChanged: (v) {
            if (!mounted) return;
            unawaited(
              _settings.setCdbDirectReadAhead(v).catchError((Object _) {}),
            );
          },
          enabled: available && _settings.editing.enableCdbDirect,
          tooltip:
              'Reads a larger block around each lookup — worth it on a '
              'spinning disk, wasted work on an SSD.',
          disabledReason: 'Turn on offline ChessDB first.',
        ),
        if (_mediaAdvice != null) ...[
          const SizedBox(height: 2),
          Text(_mediaAdvice!, style: AppTextStyles.caption),
        ],
      ],
    );
  }

  String? get _mediaAdvice => switch (_pathMedia) {
    StorageMedia.ssd =>
      'That folder is on an SSD — leave this off; it only adds work.',
    StorageMedia.hardDisk =>
      'That folder is on a spinning disk — turn this on.',
    StorageMedia.network =>
      'That folder is on a network share. Random 4 kB reads over a network '
          'make the dump slower than the engine it replaces.',
    _ => null,
  };

  // ── Path field ────────────────────────────────────────────────────────────

  Widget _pathField(bool available) {
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
                  helperStyle: AppTextStyles.caption,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _buildPathStatusIcon(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: available
                  ? 'Browse for the data/ folder'
                  : 'The native ChessDB reader is not loaded, so a dump here '
                        'could not be read.',
              child: IconButton(
                onPressed: available ? _pickDirectory : null,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            if (_pathCtrl.text.isNotEmpty)
              IconButton(
                onPressed: () => unawaited(_reveal(_pathCtrl.text)),
                icon: const Icon(Icons.open_in_new),
                tooltip: 'Show in file manager',
              ),
            if (_pathCtrl.text.isNotEmpty)
              IconButton(
                onPressed: available
                    ? () {
                        if (!mounted) return;
                        unawaited(
                          _settings.clearCdbSelection().catchError(
                            (Object _) {},
                          ),
                        );
                      }
                    : null,
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
      onExpansionChanged: (v) {
        if (mounted) setState(() => _setupExpanded = v);
      },
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
                style: AppTextStyles.caption,
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
              style: const TextStyle(
                fontFamily: AppTextStyles.monoFamily,
                fontSize: 12,
              ),
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
}

/// What the offline ChessDB dump is and where it sits in the eval chain.
///
/// Reached from the Databases page's ⋮ menu rather than a text button beside
/// the title: it is background, and background that is always on screen is
/// what pushed the actual controls below the fold on the page this replaced.
void showOfflineChessDbInfo(BuildContext context) {
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
