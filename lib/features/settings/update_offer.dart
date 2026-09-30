import 'package:pub_semver/pub_semver.dart';

import '../../net/github_releases.dart';
import '../../storage/update_files.dart';
import '../../storage/update_install.dart';

/// A release newer than this copy, with the one file that can replace this
/// copy and the facts that prove the download is that file.
final class UpdateOffer {
  const UpdateOffer({
    required this.version,
    required this.tag,
    required this.page,
    this.asset,
  });

  final Version version;
  final String tag;

  /// The release on GitHub, for its notes and for a copy that updates by
  /// hand.
  final Uri page;

  /// The file to download, and where from; null when this copy is updated
  /// by hand.
  final ({ExpectedPayload payload, Uri url})? asset;

  /// Whether the app can download and install it itself.
  bool get installable => asset != null;

  @override
  bool operator ==(Object other) =>
      other is UpdateOffer && other.tag == tag && other.asset == asset;

  @override
  int get hashCode => Object.hash(tag, asset);
}

sealed class OfferCheck {
  const OfferCheck();
}

final class Newer extends OfferCheck {
  const Newer(this.offer);

  final UpdateOffer offer;
}

/// Not newer than this copy, not a stable release, or not tagged the way
/// releases are.
final class NotNewer extends OfferCheck {
  const NotNewer();
}

/// Newer, but this copy's file is missing, duplicated, still uploading or
/// lacks the digest that would let it be verified. Missing integrity facts
/// are a failure, never a reason to install without them.
final class Incomplete extends OfferCheck {
  const Incomplete();
}

/// Release tags are `vMAJOR.MINOR.PATCH`. Never `+BUILD`: the app reads
/// its own version without the build number, so such a release would stay
/// newer after it was installed.
final _releaseTag = RegExp(r'^v\d+\.\d+\.\d+$');

/// GitHub's asset digest: `sha256:` and 64 hex digits.
final _sha256Digest = RegExp(r'^sha256:([a-fA-F0-9]{64})$');

/// A file bigger than this is not one this app published.
const maxAssetBytes = 4 * 1024 * 1024 * 1024;

/// Whether [release] is newer than [current] and, for a copy installed as
/// [kind], which of its files replaces it:
/// `chess-auto-prep-<tag>-<kind's suffix>`, downloaded only from this
/// repository's release URL. A version this copy cannot read is never
/// older than anything, so nothing is offered.
OfferCheck offerFor(
  GitHubRelease release, {
  required String current,
  required InstallKind kind,
}) {
  final Version installed;
  try {
    installed = Version.parse(current);
  } on FormatException {
    return const NotNewer();
  }
  if (!release.stable || !_releaseTag.hasMatch(release.tag)) {
    return const NotNewer();
  }
  final version = Version.parse(release.tag.substring(1));
  if (version <= installed) return const NotNewer();
  final suffix = kind.assetSuffix;
  if (suffix == null) {
    return Newer(
      UpdateOffer(version: version, tag: release.tag, page: release.page),
    );
  }
  final name = 'chess-auto-prep-${release.tag}-$suffix';
  final matches = release.assets.where((a) => a.name == name).toList();
  if (matches.length != 1) return const Incomplete();
  final asset = matches.single;
  final digest = _sha256Digest.firstMatch(asset.digest);
  final expectedUrl = Uri.https(
    'github.com',
    '/$updateRepository/releases/download/${release.tag}/$name',
  );
  if (!asset.uploaded ||
      digest == null ||
      asset.size <= 0 ||
      asset.size > maxAssetBytes ||
      asset.url != expectedUrl) {
    return const Incomplete();
  }
  return Newer(
    UpdateOffer(
      version: version,
      tag: release.tag,
      page: release.page,
      asset: (
        payload: (
          tag: release.tag,
          name: name,
          size: asset.size,
          sha256: digest[1]!.toLowerCase(),
        ),
        url: asset.url,
      ),
    ),
  );
}
