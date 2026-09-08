import 'package:pub_semver/pub_semver.dart';

const updateRepository = 'Zinkelburger/Chess-Auto-Prep';
final releasesPage = Uri.https('github.com', '/$updateRepository/releases');

enum InstallKind {
  windowsInstaller('windows-setup.exe'),
  linuxDeb('linux-amd64.deb'),
  linuxRpm('linux-x86_64.rpm'),
  linuxPortable('linux.zip'),
  manual('');

  const InstallKind(this.suffix);
  final String suffix;
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.assetName,
    required this.url,
    required this.sha256,
    required this.size,
  });

  final Version version;
  final String tag;
  final String notes;
  final String assetName;
  final Uri url;
  final String sha256;
  final int size;
  Uri get page =>
      Uri.https('github.com', '/$updateRepository/releases/tag/$tag');

  /// Only complete stable releases, exact platform assets and GitHub's digest.
  /// Missing integrity metadata is an error, never a reason to skip verification.
  static UpdateRelease? parse(
    Map<String, dynamic> json,
    String currentVersion,
    InstallKind kind,
  ) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'] as String;
    if (!RegExp(r'^v\d+\.\d+\.\d+(\+\d+)?$').hasMatch(tag)) return null;
    final version = Version.parse(tag.substring(1));
    if (version <= Version.parse(currentVersion)) return null;
    final name = 'chess-auto-prep-$tag-${kind.suffix}';
    final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
    if (kind == InstallKind.manual) {
      return UpdateRelease(
        version: version,
        tag: tag,
        notes: json['body'] as String? ?? '',
        assetName: '',
        url: releasesPage,
        sha256: '',
        size: 0,
      );
    }
    final matches = assets.where((a) => a['name'] == name).toList();
    if (matches.length != 1) {
      throw const FormatException(
        'Release asset is missing. Try again after the release finishes uploading.',
      );
    }
    final asset = matches.single;
    final digest = asset['digest'] as String? ?? '';
    final size = asset['size'] as int;
    final url = Uri.parse(asset['browser_download_url'] as String);
    if (asset['state'] != 'uploaded' ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
        size <= 0 ||
        size > 4 * 1024 * 1024 * 1024 ||
        url !=
            Uri.https(
              'github.com',
              '/$updateRepository/releases/download/$tag/$name',
            )) {
      throw const FormatException(
        'Release has incomplete or untrusted update metadata.',
      );
    }
    return UpdateRelease(
      version: version,
      tag: tag,
      notes: json['body'] as String? ?? '',
      assetName: name,
      url: url,
      sha256: digest.substring(7).toLowerCase(),
      size: size,
    );
  }
}
