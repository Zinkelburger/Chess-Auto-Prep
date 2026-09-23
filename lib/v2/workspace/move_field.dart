import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/typed_move.dart';
import '../ui/theme.dart';

/// The typed-move field's words and focus.
///
/// The window keeps one for the life of the workspace instead of the field
/// keeping its own: the field under the board is built anew as a lesson
/// takes the board and gives it back, and keys reach it from outside the
/// field — `/` from anywhere in the workspace, a move's first letter from a
/// lesson that is asking for one.
final class MoveEntry {
  final words = TextEditingController();
  final focus = FocusNode(debugLabel: 'move field');

  /// [character] after the words, and the focus in the field, as if it had
  /// been typed there.
  void type(String character) {
    focus.requestFocus();
    final text = words.text + character;
    words.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void dispose() {
    words.dispose();
    focus.dispose();
  }
}

/// A move typed instead of played on the board: SAN or UCI, played the
/// moment the words name one legal move and could not go on to name
/// another (see [readTypedMove]).
///
/// The move goes to [onMove], the way a move made on the board goes, so a
/// typed move is saved, taken back and judged as a dragged one is. Enter
/// plays what the words still leave; Esc clears them and gives the keys
/// back to whatever had them before. Words no move is written as turn the
/// field the error colour, and nothing more is said.
class MoveField extends StatefulWidget {
  const MoveField({
    super.key,
    required this.entry,
    required this.fen,
    required this.onMove,
  });

  final MoveEntry entry;

  /// The position on the board, which the words are read in.
  final Fen fen;

  /// Where a move goes, as UCI; null while the board takes none, which
  /// leaves the field read-only.
  final ValueChanged<String>? onMove;

  @override
  State<MoveField> createState() => _MoveFieldState();
}

class _MoveFieldState extends State<MoveField> {
  /// Enter found no move in the words; the next change forgets it.
  bool _refused = false;

  /// The words as last heard, so a caret moving is not a change.
  String _heard = '';

  TextEditingController get _words => widget.entry.words;

  @override
  void initState() {
    super.initState();
    _heard = _words.text;
    _words.addListener(_changed);
  }

  @override
  void didUpdateWidget(MoveField old) {
    super.didUpdateWidget(old);
    if (old.entry == widget.entry) return;
    old.entry.words.removeListener(_changed);
    _heard = _words.text;
    _words.addListener(_changed);
  }

  @override
  void dispose() {
    _words.removeListener(_changed);
    super.dispose();
  }

  /// Heard on the controller rather than from the field, so words a lesson
  /// types in from outside are read the same as keys pressed here.
  void _changed() {
    final text = _words.text;
    if (text == _heard) return;
    _heard = text;
    if (_refused) setState(() => _refused = false);
    if (readTypedMove(widget.fen, text) case Resolved(:final uci)) _play(uci);
  }

  void _play(String uci) {
    final onMove = widget.onMove;
    if (onMove == null) return;
    _words.clear();
    onMove(uci);
  }

  void _entered(String text) {
    final uci = enteredMove(widget.fen, text);
    if (uci != null && widget.onMove != null) return _play(uci);
    setState(() => _refused = text.trim().isNotEmpty);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    _words.clear();
    widget.entry.focus.unfocus(
      disposition: UnfocusDisposition.previouslyFocusedChild,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _key,
      child: Tooltip(
        message: 'Type a move (/)',
        child: ValueListenableBuilder(
          valueListenable: _words,
          builder: (context, value, _) {
            final wrong =
                _refused ||
                (value.text.isNotEmpty &&
                    readTypedMove(widget.fen, value.text) is NoMatch);
            final line = wrong
                ? theme.colorScheme.error
                : theme.colorScheme.outline;
            return TextField(
              controller: _words,
              focusNode: widget.entry.focus,
              readOnly: widget.onMove == null,
              onSubmitted: _entered,
              // Without this the field lets go of the focus on Enter; the
              // next move is typed into it too.
              onEditingComplete: () {},
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(_moveCharacters),
                LengthLimitingTextInputFormatter(_longestMove),
              ],
              style: monoText.copyWith(
                color: wrong ? theme.colorScheme.error : null,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Type a move',
                hintStyle: theme.textTheme.bodySmall,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Space.s,
                  vertical: Space.s,
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: wrong ? line : theme.colorScheme.primary,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// What a move can be written with: SAN and UCI letters, digits, and the
  /// marks the reading ignores. Space and `/` are keys, never words here.
  static final _moveCharacters = RegExp(r'[a-hA-HKkQqRrNnOox0-9=+#!?:-]');

  /// `exd8=Q+!` is eight; nothing a move is written as is longer.
  static const _longestMove = 8;
}
