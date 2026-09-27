import 'package:shared_preferences/shared_preferences.dart';
import '../../features/documents/repositories/viewer_solitaire_repository.dart';

class SharedPreferencesViewerSolitaireRepository
    implements ViewerSolitaireRepository {
  SharedPreferencesViewerSolitaireRepository({
    required this.preferences,
    required this.trophyCount,
  });
  final Future<SharedPreferences> Function() preferences;
  final Future<int> Function() trophyCount;
  Future<void> _tail = Future.value();
  Future<T> _run<T>(Future<T> Function(SharedPreferences) action) {
    final result = _tail.then((_) async {
      final prefs = await preferences();
      await prefs.reload();
      return action(prefs);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<ViewerSolitaireSettings> load() => _run(
    (prefs) async => (
      revealDelaySeconds: prefs.getInt('solitaire_reveal_delay_sec') ?? 60,
      includeVariations: prefs.getBool('solitaire_include_variations') ?? false,
      trophyCount: await trophyCount(),
    ),
  );
  Future<void> _ack(Future<bool> write) async {
    if (!await write) throw StateError('Solitaire settings were not saved');
  }

  @override
  Future<void> saveRevealDelay(int seconds) => _run(
    (prefs) => _ack(prefs.setInt('solitaire_reveal_delay_sec', seconds)),
  );
  @override
  Future<void> saveIncludeVariations(bool value) => _run(
    (prefs) => _ack(prefs.setBool('solitaire_include_variations', value)),
  );
}
