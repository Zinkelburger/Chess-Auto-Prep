import '../models/board_display_configuration.dart';
import '../repositories/settings_section_storage.dart';
import 'section_settings_owner.dart';

class BoardDisplaySettings
    extends SectionSettingsOwner<BoardDisplayConfiguration> {
  BoardDisplaySettings(
    SettingsSectionStorage<BoardDisplayConfiguration> storage,
  ) : super(storage, BoardDisplayConfiguration());
  BoardCoordinates get coordinates => committed.coordinates;
  PieceNotation get pieceNotation => committed.pieceNotation;
  bool get showLegalMoves => committed.showLegalMoves;
  Future<void> setCoordinates(BoardCoordinates value) =>
      edit({'display.board_coordinates': value.name});
  Future<void> setPieceNotation(PieceNotation value) =>
      edit({'display.piece_notation': value.name});
  Future<void> setShowLegalMoves(bool value) =>
      edit({'display.legal_moves': value});
}
