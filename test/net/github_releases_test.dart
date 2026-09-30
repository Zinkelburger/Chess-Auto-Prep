import 'dart:convert';

import 'package:chess_auto_prep/net/github_releases.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/scripted_releases.dart';

void main() {
  GitHubReleases answering(int status, String body) =>
      GitHubReleases(MockClient((_) async => http.Response(body, status)));

  test('the latest release is read with its files', () async {
    Uri? asked;
    final releases = GitHubReleases(
      MockClient((request) async {
        asked = request.url;
        return http.Response(jsonEncode(releaseJson()), 200);
      }),
    );
    final answer = await releases.latest();
    expect(asked!.host, 'api.github.com');
    expect(asked!.path, '/repos/$updateRepository/releases/latest');
    final release = (answer as LatestRelease).release;
    expect(release.tag, 'v1.17.0');
    expect(release.stable, isTrue);
    expect(release.assets.single.name, 'chess-auto-prep-v1.17.0-linux.zip');
    expect(release.assets.single.digest, releaseDigest);
    expect(release.page.path, '/$updateRepository/releases/tag/v1.17.0');
  });

  test('a fixture address replaces GitHub for a headless check', () async {
    Uri? asked;
    final fixture = Uri.parse('http://127.0.0.1:8765/latest.json');
    final releases = GitHubReleases(
      MockClient((request) async {
        asked = request.url;
        return http.Response(jsonEncode(releaseJson()), 200);
      }),
      latestUrl: fixture,
    );
    await releases.latest();
    expect(asked, fixture);
  });

  test('no releases, rate limits, errors and garbage are told apart', () async {
    expect(await answering(404, '').latest(), isA<NoRelease>());
    for (final status in [403, 429]) {
      final answer = await answering(status, '').latest();
      expect(
        (answer as ReleaseCheckFailed).problem,
        ReleaseProblem.rateLimited,
      );
    }
    final error = await answering(500, '').latest() as ReleaseCheckFailed;
    expect(error.problem, ReleaseProblem.http);
    final garbage = await answering(200, '[1, 2]').latest();
    expect((garbage as ReleaseCheckFailed).problem, ReleaseProblem.malformed);
  });

  test('a network that throws is unreachable, not an exception', () async {
    final releases = GitHubReleases(
      MockClient((_) async => throw http.ClientException('offline')),
    );
    final answer = await releases.latest();
    expect((answer as ReleaseCheckFailed).problem, ReleaseProblem.unreachable);
  });

  test('drafts and prereleases are not stable', () {
    expect(parseRelease(releaseJson(draft: true)).stable, isFalse);
    expect(parseRelease(releaseJson(prerelease: true)).stable, isFalse);
    expect(() => parseRelease({'tag_name': 3}), throwsFormatException);
  });

  test('a download streams its bytes or is refused', () async {
    final releases = GitHubReleases(
      MockClient(
        (request) async => request.url.path.endsWith('missing')
            ? http.Response('', 404)
            : http.Response.bytes(releaseBytes, 200),
      ),
    );
    final ok = await releases.download(Uri.parse('https://github.com/a'));
    final bytes = await (ok as AssetStream).bytes.expand((b) => b).toList();
    expect(bytes, releaseBytes);
    final refused = await releases.download(
      Uri.parse('https://github.com/missing'),
    );
    expect(refused, isA<AssetRefused>());
  });
}
