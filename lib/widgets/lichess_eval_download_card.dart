/// Status of the Lichess cloud-evaluation store on this machine, and the
/// controls that change it: download and build it, pause or resume, free the
/// archive once the store is built, or delete the lot.
///
/// Extracted from [LichessEvalSettingsPanel] so the repertoire builder's
/// eval-sources pane can show the same card. Both mount the shared
/// [LichessEvalController], so a transfer started in one is the transfer the
/// other reports on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/eval/lichess_eval_controller.dart';
import '../services/eval/lichess_eval_source.dart';
import '../services/eval/storage_volumes.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/open_in_file_manager.dart';
import 'lichess_eval_download_dialog.dart';
import 'storage_destination_picker.dart';

class LichessEvalCard extends StatefulWidget {
  const LichessEvalCard({super.key, this.controller});

  final LichessEvalController? controller;

  @override
  State<LichessEvalCard> createState() => _LichessEvalCardState();
}

class _LichessEvalCardState extends State<LichessEvalCard> {
  LichessEvalController get _controller =>
      widget.controller ?? LichessEvalController.instance;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // Reads disk only — nothing starts downloading behind the user's back.
    unawaited(_controller.loadSaved());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startDownload() async {
    final request = await showLichessDownloadDialog(context);
    if (request == null) return;
    await _controller.prepare(info: request.info, parentDir: request.parentDir);
    unawaited(_controller.start());
  }

  Future<void> _reveal() async {
    final directory = _controller.storeDirectory;
    if (directory == null) return;
    final opened = await openInFileManager(directory);
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(directory)));
    }
  }

  Future<void> _confirmDelete({required bool everything}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          everything
              ? 'Delete the Lichess evaluations?'
              : 'Delete the download?',
        ),
        content: Text(
          everything
              ? 'Removes the built store and anything left of the download. '
                    'Getting it back means downloading '
                    '${formatBytes(_controller.info?.bytes ?? kLichessEvalFallbackBytes)} '
                    'again.'
              : 'Removes the compressed download and keeps the store the app '
                    'actually reads. Only needed again to rebuild.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (everything) {
      await _controller.deleteEverything();
    } else {
      await _controller.deleteArchive();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: switch (_controller.phase) {
        LichessEvalPhase.idle || LichessEvalPhase.probing => _idleCard(),
        LichessEvalPhase.downloading ||
        LichessEvalPhase.importing ||
        LichessEvalPhase.paused ||
        LichessEvalPhase.failed => _progressCard(),
        LichessEvalPhase.complete => _completeCard(),
      },
    );
  }

  Widget _idleCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'No Lichess evaluations on this machine yet.',
          style: AppTextStyles.bodyStrong,
        ),
        const SizedBox(height: 4),
        Text(
          '${formatCompactCount(kLichessEvalFallbackPositions)} positions '
          'analysed by Stockfish on the Lichess analysis board. '
          '${formatBytes(kLichessEvalFallbackBytes)} to download; about '
          '${formatBytes(kLichessEvalFallbackPositions * 15)} stays on disk '
          'afterwards.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: () => unawaited(_startDownload()),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download evaluations…'),
            ),
            TextButton(
              onPressed: () =>
                  unawaited(launchUrl(Uri.parse(kLichessDatabasePageUrl))),
              child: const Text('Open database.lichess.org'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _progressCard() {
    final phase = _controller.phase;
    final running =
        phase == LichessEvalPhase.downloading ||
        phase == LichessEvalPhase.importing;
    final error = _controller.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(switch (phase) {
          LichessEvalPhase.downloading => 'Downloading',
          LichessEvalPhase.importing => 'Building the store',
          LichessEvalPhase.failed => 'Stopped',
          _ => 'Paused',
        }, style: AppTextStyles.bodyStrong),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _controller.fraction.clamp(0.0, 1.0),
          minHeight: 4,
        ),
        const SizedBox(height: 8),
        Text(_progressLine(), style: AppTextStyles.caption),
        if (error != null) ...[
          const SizedBox(height: 10),
          destinationBanner(AppColors.danger, Icons.error_outline, error),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (running)
              OutlinedButton.icon(
                onPressed: () => unawaited(_controller.pause()),
                icon: const Icon(Icons.pause, size: 16),
                label: const Text('Pause'),
              )
            else
              FilledButton.icon(
                onPressed: () => unawaited(_controller.start()),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Resume'),
              ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_reveal()),
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Open folder'),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_confirmDelete(everything: true)),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete files'),
            ),
          ],
        ),
      ],
    );
  }

  String _progressLine() {
    switch (_controller.phase) {
      case LichessEvalPhase.downloading:
      case LichessEvalPhase.paused:
      case LichessEvalPhase.failed:
        final done = formatBytes(_controller.archiveBytesDone);
        final total = formatBytes(_controller.archiveBytesTotal);
        final rate = _controller.bytesPerSecond;
        final eta = _controller.eta;
        final tail = [
          if (rate > 0) '${formatBytes(rate.round())}/s',
          if (eta != null) '${formatDuration(eta)} left',
        ].join(', ');
        return '$done of $total${tail.isEmpty ? '' : ' — $tail'}';
      case LichessEvalPhase.importing:
        if (_controller.bucketsMerged > 0) {
          return 'Sorting — ${_controller.bucketsMerged} of 256 blocks. '
              'The download can be deleted once this finishes.';
        }
        return 'Read ${formatCompactCount(_controller.linesRead)} positions of '
            '${formatCompactCount(_controller.info?.positions ?? kLichessEvalFallbackPositions)}. '
            'Nothing but the store is written to disk.';
      case LichessEvalPhase.idle:
      case LichessEvalPhase.probing:
      case LichessEvalPhase.complete:
        return '';
    }
  }

  Widget _completeCard() {
    final manifest = _controller.manifest;
    final archiveOnDisk = _controller.archiveBytesDone > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${formatCompactCount(_controller.storedPositions)} positions ready',
          style: AppTextStyles.bodyStrong,
        ),
        const SizedBox(height: 4),
        Text(
          [
            formatBytes(_controller.storedPositions * 15 + 32),
            if (manifest?.builtAt != null)
              'built ${formatDestinationDate(manifest!.builtAt!)}',
            if (archiveOnDisk)
              '${formatBytes(_controller.archiveBytesDone)} download still '
                  'on disk',
          ].join(' · '),
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => unawaited(_reveal()),
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Open folder'),
            ),
            if (archiveOnDisk)
              OutlinedButton.icon(
                onPressed: () => unawaited(_confirmDelete(everything: false)),
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: Text(
                  'Free ${formatBytes(_controller.archiveBytesDone)}',
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_startDownload()),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Rebuild from a newer file…'),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_confirmDelete(everything: true)),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
            ),
          ],
        ),
      ],
    );
  }
}

/// "394.0M", "12k", "42" — position counts, which run to nine digits and are
/// never worth reading in full.
String formatCompactCount(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).round()}k';
  return '$value';
}
