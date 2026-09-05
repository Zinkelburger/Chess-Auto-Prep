import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';

/// Opaque identities must be deterministic, separate distinct names, and stay
/// within one safe path component on every supported desktop platform.
void main() {
  String keyFor(String platform, String username) =>
      AnalysisPlayerInfo(platform: platform, username: username).playerKey;

  /// The username-derived tail of the key (everything after `<platform>_`).
  String safeTail(String platform, String username) {
    final key = keyFor(platform, username);
    expect(key, matches(RegExp(r'^player-[a-f0-9]{64}$')));
    return key.substring('player-'.length);
  }

  final nul = String.fromCharCode(0);

  group('AnalysisPlayerInfo.speeds', () {
    test('round-trips through JSON', () {
      const info = AnalysisPlayerInfo(
        platform: 'lichess',
        username: 'x',
        speeds: {GameSpeed.bullet, GameSpeed.blitz},
      );
      final back = AnalysisPlayerInfo.fromJson(info.toJson());
      expect(back.speeds, {GameSpeed.bullet, GameSpeed.blitz});
      expect(back.speedsDescription, 'bullet, blitz');
    });

    test('a set saved before the filter was a choice is the default', () {
      final back = AnalysisPlayerInfo.fromJson({
        'platform': 'chesscom',
        'username': 'x',
      });
      expect(back.speeds, defaultDownloadSpeeds);
      expect(back.speedsDescription, isNull);
    });

    test('an empty or garbled list never means "no games"', () {
      expect(
        AnalysisPlayerInfo.fromJson({
          'platform': 'chesscom',
          'username': 'x',
          'speeds': <String>[],
        }).speeds,
        defaultDownloadSpeeds,
      );
      expect(
        AnalysisPlayerInfo.fromJson({
          'platform': 'chesscom',
          'username': 'x',
          'speeds': ['hyperbullet', 'rapid'],
        }).speeds,
        {GameSpeed.rapid},
      );
    });

    test('a PGN-file import has no filter to describe', () {
      const info = AnalysisPlayerInfo(platform: 'import', username: 'Book');
      expect(info.speedsDescription, isNull);
      const all = AnalysisPlayerInfo(
        platform: 'chesscom',
        username: 'x',
        speeds: {...selectableGameSpeeds},
      );
      expect(all.speedsDescription, 'all time controls');
    });
  });

  group('AnalysisPlayerInfo.playerKey — benign names', () {
    test('platforms and distinct names have distinct opaque keys', () {
      expect(keyFor('chesscom', 'hikaru'), isNot(keyFor('lichess', 'hikaru')));
      expect(keyFor('import', 'AC/DC'), isNot(keyFor('import', 'AC DC')));
      expect(keyFor('import', 'AC/DC'), isNot(keyFor('import', 'AC_DC')));
      expect(
        keyFor('import', 'alice'),
        isNot(keyFor('import', 'alice_white_analysis')),
      );
    });
    test('legacy names remain available for migration', () {
      expect(
        const AnalysisPlayerInfo(
          platform: 'import',
          username: 'AC/DC Fan',
        ).legacyPlayerKey,
        'import_ac_dc_fan',
      );
    });
  });

  group('AnalysisPlayerInfo.playerKey — sanitized tail is always safe', () {
    // The core invariant: whatever the user types, the tail matches this and
    // therefore cannot contain a separator, dot, or NUL.
    final tailAlphabet = RegExp(r'^[a-z0-9_-]*$');

    final hostileNames = <String, String>{
      'unix parent traversal': '../../etc/passwd',
      'deep unix traversal': '../../../../../../etc/shadow',
      'windows traversal': r'..\..\..\Windows\System32\config',
      'leading absolute unix path': '/etc/passwd',
      'leading absolute windows path': r'C:\Windows\System32',
      'bare dot-dot': '..',
      'single dot': '.',
      'url-encoded traversal': '%2e%2e%2f%2e%2e%2f',
      'embedded NUL byte': 'foo${nul}bar',
      'newline and tab': 'foo\nbar\ttail',
      'unicode homoglyphs and emoji': 'café♞名前🏰',
      'unc path': r'\\server\share\file',
      'trailing slash': 'user/',
      'just slashes': '////',
      'mixed hostile': '../a/../../b\\c:d*e?',
    };

    hostileNames.forEach((label, hostile) {
      test('tail stays in [a-z0-9_-] for $label', () {
        for (final platform in ['import', 'chesscom', 'lichess']) {
          final tail = safeTail(platform, hostile);
          expect(
            tail,
            matches(tailAlphabet),
            reason: 'sanitized tail must not leak "$hostile" verbatim',
          );
          // No path separator, no dot (so no ".." token can survive), no
          // drive-letter colon, no whitespace, no NUL.
          expect(tail, isNot(contains('/')));
          expect(tail, isNot(contains(r'\')));
          expect(tail, isNot(contains('.')));
          expect(tail, isNot(contains(':')));
          expect(tail, isNot(contains(' ')));
          expect(tail, isNot(contains('..')));
          expect(tail, isNot(contains(nul)));
        }
      });
    });

    test('full key is a single path segment (basename == itself)', () {
      for (final hostile in hostileNames.values) {
        final key = keyFor('import', hostile);
        // A well-formed key, appended to a directory, must not introduce any
        // new path component: joining dir + "$key.pgn" and taking basename
        // must round-trip.
        final fileName = '$key.pgn';
        expect(p.basename(fileName), fileName);
        expect(p.split(p.join('root', fileName)), ['root', fileName]);
      }
    });
  });

  group('AnalysisPlayerInfo.playerKey — edge cases (no crash)', () {
    test('empty usernames remain safely namespaced', () {
      expect(safeTail('import', '').length, 64);
      expect(keyFor('import', ''), isNot(keyFor('chesscom', '')));
    });

    test('whitespace-only username has a distinct safe key', () {
      expect(safeTail('import', '   ').length, 64);
      expect(keyFor('import', '   '), isNot(keyFor('import', '')));
    });

    test('very long username does not crash and stays in-alphabet', () {
      final longName = 'A/../' * 5000; // 25k chars of hostile input
      final tail = safeTail('import', longName);
      expect(tail, matches(RegExp(r'^[a-z0-9_-]*$')));
      // Long names cannot exceed the filesystem component length limit.
      expect(tail.length, 64);
    });

    test('case folding collapses names differing only in case', () {
      expect(keyFor('chesscom', 'Hikaru'), keyFor('chesscom', 'hikaru'));
      expect(keyFor('chesscom', 'HIKARU'), keyFor('chesscom', 'hikaru'));
    });

    // Reserved Windows device names (CON, NUL, PRN, AUX, COM1, LPT1) survive
    // the allowlist as-is, BUT the mandatory "<platform>_" prefix means the
    // on-disk basename is e.g. "import_con.pgn" — not the reserved "con" — so
    // no Windows reserved-name collision is reachable. Pin that here.
    test('reserved Windows names produce safe opaque keys', () {
      for (final reserved in ['CON', 'NUL', 'PRN', 'AUX', 'COM1', 'LPT1']) {
        final key = keyFor('import', reserved);
        expect(key, startsWith('player-'));
        // The base name is not itself a reserved device name.
        expect(
          ['con', 'nul', 'prn', 'aux', 'com1', 'lpt1'].contains(key),
          isFalse,
        );
      }
    });
  });
}
