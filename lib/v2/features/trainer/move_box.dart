import 'package:flutter/material.dart';

import '../../chess/training/drill.dart' show Asking;
import '../../chess/typed_move.dart';
import '../../ui/theme.dart';
import 'lesson.dart';

/// Whether [lesson] is waiting for the user's move.
bool askingFor(Lesson lesson) =>
    lesson.state is Drilling && lesson.drill.stage is Asking;

/// Plays the move [words] name, if the lesson is asking and they name
/// exactly one, and clears them. Whether a move was played.
bool playTyped(Lesson lesson, TextEditingController words) {
  if (!askingFor(lesson)) return false;
  final uci = typedMove(lesson.drill.fen, words.text);
  if (uci == null) return false;
  words.clear();
  lesson.play(uci);
  return true;
}

/// The move typed rather than played: SAN or UCI, played as soon as the
/// words name exactly one legal move, with no Enter needed. Enter on words
/// that name none says so.
///
/// The lesson view owns the words and the focus, so it can send a key typed
/// on the lesson into the box and take the focus back once the lesson stops
/// asking.
class MoveBox extends StatefulWidget {
  const MoveBox({
    super.key,
    required this.lesson,
    required this.controller,
    required this.focusNode,
  });

  final Lesson lesson;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  State<MoveBox> createState() => _MoveBoxState();
}

class _MoveBoxState extends State<MoveBox> {
  /// Enter was pressed on words that name no move here.
  var _refused = false;

  void _changed(String _) {
    playTyped(widget.lesson, widget.controller);
    if (_refused) setState(() => _refused = false);
  }

  void _submitted(String text) {
    if (playTyped(widget.lesson, widget.controller)) return;
    setState(() => _refused = text.trim().isNotEmpty);
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Type a move (/)',
    child: TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      readOnly: !askingFor(widget.lesson),
      onChanged: _changed,
      onSubmitted: _submitted,
      autocorrect: false,
      enableSuggestions: false,
      style: monoText,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Type a move…',
        errorText: _refused ? 'Not a legal move here' : null,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
