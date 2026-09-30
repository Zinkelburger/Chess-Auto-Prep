import 'package:chess_auto_prep/features/settings/update_offer.dart';
import 'package:chess_auto_prep/net/github_releases.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_releases.dart';

const allSuffixes = [
  'windows-setup.exe',
  'windows.zip',
  'linux-amd64.deb',
  'linux-x86_64.rpm',
  'linux.zip',
  'linux.flatpak',
  'macos-arm64.zip',
];

void main() {
  OfferCheck check(
    Map<String, Object?> json, {
    InstallKind kind = InstallKind.linuxPortable,
    String current = '1.16.1',
  }) => offerFor(parseRelease(json), current: current, kind: kind);

  test('each install takes its own file from a full release', () {
    const expected = {
      InstallKind.windowsSetup: 'chess-auto-prep-v1.17.0-windows-setup.exe',
      InstallKind.linuxDeb: 'chess-auto-prep-v1.17.0-linux-amd64.deb',
      InstallKind.linuxRpm: 'chess-auto-prep-v1.17.0-linux-x86_64.rpm',
      InstallKind.linuxPortable: 'chess-auto-prep-v1.17.0-linux.zip',
    };
    for (final MapEntry(key: kind, value: name) in expected.entries) {
      final offer =
          (check(releaseJson(suffixes: allSuffixes), kind: kind) as Newer)
              .offer;
      expect(offer.asset!.payload.name, name, reason: '$kind');
      expect(offer.asset!.payload.size, releaseBytes.length);
      expect(offer.asset!.payload.sha256, releaseDigest.substring(7));
      expect(offer.asset!.url.path, endsWith('/v1.17.0/$name'));
      expect(offer.version.toString(), '1.17.0');
    }
  });

  test('a copy updated by hand is offered the release page, no file', () {
    final offer =
        (check(releaseJson(suffixes: []), kind: InstallKind.manual) as Newer)
            .offer;
    expect(offer.installable, isFalse);
    expect(offer.page.path, '/$updateRepository/releases/tag/v1.17.0');
  });

  test('older, equal, draft, prerelease and oddly tagged releases are not '
      'offered', () {
    expect(check(releaseJson(tag: 'v1.9.0')), isA<NotNewer>());
    expect(check(releaseJson(tag: 'v1.16.1')), isA<NotNewer>());
    expect(check(releaseJson(draft: true)), isA<NotNewer>());
    expect(check(releaseJson(prerelease: true)), isA<NotNewer>());
    expect(check(releaseJson(tag: 'nightly')), isA<NotNewer>());
    expect(check(releaseJson(tag: 'v2.0.0-beta')), isA<NotNewer>());
    // The app reads its version without a build number, so a +BUILD tag
    // would look newer even once it is installed.
    expect(
      check(releaseJson(tag: 'v1.17.0+5'), current: '1.17.0'),
      isA<NotNewer>(),
    );
    expect(check(releaseJson(), current: 'unknown'), isA<NotNewer>());
    // Numbers, not text: 1.10 is newer than 1.9.
    expect(check(releaseJson(tag: 'v1.10.0'), current: '1.9.3'), isA<Newer>());
  });

  test('a release without trustworthy facts for this file fails closed', () {
    expect(check(releaseJson(digest: '')), isA<Incomplete>());
    expect(check(releaseJson(digest: 'md5:abc')), isA<Incomplete>());
    expect(check(releaseJson(state: 'starter')), isA<Incomplete>());
    expect(check(releaseJson(size: 0)), isA<Incomplete>());
    expect(check(releaseJson(size: maxAssetBytes + 1)), isA<Incomplete>());
    expect(
      check(releaseJson(url: 'https://example.com/update.zip')),
      isA<Incomplete>(),
    );
    expect(
      check(releaseJson(suffixes: ['linux.zip', 'linux.zip'])),
      isA<Incomplete>(),
    );
    expect(
      check(releaseJson(), kind: InstallKind.windowsSetup),
      isA<Incomplete>(),
    );
  });
}
