import 'package:chess_auto_prep/app/window_input.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/workspace/study_picker.dart';
import 'package:dartchess/dartchess.dart' show Side;

/// The window as a window test scripts it: what the clipboard holds and
/// which study chapters go into, with the chapter names it was asked for.
final class ScriptedInput implements WindowInput {
  String? clipboardText;
  StudyPick? study;
  final chaptersAsked = <String?>[];

  @override
  Future<Side?> sideFor(String chapter) async => null;

  @override
  Future<String?> clipboard() async => clipboardText;

  @override
  Future<StudyPick?> studyFor({
    required List<ChapterRef> studies,
    required String? chapter,
    required int count,
  }) async {
    chaptersAsked.add(chapter);
    return study;
  }
}
