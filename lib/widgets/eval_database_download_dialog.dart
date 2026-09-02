/// "Download the evaluation database" — pick a drive, see what it costs.
///
/// The dump is over a terabyte, so the dialog answers the three questions
/// that decide whether the download is a good idea on this machine: how big
/// is it, which drives have room, and are those drives fast enough to read it
/// afterwards.  The last two are [StorageDestinationPicker]'s job, shared with
/// the Lichess download; what is specific here is the snapshot.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/eval/cdb_snapshot_catalog.dart';
import '../services/eval/cdb_snapshot_download.dart';
import '../services/eval/storage_volumes.dart';
import '../theme/app_colors.dart';
import 'storage_destination_picker.dart';

/// What the user chose: which snapshot, and the folder to put it in.
class CdbDownloadRequest {
  const CdbDownloadRequest({required this.snapshot, required this.parentDir});
  final CdbSnapshot snapshot;
  final String parentDir;
}

Future<CdbDownloadRequest?> showCdbDownloadDialog(BuildContext context) {
  return showDialog<CdbDownloadRequest>(
    context: context,
    builder: (_) => const _CdbDownloadDialog(),
  );
}

class _CdbDownloadDialog extends StatefulWidget {
  const _CdbDownloadDialog();

  @override
  State<_CdbDownloadDialog> createState() => _CdbDownloadDialogState();
}

class _CdbDownloadDialogState extends State<_CdbDownloadDialog> {
  final CdbSnapshotCatalog _catalog = CdbSnapshotCatalog();

  CdbSnapshot? _snapshot;
  String? _catalogError;
  bool _loadingSnapshot = true;

  StorageDestination _destination = const StorageDestination(
    parentDir: null,
    volume: null,
    fits: true,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_loadSnapshot());
  }

  @override
  void dispose() {
    _catalog.dispose();
    super.dispose();
  }

  Future<void> _loadSnapshot() async {
    try {
      final snap = await _catalog.fetchLatest();
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _loadingSnapshot = false;
      });
    } on CdbCatalogException catch (e) {
      if (!mounted) return;
      setState(() {
        _catalogError = e.message;
        _loadingSnapshot = false;
      });
    }
  }

  bool get _canStart =>
      _snapshot != null && _destination.parentDir != null && _destination.fits;

  @override
  Widget build(BuildContext context) {
    final snap = _snapshot;
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
                'Download the evaluation database',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _snapshotSummary(snap),
                    const SizedBox(height: 16),
                    const Text(
                      'Where should it go?',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    StorageDestinationPicker(
                      requiredBytes: snap?.totalBytes,
                      folderName: 'chessdb',
                      browseTitle: 'Choose where to keep the ChessDB dump',
                      recommendedHeadroomBytes: kCdbRecommendedHeadroomBytes,
                      tightAdvice:
                          'The download parks itself if the drive drops '
                          'below 2 GB free.',
                      hardDiskAdvice:
                          'This is a hard disk. Lookups are random 4 KB '
                          'reads, so an SSD is perhaps a hundred times faster '
                          'here. It still works — turn on the HDD read-ahead '
                          'hint in settings afterwards.',
                      networkAdvice:
                          'This is a network share. Every eval lookup becomes '
                          'a round trip; a local drive is the only sensible '
                          'home for the dump.',
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
                      snap == null
                          ? 'Download'
                          : 'Download ${formatBytes(snap.totalBytes)}',
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

  Widget _snapshotSummary(CdbSnapshot? snap) {
    if (_loadingSnapshot) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('Reading the published snapshot list…'),
        ],
      );
    }
    if (snap == null) {
      return destinationBanner(
        AppColors.danger,
        Icons.error_outline,
        _catalogError ?? 'Could not read the snapshot list.',
        action: TextButton(
          onPressed: () {
            setState(() {
              _loadingSnapshot = true;
              _catalogError = null;
            });
            unawaited(_loadSnapshot());
          },
          child: const Text('Retry'),
        ),
      );
    }

    final date = snap.date;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${snap.id} — ${formatBytes(snap.totalBytes)} in '
          '${snap.files.length} files'
          '${date == null ? '' : ', published ${formatDestinationDate(date)}'}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'Every position chessdb.cn has scored, read straight off your disk: '
          'no per-query limits, no network, and the generator stops waiting on '
          'the API. The transfer takes hours — it pauses and resumes, and '
          'finished files are never fetched twice.',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
        ),
      ],
    );
  }

  Widget _destinationLine() {
    final dir = _destination.parentDir;
    final snap = _snapshot;
    if (dir == null) {
      return const Text(
        'Choose a drive or folder.',
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      );
    }
    return Text(
      snap == null ? dir : p.join(dir, snap.id),
      style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      overflow: TextOverflow.ellipsis,
    );
  }

  Future<void> _confirm() async {
    final snap = _snapshot;
    final dir = _destination.parentDir;
    if (snap == null || dir == null) return;

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
    Navigator.pop(context, CdbDownloadRequest(snapshot: snap, parentDir: dir));
  }
}
