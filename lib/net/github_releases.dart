import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../diagnostics/log.dart';
import 'lichess_http.dart' show appUserAgent;

/// The app's own releases on GitHub: the newest one, and the bytes of one
/// of its files. The app asks at most once a day and when the user presses
/// Check now, so there is no retry here: a check that fails is simply the
/// next day's check, and a download that fails is the user's Try again.

/// The repository the app is published from.
const updateRepository = 'Zinkelburger/Chess-Auto-Prep';

/// One file attached to a release, as GitHub describes it.
final class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.digest,
    required this.uploaded,
  });

  final String name;
  final Uri url;

  /// Bytes, as GitHub counted them on upload.
  final int size;

  /// GitHub's `sha256:<hex>`, or empty when it gave none.
  final String digest;

  /// False while the file is still being uploaded.
  final bool uploaded;
}

/// A release as GitHub lists it, before anything about this copy of the
/// app decides whether it is newer or which file fits.
final class GitHubRelease {
  const GitHubRelease({
    required this.tag,
    required this.stable,
    required this.assets,
  });

  final String tag;

  /// Neither a draft nor a prerelease.
  final bool stable;
  final List<ReleaseAsset> assets;

  /// Where the release is shown on GitHub.
  Uri get page =>
      Uri.https('github.com', '/$updateRepository/releases/tag/$tag');
}

sealed class ReleaseCheck {
  const ReleaseCheck();
}

final class LatestRelease extends ReleaseCheck {
  const LatestRelease(this.release);

  final GitHubRelease release;
}

/// The repository has no release at all: GitHub's 404.
final class NoRelease extends ReleaseCheck {
  const NoRelease();
}

enum ReleaseProblem { unreachable, rateLimited, http, malformed }

final class ReleaseCheckFailed extends ReleaseCheck {
  const ReleaseCheckFailed(this.problem);

  final ReleaseProblem problem;
}

sealed class AssetDownload {
  const AssetDownload();
}

/// The file is coming: its announced length, when GitHub gave one, and its
/// bytes, which fail with a [TimeoutException] when they stop arriving.
final class AssetStream extends AssetDownload {
  const AssetStream(this.bytes, {this.length});

  final Stream<List<int>> bytes;
  final int? length;
}

/// The server could not be reached or did not send the file.
final class AssetRefused extends AssetDownload {
  const AssetRefused();
}

/// The releases of the app. The network is a real boundary: GitHub in the
/// app, a scripted one in tests.
abstract interface class AppReleases {
  /// The newest release GitHub calls latest: never a draft or prerelease.
  Future<ReleaseCheck> latest();

  /// Starts the transfer of [url], one of a release's asset URLs.
  Future<AssetDownload> download(Uri url);
}

/// How long the release list may take.
const releaseCheckTimeout = Duration(seconds: 20);

/// How long a download may take to start, and how long its bytes may stop.
const downloadStartTimeout = Duration(seconds: 30);
const downloadStallTimeout = Duration(seconds: 45);

final class GitHubReleases implements AppReleases {
  /// [latestUrl] replaces GitHub's for a headless check against a local
  /// fixture; the app itself never sets it.
  GitHubReleases(this._client, {Uri? latestUrl})
    : _latest =
          latestUrl ??
          Uri.https(
            'api.github.com',
            '/repos/$updateRepository/releases/latest',
          );

  final http.Client _client;
  final Uri _latest;

  @override
  Future<ReleaseCheck> latest() async {
    final http.Response response;
    try {
      response = await _client
          .get(
            _latest,
            headers: {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': appUserAgent,
            },
          )
          .timeout(releaseCheckTimeout);
    } on Object catch (error) {
      log.w('check GitHub for a new release', error);
      return const ReleaseCheckFailed(ReleaseProblem.unreachable);
    }
    final status = response.statusCode;
    if (status == 404) return const NoRelease();
    if (status == 403 || status == 429) {
      log.w('check GitHub for a new release', 'HTTP $status');
      return const ReleaseCheckFailed(ReleaseProblem.rateLimited);
    }
    if (status != 200) {
      log.w('check GitHub for a new release', 'HTTP $status');
      return const ReleaseCheckFailed(ReleaseProblem.http);
    }
    try {
      return LatestRelease(parseRelease(jsonDecode(response.body)));
    } on Object catch (error) {
      log.w('read the GitHub release', error);
      return const ReleaseCheckFailed(ReleaseProblem.malformed);
    }
  }

  @override
  Future<AssetDownload> download(Uri url) async {
    final http.StreamedResponse response;
    try {
      response = await _client
          .send(
            http.Request('GET', url)
              ..headers['User-Agent'] = appUserAgent
              ..headers['Accept'] = 'application/octet-stream',
          )
          .timeout(downloadStartTimeout);
    } on Object catch (error) {
      log.w('download the update', error);
      return const AssetRefused();
    }
    if (response.statusCode != 200) {
      log.w('download the update', 'HTTP ${response.statusCode}');
      unawaited(response.stream.listen(null).cancel());
      return const AssetRefused();
    }
    return AssetStream(
      response.stream.timeout(downloadStallTimeout),
      length: response.contentLength,
    );
  }
}

/// GitHub's release JSON as a [GitHubRelease]. Throws [FormatException]
/// when a field the app relies on is missing or of the wrong type.
GitHubRelease parseRelease(Object? json) {
  if (json is! Map<String, Object?>) {
    throw const FormatException('a release is not a JSON object');
  }
  final tag = json['tag_name'];
  final assets = json['assets'] ?? const <Object?>[];
  if (tag is! String || assets is! List<Object?>) {
    throw const FormatException('a release has no tag or asset list');
  }
  return GitHubRelease(
    tag: tag,
    stable: json['draft'] == false && json['prerelease'] == false,
    assets: [for (final asset in assets) _asset(asset)],
  );
}

ReleaseAsset _asset(Object? json) {
  if (json is! Map<String, Object?>) {
    throw const FormatException('a release asset is not a JSON object');
  }
  if (json case {
    'name': final String name,
    'browser_download_url': final String url,
    'size': final int size,
  }) {
    final digest = json['digest'];
    return ReleaseAsset(
      name: name,
      url: Uri.parse(url),
      size: size,
      digest: digest is String ? digest : '',
      uploaded: json['state'] == 'uploaded',
    );
  }
  throw const FormatException('a release asset lacks its name, URL or size');
}
