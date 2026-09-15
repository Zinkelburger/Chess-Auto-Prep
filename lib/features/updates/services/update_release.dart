/// A GitHub release of this app, reduced to the one asset this install can
/// use and the integrity facts needed to trust it.
library;

import 'package:pub_semver/pub_semver.dart';

const updateRepository = 'Zinkelburger/Chess-Auto-Prep';
final releasesPage = Uri.https('github.com', '/$updateRepository/releases');

/// How this copy of the app was installed, which decides which release
/// asset (if any) can replace it in place.
enum InstallKind {
  windowsInstaller('windows-setup.exe'),
  linuxDeb('linux-amd64.deb'),
  linuxRpm('linux-x86_64.rpm'),
  linuxPortable('linux.zip'),

  /// Nothing the app can install itself; the user is sent to the releases
  /// page.
  manual('');

  const InstallKind(this.suffix);

  /// The tail of the asset file name for this install, after the tag.
  final String suffix;
}

/// Release tags are `vMAJOR.MINOR.PATCH`, optionally `+BUILD`.
final _releaseTag = RegExp(r'^v\d+\.\d+\.\d+(\+\d+)?$');

/// GitHub's asset digest: `sha256:` and 64 hex digits.
final _sha256Digest = RegExp(r'^sha256:([a-fA-F0-9]{64})$');

/// An asset larger than this is not something this app published.
const _maxAssetBytes = 4 * 1024 * 1024 * 1024;

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

  /// The asset file name, or empty for a manual install.
  final String assetName;

  /// Where the asset downloads from; the releases page for a manual install.
  final Uri url;

  /// Lower-case hex; empty for a manual install.
  final String sha256;
  final int size;

  Uri get page =>
      Uri.https('github.com', '/$updateRepository/releases/tag/$tag');

  /// Only complete stable releases, exact platform assets and GitHub's digest.
  /// Missing integrity metadata is an error, never a reason to skip
  /// verification. Returns null when [json] is not a newer stable release.
  static UpdateRelease? parse(
    Map<String, dynamic> json,
    String currentVersion,
    InstallKind kind,
  ) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'] as String;
    if (!_releaseTag.hasMatch(tag)) return null;
    final version = Version.parse(tag.substring(1));
    if (version <= Version.parse(currentVersion)) return null;
    final notes = json['body'] as String? ?? '';
    if (kind == InstallKind.manual) {
      return UpdateRelease(
        version: version,
        tag: tag,
        notes: notes,
        assetName: '',
        url: releasesPage,
        sha256: '',
        size: 0,
      );
    }
    final name = 'chess-auto-prep-$tag-${kind.suffix}';
    final asset = _findAsset(json, name);
    final digest = _sha256Digest.firstMatch(asset['digest'] as String? ?? '');
    final size = asset['size'] as int;
    final url = Uri.parse(asset['browser_download_url'] as String);
    final expectedUrl = Uri.https(
      'github.com',
      '/$updateRepository/releases/download/$tag/$name',
    );
    if (asset['state'] != 'uploaded' ||
        digest == null ||
        size <= 0 ||
        size > _maxAssetBytes ||
        url != expectedUrl) {
      throw const FormatException(
        'Release has incomplete or untrusted update metadata.',
      );
    }
    return UpdateRelease(
      version: version,
      tag: tag,
      notes: notes,
      assetName: name,
      url: url,
      sha256: digest[1]!.toLowerCase(),
      size: size,
    );
  }

  /// The one asset called [name]; a missing or duplicated asset is an
  /// incomplete release, not a release without an update.
  static Map<String, dynamic> _findAsset(
    Map<String, dynamic> json,
    String name,
  ) {
    final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
    final matches = assets.where((a) => a['name'] == name).toList();
    if (matches.length != 1) {
      throw const FormatException(
        'Release asset is missing. Try again after the release finishes uploading.',
      );
    }
    return matches.single;
  }
}
