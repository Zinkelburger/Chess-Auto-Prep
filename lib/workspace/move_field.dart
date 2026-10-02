import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/typed_move.dart';
import '../ui/app_keys.dart';
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
  final problem = ValueNotifier<String?>(null);
  final focus = FocusNode(debugLabel: 'move field');
  Fen? _position;

  /// The entry survives board widgets; notation belongs to its position.
  void follow(Fen fen) {
    if (_position == fen) return;
    _position = fen;
    words.clear();
    problem.value = null;
  }

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
    problem.dispose();
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
/// field the error colour; a submitted refusal explains what to change.
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
    // A replaced board may still have an inactive field listening to the
    // shared controller. Clear only after that old element has detached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.entry.follow(widget.fen);
    });
    _heard = _words.text;
    _words.addListener(_changed);
  }

  @override
  void didUpdateWidget(MoveField old) {
    super.didUpdateWidget(old);
    if (old.entry != widget.entry) {
      old.entry.words.removeListener(_changed);
      _heard = _words.text;
      _words.addListener(_changed);
    }
    // Words typed for another position mean nothing in this one.
    widget.entry.follow(widget.fen);
    // A board that stops taking moves gives the keys back.
    final focus = widget.entry.focus;
    if (widget.onMove == null && focus.hasFocus) {
      _words.clear();
      focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    }
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
    widget.entry.problem.value = null;
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
    widget.entry.problem.value = !_refused
        ? null
        : widget.onMove == null
        ? 'Moves are unavailable right now.'
        : readTypedMove(widget.fen, text) is StillTyping
        ? 'Specify the full move, such as Ngf3.'
        : 'That move is not legal here.';
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!AppKey.clearMove.accepts(event)) return KeyEventResult.ignored;
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
        message: AppKey.typeMove.tip('Type a move'),
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

/// A stable full-width line below board controls, also announced on refusal.
class MoveFeedback extends StatelessWidget {
  const MoveFeedback({super.key, required this.entry});
  final MoveEntry entry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: moveFeedbackHeight,
    child: ValueListenableBuilder(
      valueListenable: entry.problem,
      builder: (context, problem, _) => Semantics(
        liveRegion: true,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            problem ?? '',
            maxLines: 2,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ),
    ),
  );
}
