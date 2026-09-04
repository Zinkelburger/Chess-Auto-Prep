/// Where a large download can go: mounted volumes, their free space, and
/// whether they sit on spinning rust.
///
/// The ChessDB dump is ~1.2 TB and is read with random 4 KB lookups, so the
/// difference between an SSD and a hard disk is the difference between a
/// millisecond and a seek. The download UI shows both facts before the user
/// commits several hours of transfer to a drive.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Filesystem types that are not real storage (RAM, kernel, containers).
const Set<String> _pseudoFsTypes = {
  'autofs',
  'bpf',
  'cgroup',
  'cgroup2',
  'configfs',
  'debugfs',
  'devpts',
  'devtmpfs',
  'efivarfs',
  'fuse.gvfsd-fuse',
  'fuse.portal',
  'fusectl',
  'hugetlbfs',
  'mqueue',
  'overlay',
  'proc',
  'pstore',
  'ramfs',
  'securityfs',
  'squashfs',
  'sysfs',
  'tmpfs',
  'tracefs',
};

/// Filesystem types served over the network — usable, but a poor home for a
/// database read with random lookups.
const Set<String> _remoteFsTypes = {
  'afs',
  'cifs',
  'fuse.sshfs',
  'nfs',
  'nfs4',
  'smb3',
  'smbfs',
};

/// How a volume stores bytes, as far as the kernel will admit.
enum StorageMedia { ssd, hardDisk, network, unknown }

class StorageVolume {
  const StorageVolume({
    required this.device,
    required this.fsType,
    required this.mountPoint,
    required this.totalBytes,
    required this.freeBytes,
    this.media = StorageMedia.unknown,
  });

  final String device;
  final String fsType;
  final String mountPoint;
  final int totalBytes;
  final int freeBytes;
  final StorageMedia media;

  int get usedBytes => totalBytes - freeBytes;

  StorageVolume withMedia(StorageMedia value) => StorageVolume(
    device: device,
    fsType: fsType,
    mountPoint: mountPoint,
    totalBytes: totalBytes,
    freeBytes: freeBytes,
    media: value,
  );

  /// Short label for the volume list.
  String get mediaLabel => switch (media) {
    StorageMedia.ssd => 'SSD',
    StorageMedia.hardDisk => 'Hard disk',
    StorageMedia.network => 'Network',
    StorageMedia.unknown => fsType,
  };
}

/// Parse `df -PB1 -T` output.
///
/// Columns are separated by runs of spaces, and both the device (`//host/my
/// share`) and the mount point (`/media/big disk`) can contain spaces — so the
/// five numeric-ish columns in the middle are what the row is matched on, and
/// everything on either side of them is taken whole.
List<StorageVolume> parseDfTable(String stdout) {
  final row = RegExp(r'^(.*?)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$');
  final volumes = <StorageVolume>[];
  for (final line in const LineSplitter().convert(stdout)) {
    if (line.trim().isEmpty) continue;
    if (line.startsWith('Filesystem')) continue;

    final m = row.firstMatch(line);
    if (m == null) continue;
    final total = int.tryParse(m.group(3)!);
    final free = int.tryParse(m.group(5)!);
    if (total == null || free == null || total <= 0) continue;

    final fsType = m.group(2)!;
    if (_pseudoFsTypes.contains(fsType)) continue;

    volumes.add(
      StorageVolume(
        device: m.group(1)!.trim(),
        fsType: fsType,
        mountPoint: m.group(7)!.trim(),
        totalBytes: total,
        freeBytes: free,
        media: _remoteFsTypes.contains(fsType)
            ? StorageMedia.network
            : StorageMedia.unknown,
      ),
    );
  }
  return volumes;
}

/// Keep one row per underlying device.
///
/// A btrfs root usually mounts `/` and `/home` from the same device; showing
/// both as separate destinations would suggest they have separate space.
/// [preferredPrefix] (normally the home directory) decides which mount point
/// survives, since that is where the user is most likely to want the dump.
List<StorageVolume> dedupeByDevice(
  List<StorageVolume> volumes, {
  String? preferredPrefix,
}) {
  final byDevice = <String, StorageVolume>{};
  for (final v in volumes) {
    final existing = byDevice[v.device];
    if (existing == null) {
      byDevice[v.device] = v;
      continue;
    }
    if (_isBetterMount(v, existing, preferredPrefix)) byDevice[v.device] = v;
  }
  final result = byDevice.values.toList();
  result.sort((a, b) => b.freeBytes.compareTo(a.freeBytes));
  return result;
}

bool _isBetterMount(
  StorageVolume candidate,
  StorageVolume current,
  String? preferredPrefix,
) {
  if (preferredPrefix != null) {
    final candidateHolds = _holds(candidate.mountPoint, preferredPrefix);
    final currentHolds = _holds(current.mountPoint, preferredPrefix);
    if (candidateHolds != currentHolds) return candidateHolds;
    // Both contain the preferred path: the deeper mount is the one it
    // actually sits on (`/home` rather than `/`).
    if (candidateHolds) {
      return candidate.mountPoint.length > current.mountPoint.length;
    }
  }
  return candidate.mountPoint.length < current.mountPoint.length;
}

