import 'package:chess_auto_prep/chess/pgn/collection_player.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

/// Three games of Carlsen's, as White, Black and White.
const carlsenGames = '''
[Event "Open"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]

1. e4 e5 *

[Event "Open"]
[White "Caruana, Fabiano"]
[Black "Carlsen, Magnus"]

1. d4 d5 *

[Event "Open"]
[White "Carlsen, Magnus"]
[Black "Giri, Anish"]

1. c4 e5 *
''';

final class _Places implements ViewerPlaces {
  final saved = <String, ReadingPlace>{};

  @override
  Future<ReadingPlace?> load(String path) async => saved[path];

  @override
  Future<void> save(String path, ReadingPlace place) async =>
      saved[path] = place;
}

void main() {
  late ViewerFixture fixture;
  tearDown(() => fixture.dispose());

  test(
    'a collection of one player\'s games shows each from their side',
    () async {
      fixture = await viewerOver(carlsenGames);
      await fixture.open();
      expect(fixture.viewer.followed, 'Carlsen, Magnus');
      expect(fixture.session.orientation, Side.white);
      fixture.viewer.showGame(1);
      expect(fixture.session.orientation, Side.black);
      fixture.viewer.showGame(2);
      expect(fixture.session.orientation, Side.white);
    },
  );

  test('a flip on the game stands until another game comes', () async {
    fixture = await viewerOver(carlsenGames);
    await fixture.open(game: 1);
    expect(fixture.session.orientation, Side.black);
    fixture.session.flip();
    fixture.session.playMove('g1f3');
    expect(fixture.session.orientation, Side.white);
  });

  test('following another player, or nobody, is kept for the file', () async {
    final places = _Places();
    fixture = await viewerOver(carlsenGames, places: places);
    await fixture.open();
    fixture.viewer.follow('Nakamura');
    expect(fixture.session.orientation, Side.black);
    await pumpEventQueue();
    expect(
      places.saved[fixture.ref.path]!.perspective,
      const FollowPlayer('Nakamura'),
    );
    fixture.viewer.follow('');
    expect(fixture.viewer.followed, isNull);
    fixture.viewer.showGame(1);
    expect(fixture.session.orientation, Side.white, reason: 'nobody followed');
    await pumpEventQueue();
    final place = places.saved[fixture.ref.path];
    await fixture.session.open(fixture.ref, game: 1);
    await fixture.viewer.opened(fixture.ref, place: place);
    expect(fixture.viewer.perspective, const FollowNobody());
    expect(fixture.viewer.players.first, 'Carlsen, Magnus');
  });
}
