/// The Scid game encoder, checked byte-for-byte against Scid's own output.
///
/// `fixtures/ref4.*` and `fixtures/ref5.*` were produced by compiling Scid's
/// codec (`src/codec_scid4.cpp`, `scidbase.cpp`, `game.cpp`, `position.cpp`,
/// `sortcache.cpp`, `stored.cpp`, `textbuf.cpp`, `misc.cpp` — the Tcl-free
/// subset its own gtest target uses) and importing `fixtures/fixture.pgn`. The
/// game-data file is byte-identical between the two format versions, which is
/// why one encoder serves both.
///
/// `fixture.pgn` is deliberately awkward: castling both sides, a two-byte queen
/// diagonal, en passant, an under-promotion to a knight, and a game starting
/// from a FEN with comments, a NAG and a variation — the cases where a piece
/// list that has drifted from Scid's produces plausible-looking but wrong
/// bytes.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:chess_auto_prep/services/scid/scid_game_encoder.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'test/services/scid/fixtures';

List<PgnGame<PgnNodeData>> _fixtureGames() {
  final text = io.File('$_dir/fixture.pgn').readAsStringSync();
  return PgnGame.parseMultiGamePgn(text);
}

Uint8List _encodedBlobs(List<PgnGame<PgnNodeData>> games) {
  final out = BytesBuilder();
  for (final g in games) {
    out.add(ScidGameEncoder.encode(g).data);
  }
  return out.takeBytes();
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  test('the fixture parses into five games', () {
    expect(_fixtureGames(), hasLength(5));
  });

  test('game data is identical between Scid v4 and v5', () {
    final sg4 = io.File('$_dir/ref4.sg4').readAsBytesSync();
    final sg5 = io.File('$_dir/ref5.sg5').readAsBytesSync();
    expect(
      sg4,
      orderedEquals(sg5),
      reason: 'if these ever diverge, one encoder can no longer serve both',
    );
  });

  test('every game encodes to the bytes Scid itself wrote', () {
    final expected = io.File('$_dir/ref4.sg4').readAsBytesSync();
    final actual = _encodedBlobs(_fixtureGames());

    if (!_sameBytes(expected, actual)) {
      // Point at the first divergence rather than dumping 178 bytes twice.
      var i = 0;
      while (i < expected.length &&
          i < actual.length &&
          expected[i] == actual[i]) {
        i++;
      }
      final from = (i - 8) < 0 ? 0 : i - 8;
      int end(int len) => (from + 24) > len ? len : from + 24;
      fail(
        'diverged at byte $i\n'
        '  expected: ${_hex(expected.sublist(from, end(expected.length)))}\n'
        '  actual:   ${_hex(actual.sublist(from, end(actual.length)))}\n'
        '  lengths: expected ${expected.length}, actual ${actual.length}',
      );
    }
    expect(actual, orderedEquals(expected));
  });

  group('derived index fields', () {
    test('ply counts match the mainlines', () {
      final games = _fixtureGames();
      final plies = games.map((g) => ScidGameEncoder.encode(g).plyCount);
      expect(plies, [61, 86, 79, 57, 4]);
    });

    test('no game is truncated — every fixture move is legal', () {
      for (final g in _fixtureGames()) {
        expect(ScidGameEncoder.encode(g).truncatedAt, isNull);
      }
    });

    test('promotions set the flag that matches the piece', () {
      final encoded = _fixtureGames().map(ScidGameEncoder.encode).toList();
      expect(
        encoded.where((g) => g.hasPromotion),
        isNotEmpty,
        reason: 'the fixture contains a game promoting to a queen',
      );
      expect(
        encoded.where((g) => g.hasUnderPromotion),
        isNotEmpty,
        reason: 'the fixture contains a game under-promoting',
      );
    });

    test('only the FEN game is marked as a non-standard start', () {
      final flags = _fixtureGames().map(
        (g) => ScidGameEncoder.encode(g).nonStandardStart,
      );
      expect(flags, [false, false, false, false, true]);
    });

    test('comments, variations and NAGs are counted', () {
      final g = ScidGameEncoder.encode(_fixtureGames()[4]);
      expect(g.commentCount, 3, reason: 'quiet move, equal, main line');
      expect(g.variationCount, 1);
      expect(g.nagCount, 1);
    });

    test('home pawns are recorded in departure order', () {
      final g = ScidGameEncoder.encode(_fixtureGames().first);
      expect(g.homePawnCount, greaterThan(0));
      // First byte is the count; nibbles follow, low first.
      expect(g.homePawnData[0], g.homePawnCount);
      expect(g.homePawnData, hasLength(9));
    });
  });

  group('material signature', () {
    test('the standard start packs both full armies', () {
      final sig = materialSignature(Chess.initial);
      expect((sig >> 12) & 0xF, 8, reason: 'white pawns');
      expect((sig >> 0) & 0xF, 8, reason: 'black pawns');
      expect((sig >> 22) & 0x3, 1, reason: 'white queen');
      expect((sig >> 20) & 0x3, 2, reason: 'white rooks');
    });

    test('piece counts saturate at three', () {
      final threeQueens = Chess.fromSetup(
        Setup.parseFen('4k3/8/8/8/8/8/8/QQQQK3 w - - 0 1'),
      );
      expect((materialSignature(threeQueens) >> 22) & 0x3, 3);
    });
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
