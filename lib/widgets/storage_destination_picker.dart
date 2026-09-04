/// "Where should this go?" — the drive list shared by the database downloads.
///
/// Both evaluation databases are large enough that picking a destination is a
/// real decision rather than a file dialog: the ChessDB dump is over a
/// terabyte and the Lichess store needs about 28 GB while it is being built.
/// So the picker answers the same three questions for either of them — which
/// drives have room, are they fast enough to read afterwards, and what is left
/// over — and hands the host back a folder.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/eval/storage_volumes.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// What the picker currently points at.
class StorageDestination {
  const StorageDestination({
    required this.parentDir,
    required this.volume,
    required this.fits,
  });

  /// Folder the download should be written under, or null when nothing is
  /// chosen yet.
  final String? parentDir;

  /// The drive it lives on, when that could be determined.
  final StorageVolume? volume;

  /// False only when a drive was measured and is too small.
  final bool fits;

  bool get isUsable => parentDir != null && fits;
}

class StorageDestinationPicker extends StatefulWidget {
  const StorageDestinationPicker({
    super.key,
    required this.requiredBytes,
    required this.folderName,
    required this.browseTitle,
    required this.onChanged,
    this.recommendedHeadroomBytes = 20 * 1000 * 1000 * 1000,
    this.hardDiskAdvice,
    this.networkAdvice,
    this.tightAdvice,
  });

  /// Peak space needed, or null while the size is still being fetched.
  final int? requiredBytes;

  /// Folder created inside the chosen drive, e.g. `chessdb`.
  final String folderName;

  final String browseTitle;

  /// Called on every change of selection.
  final ValueChanged<StorageDestination> onChanged;

  /// A fit leaving less than this is called out as tight.
  final int recommendedHeadroomBytes;

  /// Why a spinning disk is a poor choice for *this* database; null hides the
  /// advisory.
  final String? hardDiskAdvice;
  final String? networkAdvice;

  /// Extra sentence appended to the tight-fit warning.
  final String? tightAdvice;

  @override
  State<StorageDestinationPicker> createState() =>
      _StorageDestinationPickerState();
}

class _StorageDestinationPickerState extends State<StorageDestinationPicker> {
  List<StorageVolume> _volumes = const [];
  bool _loading = true;

