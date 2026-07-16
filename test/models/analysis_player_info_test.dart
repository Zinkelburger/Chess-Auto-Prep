import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chess_auto_prep/models/analysis_player_info.dart';

/// Pure (no-filesystem) coverage of the username → storage-key derivation that
/// every analysis file path is built from ([AnalysisPlayerInfo.playerKey]).
///
/// The security-relevant property is that the derivation is an *allowlist*:
/// `username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_')`. Because
/// only `[a-z0-9_-]` survives, the sanitized portion can never contain a path
/// separator (`/`, `\`), a `.` (so no `..` traversal token can form), a colon,
/// or a NUL byte. The mandatory `<platform>_` prefix keeps the whole key a
/// single path segment. The filesystem-level proof that this actually confines
/// writes lives in test/services/path_sanitization_test.dart; this file pins
/// the string contract that guarantee rests on.
void main() {
  String keyFor(String platform, String username) =>
      AnalysisPlayerInfo(platform: platform, username: username).playerKey;

  /// The username-derived tail of the key (everything after `<platform>_`).
  String safeTail(String platform, String username) {
    final key = keyFor(platform, username);
    expect(key, startsWith('${platform}_'));
    return key.substring(platform.length + 1);
  }

  final nul = String.fromCharCode(0);

  group('AnalysisPlayerInfo.playerKey — benign names', () {
    test('passes platform usernames through unchanged (lowercased)', () {
      expect(keyFor('chesscom', 'Andrew_B-99'), 'chesscom_andrew_b-99');
      expect(keyFor('lichess', 'hikaru'), 'lichess_hikaru');
    });

    test('folds filename-hazardous characters to underscores', () {
      // '/' would nest the files in a subdirectory the player list never
      // scans, silently orphaning the import.
      expect(keyFor('import', 'AC/DC Fan'), 'import_ac_dc_fan');
      expect(keyFor('import', 'Carlsen, Magnus'), 'import_carlsen__magnus');
      expect(keyFor('import', 'a.b:c*d'), 'import_a_b_c_d');
    });

    test('names differing only in hazardous characters share a key', () {
      // Documented, intentional collapse: distinct hostile spellings that
      // sanitize to the same key deliberately map to the same slot.
      expect(keyFor('import', 'AC/DC'), keyFor('import', 'AC DC'));
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
    test('empty username yields just the platform prefix', () {
      expect(keyFor('import', ''), 'import_');
      expect(keyFor('chesscom', ''), 'chesscom_');
    });

    test('whitespace-only username folds to underscores', () {
      expect(keyFor('import', '   '), 'import____');
    });

    test('very long username does not crash and stays in-alphabet', () {
      final longName = 'A/../' * 5000; // 25k chars of hostile input
      final tail = safeTail('import', longName);
      expect(tail, matches(RegExp(r'^[a-z0-9_-]*$')));
      // Derivation must not truncate silently mid-string; length is preserved
      // (filesystem length limits are a separate, graceful write-time failure).
      expect(tail.length, longName.length);
    });

    test('case folding collapses names differing only in case', () {
      expect(keyFor('chesscom', 'Hikaru'), keyFor('chesscom', 'hikaru'));
      expect(keyFor('chesscom', 'HIKARU'), 'chesscom_hikaru');
    });

    // Reserved Windows device names (CON, NUL, PRN, AUX, COM1, LPT1) survive
    // the allowlist as-is, BUT the mandatory "<platform>_" prefix means the
    // on-disk basename is e.g. "import_con.pgn" — not the reserved "con" — so
    // no Windows reserved-name collision is reachable. Pin that here.
    test('reserved windows names are shielded by the platform prefix', () {
      for (final reserved in ['CON', 'NUL', 'PRN', 'AUX', 'COM1', 'LPT1']) {
        final key = keyFor('import', reserved);
        expect(key, 'import_${reserved.toLowerCase()}');
        // The base name is not itself a reserved device name.
        expect(
          ['con', 'nul', 'prn', 'aux', 'com1', 'lpt1'].contains(key),
          isFalse,
        );
      }
    });
  });
}