bool _holds(String mountPoint, String path) =>
    p.equals(mountPoint, path) || p.isWithin(mountPoint, path);

/// `/dev/nvme0n1p2` → `nvme0n1`, `/dev/sda1` → `sda`, `/dev/mapper/x` → its
/// first backing device. Returns null when the name is not a block device.
Future<String?> resolveBlockDeviceName(String device) async {
  if (!device.startsWith('/dev/')) return null;

  var name = device.substring('/dev/'.length);
  if (name.startsWith('mapper/') || name.startsWith('dm-')) {
    final resolved = await _resolveDeviceMapper(name);
    if (resolved == null) return null;
    name = resolved;
  }

  return stripPartitionSuffix(name);
}

/// `nvme0n1p3` → `nvme0n1`; `sda1` → `sda`; `mmcblk0p1` → `mmcblk0`.
String stripPartitionSuffix(String name) {
  final nvme = RegExp(r'^(nvme\d+n\d+)p\d+$').firstMatch(name);
  if (nvme != null) return nvme.group(1)!;
  final mmc = RegExp(r'^(mmcblk\d+)p\d+$').firstMatch(name);
  if (mmc != null) return mmc.group(1)!;
  final sd = RegExp(r'^([a-z]+)\d+$').firstMatch(name);
  if (sd != null) return sd.group(1)!;
  return name;
}

Future<String?> _resolveDeviceMapper(String name) async {
  var dmName = name;
  if (name.startsWith('mapper/')) {
    final link = Link('/dev/$name');
    try {
      dmName = p.basename(await link.resolveSymbolicLinks());
    } catch (_) {
      return null;
    }
  }
  final slaves = Directory('/sys/block/$dmName/slaves');
  if (!await slaves.exists()) return null;
  final entries = await slaves.list().toList();
  if (entries.isEmpty) return null;
  entries.sort((a, b) => a.path.compareTo(b.path));
  return p.basename(entries.first.path);
}

/// Whether the kernel reports [device] as rotational. Null when unknown.
Future<bool?> deviceIsRotational(String device) async {
  if (!Platform.isLinux) return null;
  final name = await resolveBlockDeviceName(device);
  if (name == null) return null;
  final file = File('/sys/block/$name/queue/rotational');
  if (!await file.exists()) return null;
  final value = (await file.readAsString()).trim();
  if (value == '1') return true;
  if (value == '0') return false;
  return null;
}

/// Mounted volumes that could hold a large download, best free space first.
Future<List<StorageVolume>> listStorageVolumes({String? homeDirectory}) async {
  if (Platform.isWindows) return const [];
  final ProcessResult result;
  try {
    result = await Process.run('df', const ['-PB1', '-T']);
  } on ProcessException {
    return const [];
  }
  if (result.exitCode != 0) return const [];

  final parsed = parseDfTable(result.stdout as String);
  final deduped = dedupeByDevice(
    parsed,
    preferredPrefix: homeDirectory ?? Platform.environment['HOME'],
  );
  return _annotateMedia(deduped);
}

Future<List<StorageVolume>> _annotateMedia(List<StorageVolume> volumes) async {
  final annotated = <StorageVolume>[];
  for (final v in volumes) {
    if (v.media != StorageMedia.unknown) {
      annotated.add(v);
      continue;
    }
    final rotational = await deviceIsRotational(v.device);
    annotated.add(
      v.withMedia(switch (rotational) {
        true => StorageMedia.hardDisk,
        false => StorageMedia.ssd,
        null => StorageMedia.unknown,
      }),
    );
  }
  return annotated;
}

/// The volume that holds [path] — walking up to the nearest existing parent,
/// so a folder the user has only named yet still reports its future home.
Future<StorageVolume?> volumeForPath(String path) async {
  final existing = await _nearestExistingDirectory(path);
  if (existing == null) return null;
  if (Platform.isWindows) return null;

  final ProcessResult result;
  try {
    result = await Process.run('df', ['-PB1', '-T', existing]);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) return null;
  final rows = parseDfTable(result.stdout as String);
  if (rows.isEmpty) return null;
  final annotated = await _annotateMedia(rows);
  return annotated.first;
}

/// Free bytes on the volume holding [path], or null when it cannot be read.
Future<int?> freeBytesForPath(String path) async =>
    (await volumeForPath(path))?.freeBytes;

Future<String?> _nearestExistingDirectory(String path) async {
  var dir = p.absolute(path);
  for (var i = 0; i < 64; i++) {
    if (await Directory(dir).exists()) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
  return null;
}

/// Human-readable byte size: `1.19 TB`, `997 GB`, `4.3 GB`.
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 1000) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final places = value >= 100 ? 0 : decimals;
  return '${value.toStringAsFixed(places)} ${units[unit]}';
}
