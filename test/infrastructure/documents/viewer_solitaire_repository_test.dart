import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_solitaire_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Backend extends InMemorySharedPreferencesStore {
  _Backend() : super.empty();
  bool reject = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (reject) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test('rejected settings cannot become the next loaded preference', () async {
    final backend = _Backend();
    SharedPreferencesStorePlatform.instance = backend;
    final repository = SharedPreferencesViewerSolitaireRepository(
      preferences: SharedPreferences.getInstance,
      trophyCount: () async => 7,
    );
    await repository.saveRevealDelay(12);
    backend.reject = true;
    await expectLater(repository.saveRevealDelay(30), throwsStateError);
    await expectLater(repository.saveIncludeVariations(true), throwsStateError);
    final retained = await repository.load();
    expect(retained.revealDelaySeconds, 12);
    expect(retained.includeVariations, isFalse);
    expect(retained.trophyCount, 7);
    backend.reject = false;
    await repository.saveRevealDelay(18);
    await repository.saveIncludeVariations(true);
    final recovered = await repository.load();
    expect(recovered.revealDelaySeconds, 18);
    expect(recovered.includeVariations, isTrue);
  });
}