  StorageVolume? _volume;
  String? _customDir;
  StorageVolume? _customVolume;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVolumes());
  }

  @override
  void didUpdateWidget(StorageDestinationPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The size usually arrives after the drives do; re-pick the default the
    // first time it is known, so the dialog never preselects a drive that
    // turns out to be too small.
    if (oldWidget.requiredBytes == null && widget.requiredBytes != null) {
      setState(() => _volume ??= _bestDefault(_volumes));
      _notify();
    }
  }

  Future<void> _loadVolumes() async {
    final volumes = await listStorageVolumes();
    if (!mounted) return;
    setState(() {
      _volumes = volumes;
      _loading = false;
      _volume ??= _bestDefault(volumes);
    });
    _notify();
  }

  void _notify() {
    widget.onChanged(
      StorageDestination(
        parentDir: _parentDir,
        volume: _targetVolume,
        fits: _fits || _targetVolume == null,
      ),
    );
  }

  /// Prefer a drive that fits with room to spare; among those, the fastest,
  /// then the roomiest.  Never silently pick one that cannot hold it.
  StorageVolume? _bestDefault(List<StorageVolume> volumes) {
    final needed = widget.requiredBytes;
    final candidates = volumes
        .where((v) => v.media != StorageMedia.network)
        .toList();
    if (candidates.isEmpty) return null;
    if (needed == null) return candidates.first;

    final fitting = candidates
        .where((v) => v.freeBytes >= needed + widget.recommendedHeadroomBytes)
        .toList();
    if (fitting.isEmpty) return null;
    fitting.sort((a, b) {
      final aSsd = a.media == StorageMedia.ssd ? 0 : 1;
      final bSsd = b.media == StorageMedia.ssd ? 0 : 1;
      if (aSsd != bSsd) return aSsd - bSsd;
      return b.freeBytes.compareTo(a.freeBytes);
    });
    return fitting.first;
  }

  Future<void> _pickCustomDirectory() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: widget.browseTitle,
    );
    if (picked == null || !mounted) return;
    final volume = await volumeForPath(picked);
    if (!mounted) return;
    setState(() {
      _customDir = picked;
      _customVolume = volume;
      _volume = null;
    });
    _notify();
  }

  String? get _parentDir {
    if (_customDir != null) return _customDir;
    final v = _volume;
    return v == null ? null : _suggestedPath(v);
  }

  /// A folder the user can actually write to: inside their home directory
  /// when the drive holds it, `<mount>/<folder>` otherwise.
  String _suggestedPath(StorageVolume v) {
    final home = Platform.environment['HOME'];
    if (home != null &&
        home.isNotEmpty &&
        (p.equals(v.mountPoint, home) || p.isWithin(v.mountPoint, home))) {
      return p.join(home, widget.folderName);
    }
    return p.join(v.mountPoint, widget.folderName);
  }

  StorageVolume? get _targetVolume =>
      _customDir != null ? _customVolume : _volume;

  int? get _freeAfter {
    final v = _targetVolume;
    final needed = widget.requiredBytes;
    if (v == null || needed == null) return null;
    return v.freeBytes - needed;
  }

  bool get _fits => (_freeAfter ?? -1) >= 0;
  bool get _isTight =>
      _fits && (_freeAfter ?? 0) < widget.recommendedHeadroomBytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_drives(), const SizedBox(height: 12), ..._advisories()],
    );
  }

  Widget _drives() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Reading drives…', style: TextStyle(fontSize: 12)),
      );
    }
    if (_volumes.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Could not list drives on this system — choose a folder instead.',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 8),
          _browseButton(),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final v in _volumes) _volumeRow(v),
        const SizedBox(height: 4),
        Row(
          children: [
            _selectionMark(_customDir != null),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _customDir ?? 'Another folder…',
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _browseButton(),
          ],
        ),
      ],
    );
  }

  /// Radio-style mark.  A real [Radio] wants a group owner this list does not
  /// have — the rows are plain tap targets.
  Widget _selectionMark(bool selected) => Icon(
    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
    size: 18,
    color: selected ? Theme.of(context).colorScheme.primary : AppColors.outline,
  );

  Widget _browseButton() => TextButton.icon(
    onPressed: () => unawaited(_pickCustomDirectory()),
    icon: const Icon(Icons.folder_open, size: 16),
    label: const Text('Browse…'),
  );

  Widget _volumeRow(StorageVolume v) {
    final needed = widget.requiredBytes;
    final after = needed == null ? null : v.freeBytes - needed;
    final fits = after != null && after >= 0;
    final selected = _customDir == null && _volume?.mountPoint == v.mountPoint;

    return InkWell(
      onTap: () {
        setState(() {
          _volume = v;
          _customDir = null;
          _customVolume = null;
        });
        _notify();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _selectionMark(selected),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Text(
                v.mountPoint,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(v.mediaLabel, style: AppTextStyles.caption),
            ),
            Expanded(
              flex: 3,
              child: Text(
                '${formatBytes(v.freeBytes)} free of '
                '${formatBytes(v.totalBytes)}',
                style: AppTextStyles.caption,
              ),
            ),
            SizedBox(
              width: 130,
              child: after == null
                  ? const SizedBox.shrink()
                  : Text(
                      fits
                          ? '${formatBytes(after)} to spare'
                          : 'short by ${formatBytes(-after)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        color: fits
                            ? AppColors.onSurfaceSoft
                            : AppColors.danger,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _advisories() {
    final v = _targetVolume;
    final out = <Widget>[];

    if (v != null && !_fits) {
      out.add(
        destinationBanner(
          AppColors.danger,
          Icons.error_outline,
          'This drive is short by ${formatBytes(-(_freeAfter ?? 0))}. '
          'Pick another drive, or free up space and reopen this dialog.',
        ),
      );
    } else if (_isTight) {
      out.add(
        destinationBanner(
          AppColors.warning,
          Icons.warning_amber_rounded,
          'This fits with only ${formatBytes(_freeAfter ?? 0)} left over.'
          '${widget.tightAdvice == null ? '' : ' ${widget.tightAdvice}'}',
        ),
      );
    }

    final hardDisk = widget.hardDiskAdvice;
    if (v?.media == StorageMedia.hardDisk && hardDisk != null) {
      out.add(destinationBanner(AppColors.warning, Icons.speed, hardDisk));
    }
    final network = widget.networkAdvice;
    if (v?.media == StorageMedia.network && network != null) {
      out.add(destinationBanner(AppColors.warning, Icons.cloud_off, network));
    }

    return [
      for (final w in out)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
    ];
  }
}

/// The tinted advisory box the download dialogs use.
Widget destinationBanner(
  Color color,
  IconData icon,
  String message, {
  Widget? action,
}) {
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
        ?action,
      ],
    ),
  );
}

/// `2 Sep 2026` — shared by the download dialogs and the settings panel.
String formatDestinationDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}
