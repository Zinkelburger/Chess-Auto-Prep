/// Status of the ChessDB full dump on this machine, and the controls that
/// change it: start a transfer, pause or resume one, verify or delete what
/// was fetched.
///
/// Extracted from [EvalDatabaseSettingsPanel] so the repertoire builder's
/// eval-sources pane can show the same card. Both mount the shared
/// [CdbSnapshotDownloadController], so a transfer started in one is the
/// transfer the other reports on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/eval/cdb_snapshot_catalog.dart';
import '../services/eval/cdb_snapshot_download.dart';
import '../services/eval/storage_volumes.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/open_in_file_manager.dart';
import 'eval_database_download_dialog.dart';
import 'storage_destination_picker.dart';

/// Rough size quoted before the exact manifest is fetched. The download
/// dialog reads the real figure from the published snapshot.
const int kChessDbApproximateBytes = 1200 * 1000 * 1000 * 1000;

class ChessDbDumpCard extends StatefulWidget {
  const ChessDbDumpCard({
    super.key,
    required this.canDownload,
    required this.configured,
    this.controller,
  });

  /// Whether a transfer may be started — false when the native reader that
  /// would read the result is not loaded, since the download is 1.2 TB of
  /// files nothing on this machine can open.
  final bool canDownload;

  /// Whether a valid dump is already pointed at, which only changes the copy
  /// on the idle card.
  final bool configured;

  final CdbSnapshotDownloadController? controller;

  @override
  State<ChessDbDumpCard> createState() => _ChessDbDumpCardState();
}

class _ChessDbDumpCardState extends State<ChessDbDumpCard> {
  CdbSnapshotDownloadController get _download =>
      widget.controller ?? CdbSnapshotDownloadController.instance;

  @override
  void initState() {
    super.initState();
    _download.addListener(_onChanged);
    // Re-attach to a transfer parked by an earlier run. Reads disk only —
    // nothing starts downloading behind the user's back.
    unawaited(_download.loadSaved());
  }

  @override
  void dispose() {
    _download.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startDownload() async {
    final request = await showCdbDownloadDialog(context);
    if (request == null) return;
    await _download.prepare(
      snapshot: request.snapshot,
      parentDir: request.parentDir,
    );
    await _download.start();
  }

  Future<void> _reveal(String path) async {
    final opened = await openInFileManager(path);
    if (opened || !mounted) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  Future<void> _confirmDelete() async {
    final snapshot = _download.snapshot;
    if (snapshot == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete downloaded files?'),
        content: Text(
          'Removes ${formatBytes(_download.bytesDone)} already fetched for '
          '${snapshot.id}. Downloading again starts from nothing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _download.deleteFiles();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _download.snapshot;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: switch (_download.phase) {
        CdbDownloadPhase.idle => _idleCard(),
        CdbDownloadPhase.preparing => const Text(
          'Checking what is already on disk…',
          style: AppTextStyles.muted,
        ),
        CdbDownloadPhase.downloading ||
        CdbDownloadPhase.paused ||
        CdbDownloadPhase.failed ||
        CdbDownloadPhase.checking => _progressCard(snapshot),
        CdbDownloadPhase.complete => _completeCard(snapshot),
      },
    );
  }

  Widget _idleCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.configured
              ? 'A dump is already configured.'
              : 'No dump on this machine yet.',
          style: AppTextStyles.bodyStrong,
        ),
        const SizedBox(height: 4),
        Text(
          'The full ChessDB snapshot is about '
          '${formatBytes(kChessDbApproximateBytes)} and takes hours to fetch. '
          'It pauses and resumes, and it wants an SSD.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: widget.canDownload
              ? () => unawaited(_startDownload())
              : null,
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(
            widget.configured
                ? 'Download a newer snapshot…'
                : 'Download database…',
          ),
        ),
      ],
    );
  }

  Widget _progressCard(CdbSnapshot? snapshot) {
    final phase = _download.phase;
    final running = phase == CdbDownloadPhase.downloading;
    final rate = _download.bytesPerSecond;
    final eta = _download.eta;

    final detail = StringBuffer()
      ..write(formatBytes(_download.bytesDone))
      ..write(' of ')
      ..write(formatBytes(_download.bytesTotal))
      ..write(' — ${_download.filesDone}/${_download.filesTotal} files');
    if (running && rate > 0) {
      detail.write(' — ${formatBytes(rate.round())}/s');
      if (eta != null) detail.write(', ${formatDuration(eta)} left');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(switch (phase) {
          CdbDownloadPhase.downloading => 'Downloading ${snapshot?.id ?? ''}',
          CdbDownloadPhase.checking => 'Checking files…',
          CdbDownloadPhase.failed => 'Download stopped',
          _ => 'Download paused',
        }, style: AppTextStyles.bodyStrong),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: _download.fraction,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Text(detail.toString(), style: AppTextStyles.caption),
        if (_download.error != null) ...[
          const SizedBox(height: 8),
          destinationBanner(
            AppColors.danger,
            Icons.error_outline,
            _download.error!,
          ),
        ],
        if (_download.problems.isNotEmpty) ...[
          const SizedBox(height: 8),
          destinationBanner(
            AppColors.warning,
            Icons.rule,
            '${_download.problems.length} files do not match the manifest. '
            'Resuming re-fetches them.',
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (running)
              OutlinedButton.icon(
                onPressed: () => unawaited(_download.pause()),
                icon: const Icon(Icons.pause, size: 16),
                label: const Text('Pause'),
              )
            else
              FilledButton.icon(
                onPressed: () => unawaited(_download.start()),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Resume'),
              ),
            TextButton(
              onPressed: running ? null : () => unawaited(_download.check()),
              child: const Text('Check files'),
            ),
            if (_download.parentDir != null)
              TextButton.icon(
                onPressed: () => unawaited(_reveal(_download.parentDir!)),
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Open folder'),
              ),
            TextButton(
              onPressed: running ? null : () => unawaited(_confirmDelete()),
              child: const Text('Delete files'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _completeCard(CdbSnapshot? snapshot) {
    final dir = _download.dataDirectory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${snapshot?.id ?? 'Snapshot'} downloaded — '
          '${formatBytes(_download.bytesTotal)}',
          style: AppTextStyles.bodyStrong,
        ),
        if (dir != null) ...[
          const SizedBox(height: 4),
          Text(dir, style: AppTextStyles.caption),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (dir != null)
              OutlinedButton.icon(
                onPressed: () => unawaited(_reveal(dir)),
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Open folder'),
              ),
            TextButton(
              onPressed: () => unawaited(_download.check()),
              child: const Text('Check files'),
            ),
            TextButton(
              onPressed: () => unawaited(_confirmDelete()),
              child: const Text('Delete files'),
            ),
          ],
        ),
      ],
    );
  }
}
