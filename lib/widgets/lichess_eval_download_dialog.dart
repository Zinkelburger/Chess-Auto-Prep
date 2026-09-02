/// "Download the Lichess evaluations" — the smaller of the two eval databases.
///
/// The numbers a person needs before agreeing to this are not the ones the
/// download page shows.  The file is 21.7 GB, but it expands to roughly 283 GB
/// of JSON that is read and discarded, and what actually stays on the disk is
/// a 5.9 GB store.  While the store is being built both exist, so the drive
/// has to hold about 28 GB — and that peak, not the download size, is what
/// the drive list is measured against.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/eval/lichess_eval_controller.dart';
import '../services/eval/lichess_eval_source.dart';
import '../services/eval/storage_volumes.dart';
import '../services/eval/zstd_stream.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'storage_destination_picker.dart';

/// What the user chose.
class LichessDownloadRequest {
  const LichessDownloadRequest({required this.info, required this.parentDir});
  final LichessEvalSourceInfo info;
  final String parentDir;
}

Future<LichessDownloadRequest?> showLichessDownloadDialog(
  BuildContext context, {
  LichessEvalController? controller,
}) {
  return showDialog<LichessDownloadRequest>(
    context: context,
    builder: (_) => _LichessDownloadDialog(
      controller: controller ?? LichessEvalController.instance,
    ),
  );
}

class _LichessDownloadDialog extends StatefulWidget {
  const _LichessDownloadDialog({required this.controller});

  final LichessEvalController controller;

  @override
  State<_LichessDownloadDialog> createState() => _LichessDownloadDialogState();
}

class _LichessDownloadDialogState extends State<_LichessDownloadDialog> {
  LichessEvalSourceInfo? _info;
  bool _loading = true;
  ZstdBackend _backend = ZstdBackend.none;

  StorageDestination _destination = const StorageDestination(
    parentDir: null,
    volume: null,
    fits: true,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final info = await widget.controller.refreshSource();
    final backend = await probeZstdBackend();
    if (!mounted) return;
    setState(() {
      _info = info;
      _backend = backend;
      _loading = false;
    });
  }

  int? get _peakBytes {
    final info = _info;
    return info == null ? null : widget.controller.peakBytesFor(info);
  }

  bool get _canStart =>
      _info != null &&
      _backend != ZstdBackend.none &&
      _destination.parentDir != null &&
      _destination.fits;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Download the Lichess evaluations',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _summary(),
                    if (_backend == ZstdBackend.none) ...[
                      const SizedBox(height: 12),
                      destinationBanner(
                        AppColors.danger,
                        Icons.error_outline,
                        zstdMissingMessage,
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      'Where should it go?',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    StorageDestinationPicker(
                      requiredBytes: _peakBytes,
                      folderName: 'lichess-evals',
                      browseTitle:
                          'Choose where to keep the Lichess evaluations',
                      recommendedHeadroomBytes: 5 * 1000 * 1000 * 1000,
                      tightAdvice:
                          'The download parks itself if the drive drops '
                          'below 2 GB free.',
                      hardDiskAdvice:
                          'This is a hard disk. It will work — the store is '
                          'small and each lookup is a single read — but '
                          'building it reads and writes about 34 GB, so '
                          'expect the import to take noticeably longer.',
                      networkAdvice:
                          'This is a network share. Building the store writes '
                          'about 12 GB across it and every lookup afterwards '
                          'is a round trip; a local drive is a much better '
                          'home.',
                      onChanged: (d) => setState(() => _destination = d),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  Expanded(child: _destinationLine()),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _canStart ? _confirm : null,
                    child: Text(
                      _info == null
                          ? 'Download'
                          : 'Download ${formatBytes(_info!.bytes)}',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary() {
    if (_loading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('Asking database.lichess.org how big the file is…'),
        ],
      );
    }
    final info = _info!;
    final updated = info.updatedOn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_formatCount(info.positions)} positions — '
          '${formatBytes(info.bytes)} to download'
          '${updated == null ? '' : ', published '
                    '${formatDestinationDate(updated)}'}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'Positions analysed by Stockfish in people’s browsers on the '
          'Lichess analysis board, published under CC0. Far fewer positions '
          'than the ChessDB dump, but each one carries a deep search and a '
          'best move, and the whole thing fits in a few gigabytes.',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(height: 10),
        _costTable(info),
        if (!info.probed) ...[
          const SizedBox(height: 10),
          destinationBanner(
            AppColors.warning,
            Icons.wifi_off,
            'Could not reach database.lichess.org, so these are the sizes as '
            'of September 2026. The real size is checked again when the '
            'download starts.',
          ),
        ],
      ],
    );
  }

  /// The three numbers that actually matter, because only one of them is on
  /// the download page.
  Widget _costTable(LichessEvalSourceInfo info) {
    final rows = <(String, String)>[
      ('Download', formatBytes(info.bytes)),
      (
        'Peak while building',
        formatBytes(widget.controller.peakBytesFor(info)),
      ),
      ('Kept afterwards', formatBytes(info.storeBytes)),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
                Text(value, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 6),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'The download can be deleted once the store is built; the import '
            'reads it once and keeps four numbers per position.',
            style: AppTextStyles.caption,
          ),
        ),
      ],
    );
  }

  Widget _destinationLine() {
    final dir = _destination.parentDir;
    if (dir == null) {
      return const Text(
        'Choose a drive or folder.',
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      );
    }
    return Text(
      '$dir${Platform.pathSeparator}${LichessEvalController.folderName}',
      style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      overflow: TextOverflow.ellipsis,
    );
  }

  static String _formatCount(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)} million';
    }
    return '$value';
  }

  Future<void> _confirm() async {
    final info = _info;
    final dir = _destination.parentDir;
    if (info == null || dir == null) return;
    try {
      await Directory(dir).create(recursive: true);
    } on FileSystemException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot write to $dir: ${e.osError?.message}')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, LichessDownloadRequest(info: info, parentDir: dir));
  }
}
