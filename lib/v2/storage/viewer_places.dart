import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../chess/pgn/reading_place.dart';

abstract interface class ViewerPlaces {
  Future<ReadingPlace?> load(String path);
  Future<void> save(String path, ReadingPlace place);
}

/// Shares the existing reading-session key and schema. Writes and reads are
/// serialized, and plugin caches are refreshed before reading disk evidence.
final class PreferencesViewerPlaces implements ViewerPlaces {
  PreferencesViewerPlaces({this.preferences = SharedPreferences.getInstance});
  final Future<SharedPreferences> Function() preferences;
  Future<void> _tail = Future.value();
  Future<T> _turn<T>(Future<T> Function(SharedPreferences) action) {
    final result = _tail.then((_) async {
      final prefs = await preferences();
      await prefs.reload();
      return action(prefs);
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<ReadingPlace?> load(String path) => _turn(
    (prefs) async =>
        ReadingPlace.decode(prefs.getString('pgn_viewer.session:$path')),
  );
  @override
  Future<void> save(String path, ReadingPlace place) => _turn((prefs) async {
    if (!await prefs.setString(
      'pgn_viewer.session:$path',
      jsonEncode(place.json),
    ))
      throw StateError('The reading position was not saved.');
  });
}
