import 'package:shared_preferences/shared_preferences.dart';
import '../features/documents/repositories/viewer_position_index_repository.dart';
import '../features/documents/repositories/viewer_opening_repository.dart';
import '../features/documents/repositories/viewer_solitaire_repository.dart';
import '../infrastructure/documents/storage_viewer_position_index_repository.dart';
import '../infrastructure/documents/isolate_viewer_opening_repository.dart';
import '../infrastructure/documents/shared_preferences_viewer_solitaire_repository.dart';
import '../services/opening_book_service.dart';
import '../services/solitaire_trophy_service.dart';
import '../services/storage/storage_factory.dart';

ViewerPositionIndexRepository createViewerPositionIndex() =>
    StorageViewerPositionIndexRepository(StorageFactory.instance);
ViewerOpeningRepository createViewerOpenings() =>
    IsolateViewerOpeningRepository(loadBook: OpeningBookService.instance.load);
ViewerSolitaireRepository createViewerSolitaire() =>
    SharedPreferencesViewerSolitaireRepository(
      preferences: SharedPreferences.getInstance,
      trophyCount: () async =>
          (await SolitaireTrophyService.instance.loadAll()).length,
    );
