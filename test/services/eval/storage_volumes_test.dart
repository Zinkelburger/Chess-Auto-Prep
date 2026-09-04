import 'package:chess_auto_prep/services/eval/storage_volumes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real `df -PB1 -T` output, trimmed.
const _df = '''
Filesystem     Type          1-blocks         Used    Available Capacity Mounted on
/dev/dm-0      btrfs    1021414735872 151321858048 866786865152      15% /
devtmpfs       devtmpfs   33290948608            0  33290948608       0% /dev
tmpfs          tmpfs      33408131072    102359040  33305772032       1% /dev/shm
/dev/dm-0      btrfs    1021414735872 151321858048 866786865152      15% /home
/dev/nvme0n1p2 ext4        2040373248     93310976   1822912512       5% /boot
/dev/sdb1      ext4     4000000000000 100000000000 3900000000000       3% /media/big disk
nas:/vol0      nfs4     8000000000000 200000000000 7800000000000       3% /mnt/nas
''';

void main() {
  group('parseDfTable', () {
    test('reads real volumes and drops pseudo filesystems', () {
      final volumes = parseDfTable(_df);
      expect(volumes.map((v) => v.mountPoint), [
        '/',
        '/home',
        '/boot',
        '/media/big disk',
        '/mnt/nas',
      ]);
    });

    test('keeps mount points that contain spaces intact', () {
      final big = parseDfTable(_df).firstWhere((v) => v.device == '/dev/sdb1');
      expect(big.mountPoint, '/media/big disk');
      expect(big.freeBytes, 3900000000000);
      expect(big.totalBytes, 4000000000000);
    });

    test('network filesystems are labelled as such without probing sysfs', () {
      final nas = parseDfTable(_df).firstWhere((v) => v.fsType == 'nfs4');
      expect(nas.media, StorageMedia.network);
      expect(nas.mediaLabel, 'Network');
    });

    test('a header-only or empty table yields nothing', () {
      expect(parseDfTable(''), isEmpty);
      expect(parseDfTable(_df.split('\n').first), isEmpty);
    });
  });

  group('dedupeByDevice', () {
    test('one row per device, preferring the mount that holds home', () {
      final volumes = dedupeByDevice(
        parseDfTable(_df),
        preferredPrefix: '/home/someone',
      );
      final btrfs = volumes.where((v) => v.device == '/dev/dm-0');
      expect(btrfs, hasLength(1));
      expect(btrfs.first.mountPoint, '/home');
    });

    test('without a preference the shallower mount wins', () {
      final volumes = dedupeByDevice(parseDfTable(_df));
      expect(
        volumes.firstWhere((v) => v.device == '/dev/dm-0').mountPoint,
        '/',
      );
    });

    test('sorted by free space, roomiest first', () {
      final volumes = dedupeByDevice(parseDfTable(_df));
      final free = volumes.map((v) => v.freeBytes).toList();
      expect(free, List<int>.from(free)..sort((a, b) => b.compareTo(a)));
    });
  });

  group('stripPartitionSuffix', () {
    test('nvme, mmc and scsi naming', () {
      expect(stripPartitionSuffix('nvme0n1p3'), 'nvme0n1');
      expect(stripPartitionSuffix('mmcblk0p1'), 'mmcblk0');
      expect(stripPartitionSuffix('sda1'), 'sda');
      expect(stripPartitionSuffix('sdb12'), 'sdb');
    });

    test('a whole-disk name is left alone', () {
      expect(stripPartitionSuffix('nvme0n1'), 'nvme0n1');
      expect(stripPartitionSuffix('sda'), 'sda');
      expect(stripPartitionSuffix('dm-0'), 'dm-0');
    });
  });

  group('formatBytes', () {
    test('scales to the unit a person would use', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(4305257543), '4.3 GB');
      expect(formatBytes(1188170000000), '1.2 TB');
    });

    test('drops the decimal once three digits are showing', () {
      expect(formatBytes(997000000000), '997 GB');
    });
  });
}
